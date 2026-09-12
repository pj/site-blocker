import Foundation
import CoreLocation
import RulesEngine

/// App-group store of which geofenced regions the device is currently inside. Persisted so it
/// survives background relaunches (region crossings can wake the app when it isn't running) and is
/// readable from `MobileEnforcer.context()` / the background-refresh handler.
enum LocationBridge {
    private static let appGroup = "group.com.pauljohnson.siteblocker"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    private static let key = "insideRegionIDs"

    static var insideRegionIDs: Set<String> {
        Set(defaults?.stringArray(forKey: key) ?? [])
    }
    static func set(_ ids: Set<String>) { defaults?.set(Array(ids), forKey: key) }
}

/// Monitors the geofenced regions referenced by location exceptions and records which the device is
/// inside (into `LocationBridge`). `onChange` fires so the store can rebuild the Safari ruleset.
@MainActor
final class LocationMonitor: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var monitored: [String: GeoRegion] = [:]
    private var inside: Set<String> = LocationBridge.insideRegionIDs
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
            inside.remove(id)
        }
        for (id, region) in want where monitored[id] != region {   // added or changed
            let clr = clRegion(region)
            manager.startMonitoring(for: clr)
            manager.requestState(for: clr)   // seed the initial inside/outside state
        }
        monitored = want

        if want.isEmpty {
            manager.stopUpdatingLocation()
            if !inside.isEmpty { inside.removeAll(); LocationBridge.set(inside); onChange?() }
            return
        }
        LocationBridge.set(inside)
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

    private func setInside(_ id: String, _ isInside: Bool) {
        let changed = isInside ? inside.insert(id).inserted : (inside.remove(id) != nil)
        guard changed else { return }
        LocationBridge.set(inside)
        onChange?()
    }

    /// Recompute which monitored regions contain `coord` by distance — the primary inside/outside
    /// signal, so a list opens even if we were already inside when monitoring began.
    private func recomputeInside(at coord: CLLocationCoordinate2D) {
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var changed = false
        for (id, r) in monitored {
            let isInside = here.distance(from: CLLocation(latitude: r.latitude, longitude: r.longitude)) <= r.radius
            if isInside {
                if inside.insert(id).inserted { changed = true }
            } else if inside.remove(id) != nil {
                changed = true
            }
        }
        if changed { LocationBridge.set(inside); onChange?() }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ m: CLLocationManager, didDetermineState state: CLRegionState,
                                     for region: CLRegion) {
        let id = region.identifier, isInside = state == .inside
        Task { @MainActor in self.setInside(id, isInside) }
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
