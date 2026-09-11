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
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorized: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    func requestAccess() { manager.requestAlwaysAuthorization() }

    /// The most recent fix, so the UI can offer "use my current location".
    var currentCoordinate: CLLocationCoordinate2D? { manager.location?.coordinate }

    /// Start/stop monitoring so exactly `regions` are watched.
    func update(regions: [GeoRegion]) {
        let want = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, region) in monitored where want[id] == nil {
            manager.stopMonitoring(for: clRegion(region))
            insideRegionIDs.remove(id)
        }
        for (id, region) in want where monitored[id] == nil {
            let clr = clRegion(region)
            manager.startMonitoring(for: clr)
            manager.requestState(for: clr)   // seed the initial inside/outside state
        }
        monitored = want
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

    private func setInside(_ id: String, _ inside: Bool) {
        let changed = inside ? insideRegionIDs.insert(id).inserted : (insideRegionIDs.remove(id) != nil)
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
        Task { @MainActor in self.onChange?() }
    }
}
