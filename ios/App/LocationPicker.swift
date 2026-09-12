import SwiftUI
import MapKit
import RulesEngine

/// A Maps-app-style location picker for a location exception, mirroring the macOS `LocationPicker`:
/// a tall interactive map with a floating search field + live results and the geofence radius
/// overlaid on top, plus a locate-me button. Tapping the map moves the center; picking a search
/// result flies there. The name auto-tracks the selected location and is never manually edited.
///
/// The map is an `MKMapView` (via `UIViewRepresentable`) rather than SwiftUI's `Map`, because the
/// app deploys back to iOS 16 where `Map(position:)` / overlays / map controls aren't available.
///
/// Edits go through a local `draft` so the continuous radius slider only commits to the bound region
/// when the drag ends — a per-tick commit would re-persist and re-arm the geofence on every frame.
struct LocationPicker: View {
    @Binding var region: GeoRegion
    var currentCoordinate: CLLocationCoordinate2D?
    var requestLocation: () -> Void = {}

    @StateObject private var search = PlaceSearchModel()
    @FocusState private var searchFocused: Bool
    @State private var draft: GeoRegion

    init(region: Binding<GeoRegion>, currentCoordinate: CLLocationCoordinate2D? = nil,
         requestLocation: @escaping () -> Void = {}) {
        _region = region
        self.currentCoordinate = currentCoordinate
        self.requestLocation = requestLocation
        _draft = State(initialValue: region.wrappedValue)
    }

    /// A brand-new exception has no location yet (0,0 — the middle of the ocean); seed it to the
    /// user's current position once a fix is available.
    private var regionIsUnset: Bool { draft.latitude == 0 && draft.longitude == 0 }
    private var coordKey: String? { currentCoordinate.map { "\($0.latitude),\($0.longitude)" } }

    var body: some View {
        ZStack(alignment: .top) {
            MapCanvas(region: draft) { coord in
                searchFocused = false
                setCenter(coord)
            }
            searchOverlay
            radiusOverlay
        }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { requestLocation(); seedIfNeeded() }
        // Seed to the current location as soon as a fix arrives (if still unset).
        .onChange(of: coordKey) { _ in seedIfNeeded() }
    }

    private var searchOverlay: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Maps", text: $search.query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .onChange(of: search.query) { _ in search.update() }
                    .onSubmit { search.update() }
                if !search.query.isEmpty {
                    Button { search.query = ""; search.results = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))

            if searchFocused, !search.results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results) { result in
                        Button { pick(result) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title).font(.callout).foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        if result.id != search.results.last?.id { Divider() }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(8)
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private var radiusOverlay: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            Slider(value: $draft.radius, in: 50...5000, step: 50) { editing in
                if !editing { commit() }   // commit once the drag ends, not every frame
            }
            .frame(width: 140)
            Text("\(Int(draft.radius)) m").font(.caption).monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .padding(8)
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func commit() { region = draft }

    private func pick(_ result: PlaceSearchModel.Result) {
        searchFocused = false
        search.resolve(result) { name, coord in
            draft.latitude = coord.latitude
            draft.longitude = coord.longitude
            draft.name = name
            commit()
        }
    }

    /// Move the center and rename to match the new spot (reverse-geocoded). The stale guard keeps a
    /// slow geocode from clobbering a newer move.
    private func setCenter(_ coord: CLLocationCoordinate2D) {
        draft.latitude = coord.latitude
        draft.longitude = coord.longitude
        commit()
        search.name(for: coord) { name in
            if draft.latitude == coord.latitude, draft.longitude == coord.longitude {
                draft.name = name
                commit()
            }
        }
    }

    private func seedIfNeeded() {
        guard regionIsUnset, let c = currentCoordinate else { return }
        setCenter(c)
    }
}

/// Interactive `MKMapView` wrapper: renders the region's center pin + radius circle, recenters on
/// large jumps / radius changes, shows the user's location with a locate-me button, and reports a
/// tapped coordinate back to the picker.
private struct MapCanvas: UIViewRepresentable {
    let region: GeoRegion
    let onTap: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        map.addGestureRecognizer(tap)

        // Locate-me button, pinned bottom-trailing (the radius overlay sits bottom-leading).
        let track = MKUserTrackingButton(mapView: map)
        track.translatesAutoresizingMaskIntoConstraints = false
        track.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        track.layer.cornerRadius = 7
        map.addSubview(track)
        NSLayoutConstraint.activate([
            track.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -8),
            track.bottomAnchor.constraint(equalTo: map.bottomAnchor, constant: -8),
        ])
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.sync(region: region, on: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onTap: (CLLocationCoordinate2D) -> Void
        private var pin: MKPointAnnotation?
        private var circle: MKCircle?
        private var lastCenter: CLLocationCoordinate2D?
        private var lastRadius: CLLocationDistance = -1
        private var didSpan = false

        init(onTap: @escaping (CLLocationCoordinate2D) -> Void) { self.onTap = onTap }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            let point = g.location(in: map)
            onTap(map.convert(point, toCoordinateFrom: map))
        }

        func sync(region r: GeoRegion, on map: MKMapView) {
            let center = CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude)
            let geometryChanged = lastCenter.map { !Self.same($0, center) } ?? true || lastRadius != r.radius

            if pin == nil { let p = MKPointAnnotation(); pin = p; map.addAnnotation(p) }
            pin?.coordinate = center
            pin?.title = r.name.isEmpty ? "Area" : r.name

            if geometryChanged {
                if let old = circle { map.removeOverlay(old) }
                let c = MKCircle(center: center, radius: r.radius)
                circle = c
                map.addOverlay(c)
            }

            let moved = lastCenter.map { !Self.same($0, center) } ?? true
            if !didSpan || moved || lastRadius != r.radius {
                let meters = max(r.radius * 6, 800)
                map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: meters,
                                                 longitudinalMeters: meters), animated: didSpan)
                didSpan = true
            }
            lastCenter = center
            lastRadius = r.radius
        }

        private static func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
            abs(a.latitude - b.latitude) < 0.00001 && abs(a.longitude - b.longitude) < 0.00001
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.18)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 1.5
            return renderer
        }
    }
}

/// Drives the search overlay: debounced completion suggestions, then an `MKLocalSearch` to turn a
/// chosen suggestion into a coordinate, plus reverse-geocoding for map taps / the seeded location.
@MainActor
final class PlaceSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    struct Result: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let subtitle: String
        let completion: MKLocalSearchCompletion
        static func == (a: Result, b: Result) -> Bool { a.id == b.id }
    }

    @Published var query = ""
    @Published var results: [Result] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    func update() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { results = []; return }
        completer.queryFragment = text
    }

    // MapKit delivers completer callbacks on the main queue, so assume isolation rather than hopping
    // through a Task (which would require sending the non-Sendable MKLocalSearchCompletion results).
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            // Read the stored (MainActor-isolated) completer rather than the parameter — same object,
            // but avoids "sending" the non-Sendable parameter across the isolation boundary.
            self.results = self.completer.results.prefix(6).map {
                Result(title: $0.title, subtitle: $0.subtitle, completion: $0)
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.results = [] }
    }

    /// Reverse-geocode a coordinate to a short human name (for map taps / the seeded current
    /// location, which arrive without a search title).
    func name(for coord: CLLocationCoordinate2D, then apply: @escaping (String) -> Void) {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        CLGeocoder().reverseGeocodeLocation(loc) { placemarks, _ in
            let p = placemarks?.first
            let name = p?.name ?? p?.thoroughfare ?? p?.locality ?? "Dropped pin"
            Task { @MainActor in apply(name) }
        }
    }

    func resolve(_ result: Result, then apply: @escaping (String, CLLocationCoordinate2D) -> Void) {
        let request = MKLocalSearch.Request(completion: result.completion)
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            let coord = item.placemark.coordinate
            let name = item.name ?? result.title
            Task { @MainActor in
                apply(name, coord)
                self.results = []
                self.query = ""
            }
        }
    }
}
