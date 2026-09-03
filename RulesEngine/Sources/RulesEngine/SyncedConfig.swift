import Foundation

/// The shared rules config the Mac publishes (a public gist, via `just publish-config`) and either
/// app imports from a URL in Settings. The Mac is the source of truth. macOS maps each entry back
/// into a full `Rule` (see `toRule()`); the iOS site-only build applies just the domains + enabled
/// flag (it has no scheduler, so days/window/limit don't apply there).
public struct SyncedConfig: Codable, Sendable {
    public var version: Int
    public var updatedAt: String
    public var rules: [SyncedRule]

    public struct SyncedRule: Codable, Sendable {
        public var name: String
        public var enabled: Bool
        /// Inline domains (manual / file-sourced rules on the Mac).
        public var domains: [String]
        /// A remote blocklist URL — the Mac syncs the *reference* for big lists, not the resolved
        /// domains; importers fetch it.
        public var blocklistUrl: String?
        public var days: [String]?          // e.g. ["mon","tue"]; nil = every day
        public var window: Window?          // nil = all day
        public var dailyLimitMinutes: Int?

        public struct Window: Codable, Sendable {
            public var start: String        // "HH:MM"
            public var end: String
        }
    }
}

public extension SyncedConfig.SyncedRule {
    /// Map this config entry into a full macOS `Rule`. A `blocklistUrl` becomes a `.remote` source
    /// (resolved on refresh); otherwise the inline domains become a `.manual` source. Day/time map
    /// into the rule's `condition`; a missing schedule means `.always`.
    func toRule() -> Rule {
        var parts: [Condition] = []
        // `days == nil` means every day (no weekday constraint). A *present* list pins a weekday
        // constraint — even when empty: no days = an `.onDaysOfWeek([])` that never opens = a
        // permanent block. This matches iOS `MobileRule.condition`, so an empty-days rule (e.g. an
        // always-on ad blocklist) means the same thing whichever platform imports the config.
        if let days {
            parts.append(.onDaysOfWeek(Set(days.compactMap(Weekday.init(abbreviation:)))))
        }
        if let window, let start = Self.minutes(window.start), let end = Self.minutes(window.end) {
            parts.append(.duringTimeOfDay(TimeWindow(startMinutes: start, endMinutes: end)))
        }
        let condition: Condition = parts.isEmpty ? .always
            : (parts.count == 1 ? parts[0] : .allOf(parts))

        let source: TargetSource
        let targets: [HostPattern]
        if let blocklistUrl, let url = URL(string: blocklistUrl) {
            source = .remote(url)
            targets = []
        } else {
            targets = domains.map { HostPattern($0) }
            source = .manual(targets)
        }
        return Rule(name: name, isEnabled: enabled, targets: targets, source: source,
                    condition: condition, dailyLimit: dailyLimitMinutes.map { TimeInterval($0 * 60) })
    }

    private static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

public extension Weekday {
    init?(abbreviation: String) {
        switch abbreviation.lowercased() {
        case "sun": self = .sunday
        case "mon": self = .monday
        case "tue": self = .tuesday
        case "wed": self = .wednesday
        case "thu": self = .thursday
        case "fri": self = .friday
        case "sat": self = .saturday
        default: return nil
        }
    }
}
