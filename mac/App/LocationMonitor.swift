import Foundation
import CoreLocation
import RulesEngine

/// Monitors the geofenced regions referenced by location exceptions and tracks which ones the
/// device is currently inside. The engine stays Core-Location-free; this feeds
/// `RuleContext.insideRegionIDs`. `onChange` fires whenever the inside-set changes so the store
/// can re-evaluate.
@MainActor
final class LocationMonitor: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var insideRegionIDs: Set<String> = []
    private var monitored: [String: GeoRegion] = [:]
    private var lastFix: CLLocationCoordinate2D?
    var onChange: (() -> Void)?
    /// Fires when a fresh location fix arrives, so the editor can seed a new exception at "here".
    var onLocation: ((CLLocationCoordinate2D) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    func requestAccess() {
        manager.requestAlwaysAuthorization()
        requestCurrentLocation()
    }

    /// Ask for a one-shot fix (for seeding / "use my current location"). Harmless if unauthorized —
    /// the fix simply never arrives.
    func requestCurrentLocation() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestLocation()
    }

    /// The most recent fix, so the UI can default a new exception to where you are now.
    var currentCoordinate: CLLocationCoordinate2D? { manager.location?.coordinate ?? lastFix }

    /// Start/stop monitoring so exactly `regions` are watched. Regions whose geometry changed (same
    /// id, moved/resized) are torn down and restarted so the geofence tracks the edit.
    func update(regions: [GeoRegion]) {
        let want = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, region) in monitored where want[id] != region {   // removed or changed
            manager.stopMonitoring(for: clRegion(region))
            insideRegionIDs.remove(id)
        }
        for (id, region) in want where monitored[id] != region {   // added or changed
            let clr = clRegion(region)
            manager.startMonitoring(for: clr)
            manager.requestState(for: clr)   // seed the initial inside/outside state
        }
        monitored = want

        if want.isEmpty {
            manager.stopUpdatingLocation()
            if !insideRegionIDs.isEmpty { insideRegionIDs.removeAll(); onChange?() }
            return
        }
        if !authorized { requestAccess() }
        // Region entry/exit events only fire on transitions; continuous fixes let us compute
        // inside/outside by distance too (reliable in the foreground and under WhenInUse).
        manager.startUpdatingLocation()
        if let c = lastFix { recomputeInside(at: c) }
    }

    private func clRegion(_ r: GeoRegion) -> CLCircularRegion {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude),
            radius: r.radius, identifier: r.id)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        return region
    }

    private func setInside(_ id: String, _ inside: Bool) {
        let changed = inside ? insideRegionIDs.insert(id).inserted : (insideRegionIDs.remove(id) != nil)
        if changed { onChange?() }
    }

    /// Recompute which monitored regions contain `coord` by distance — the primary inside/outside
    /// signal, so a list opens even if we were already inside when monitoring began.
    private func recomputeInside(at coord: CLLocationCoordinate2D) {
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var changed = false
        for (id, r) in monitored {
            let inside = here.distance(from: CLLocation(latitude: r.latitude, longitude: r.longitude)) <= r.radius
            if inside {
                if insideRegionIDs.insert(id).inserted { changed = true }
            } else if insideRegionIDs.remove(id) != nil {
                changed = true
            }
        }
        if changed { onChange?() }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ m: CLLocationManager, didDetermineState state: CLRegionState,
                                     for region: CLRegion) {
        let id = region.identifier, inside = state == .inside
        Task { @MainActor in self.setInside(id, inside) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.setInside(id, true) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.setInside(id, false) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            if self.authorized {
                self.requestCurrentLocation()
                if !self.monitored.isEmpty { self.manager.startUpdatingLocation() }
            }
            self.onChange?()
        }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let coord = locs.last?.coordinate else { return }
        Task { @MainActor in
            self.lastFix = coord
            self.onLocation?(coord)
            self.recomputeInside(at: coord)
        }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
