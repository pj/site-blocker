import Foundation

/// External-signal sources an exception can key off, beyond a plain day/time schedule. Each carries
/// enough to (a) tell the app what to watch and (b) evaluate purely: the engine never touches
/// EventKit / Focus / Core Location itself — the app resolves which of these are *active right now*
/// and passes the active identifiers in via `RuleContext`. Conditions then just test membership.

/// A calendar whose events drive an exception — e.g. an "active" US-holidays calendar opens a list
/// on holidays. `id` is the platform calendar identifier; `title` is for display.
public struct CalendarSource: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A system Focus that drives an exception. There's no public API to read the current Focus, so the
/// app exposes a **Focus Filter** the user attaches to a Focus; when that Focus is active the system
/// activates the filter and the app records `id` as active. `name` is the user-facing label.
public struct FocusSource: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

/// A circular geofence that drives an exception (the app monitors it via Core Location and reports
/// whether the device is currently inside). Radius is in meters.
public struct GeoRegion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radius: Double

    public init(id: String = UUID().uuidString, name: String,
                latitude: Double, longitude: Double, radius: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }
}

/// The distinct external-signal sources referenced across a set of lists' exceptions — what the app
/// needs to resolve (calendars to query, Focus filters to expect, regions to monitor).
public extension Sequence where Element == SiteList {
    var referencedCalendars: [CalendarSource] {
        uniqued(flatMap { $0.rules.flatMap { $0.condition.collectSources().calendars } })
    }
    var referencedFocuses: [FocusSource] {
        uniqued(flatMap { $0.rules.flatMap { $0.condition.collectSources().focuses } })
    }
    var referencedRegions: [GeoRegion] {
        uniqued(flatMap { $0.rules.flatMap { $0.condition.collectSources().regions } })
    }
}

/// Keep the first occurrence of each `id`, preserving order.
private func uniqued<T: Identifiable>(_ items: [T]) -> [T] where T.ID: Hashable {
    var seen = Set<T.ID>()
    return items.filter { seen.insert($0.id).inserted }
}
