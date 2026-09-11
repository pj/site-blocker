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
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorized: Bool { manager.authorizationStatus == .authorizedAlways }
    func requestAccess() { manager.requestAlwaysAuthorization() }
    var currentCoordinate: CLLocationCoordinate2D? { manager.location?.coordinate }

    func update(regions: [GeoRegion]) {
        let want = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, region) in monitored where want[id] == nil {
            manager.stopMonitoring(for: clRegion(region))
            inside.remove(id)
        }
        for (id, region) in want where monitored[id] == nil {
            let clr = clRegion(region)
            manager.startMonitoring(for: clr)
            manager.requestState(for: clr)
        }
        monitored = want
        LocationBridge.set(inside)
        if !want.isEmpty && !authorized { requestAccess() }
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
        Task { @MainActor in self.onChange?() }
    }
}
