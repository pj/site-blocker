import SwiftUI
import MapKit
import RulesEngine

/// A Maps-app-style location picker for a location exception. A tall interactive map with a floating
/// search field and live results overlaid on top (à la Apple Maps), the system locate-me / compass
/// controls, and the geofence radius below. Tapping the map nudges the center; picking a search
/// result flies there. Bound to the `GeoRegion` so edits flow straight back into the draft.
struct LocationPicker: View {
    @Binding var region: GeoRegion
    var currentCoordinate: CLLocationCoordinate2D?
    var requestLocation: () -> Void = {}

    @StateObject private var search = PlaceSearchModel()
    @State private var camera: MapCameraPosition
    @FocusState private var searchFocused: Bool

    init(region: Binding<GeoRegion>, currentCoordinate: CLLocationCoordinate2D? = nil,
         requestLocation: @escaping () -> Void = {}) {
        _region = region
        self.currentCoordinate = currentCoordinate
        self.requestLocation = requestLocation
        _camera = State(initialValue: .region(Self.span(for: region.wrappedValue)))
    }

    /// A brand-new exception has no location yet (0,0 — the middle of the ocean); seed it to the
    /// user's current position once a fix is available.
    private var regionIsUnset: Bool { region.latitude == 0 && region.longitude == 0 }
    private var coordKey: String? { currentCoordinate.map { "\($0.latitude),\($0.longitude)" } }

    private func seedIfNeeded() {
        guard regionIsUnset, let c = currentCoordinate else { return }
        setCenter(c)
    }

    private var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude)
    }

    private static func span(for region: GeoRegion) -> MKCoordinateRegion {
        let meters = max(region.radius * 6, 800)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
            latitudinalMeters: meters, longitudinalMeters: meters)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                MapReader { proxy in
                    Map(position: $camera) {
                        UserAnnotation()
                        Marker(region.name.isEmpty ? "Area" : region.name, coordinate: center)
                        MapCircle(center: center, radius: region.radius)
                            .foregroundStyle(.blue.opacity(0.18))
                            .stroke(.blue, lineWidth: 1.5)
                    }
                    .mapControls { MapUserLocationButton(); MapCompass() }
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        searchFocused = false
                        if let coord = proxy.convert(point, from: .local) { setCenter(coord) }
                    }
                }
                searchOverlay
                radiusOverlay
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .onAppear { requestLocation(); seedIfNeeded() }
        // Seed to the current location as soon as a fix arrives (if still unset).
        .onChange(of: coordKey) { seedIfNeeded() }
        // Follow large jumps (search result) and radius changes; tapping re-centers, which reads as
        // deliberate.
        .onChange(of: region.latitude) { recenter() }
        .onChange(of: region.longitude) { recenter() }
        .onChange(of: region.radius) { recenter() }
    }

    private var searchOverlay: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Maps", text: $search.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: search.query) { search.update() }
                    .onSubmit { search.update() }
                if !search.query.isEmpty {
                    Button { search.query = ""; search.results = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))

            if searchFocused, !search.results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results) { result in
                        Button { pick(result) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title).font(.callout)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 6).padding(.horizontal, 10)
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
            Slider(value: $region.radius, in: 50...5000, step: 50).frame(width: 150)
            Text("\(Int(region.radius)) m").font(.caption).monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .padding(8)
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func pick(_ result: PlaceSearchModel.Result) {
        searchFocused = false
        search.resolve(result) { name, coord in
            region.latitude = coord.latitude
            region.longitude = coord.longitude
            region.name = name
        }
    }

    /// Move the center and rename to match the new spot (reverse-geocoded). The stale guard keeps a
    /// slow geocode from clobbering a newer move.
    private func setCenter(_ coord: CLLocationCoordinate2D) {
        region.latitude = coord.latitude
        region.longitude = coord.longitude
        search.name(for: coord) { name in
            if region.latitude == coord.latitude, region.longitude == coord.longitude {
                region.name = name
            }
        }
    }

    private func recenter() { camera = .region(Self.span(for: region)) }
}

/// Drives the search overlay: debounced completion suggestions, then a `MKLocalSearch` to turn a
/// chosen suggestion into a coordinate.
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
