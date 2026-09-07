import Foundation

/// The shared config the Mac publishes (a public gist, via `just publish-config`) and either app
/// imports from a URL. The Mac is the source of truth.
///
/// v2 carries **site lists** (`lists`), each with an ordered set of Allow/Deny rules. v1 (`rules`,
/// one schedule per list) is still decoded for a smooth transition — `toSiteLists()` handles both.
public struct SyncedConfig: Codable, Sendable {
    public var version: Int
    public var updatedAt: String
    public var lists: [SyncedList]?     // v2
    public var rules: [SyncedRule]?     // v1 (legacy)

    public init(version: Int, updatedAt: String,
                lists: [SyncedList]? = nil, rules: [SyncedRule]? = nil) {
        self.version = version
        self.updatedAt = updatedAt
        self.lists = lists
        self.rules = rules
    }

    /// The site lists to import, from whichever format the config is in.
    public func toSiteLists() -> [SiteList] {
        if let lists { return lists.map { $0.toSiteList() } }
        if let rules { return rules.map { SiteList(migrating: $0.toRule()) } }
        return []
    }

    /// A day/time window shared by both formats.
    public struct Window: Codable, Sendable {
        public var start: String        // "HH:MM"
        public var end: String
        public init(start: String, end: String) { self.start = start; self.end = end }
    }

    // MARK: v2 — a site list with ordered rules

    public struct SyncedList: Codable, Sendable {
        public var name: String
        public var enabled: Bool
        /// Inline domains (manual/file-sourced on the Mac). A `blocklistUrl` instead syncs the
        /// reference for big lists; importers fetch it.
        public var domains: [String]
        public var blocklistUrl: String?
        public var rules: [SyncedListRule]

        public init(name: String, enabled: Bool, domains: [String], blocklistUrl: String? = nil,
                    rules: [SyncedListRule]) {
            self.name = name; self.enabled = enabled; self.domains = domains
            self.blocklistUrl = blocklistUrl; self.rules = rules
        }

        public func toSiteList() -> SiteList {
            let inline = domains.map { HostPattern($0) }
            let source: TargetSource
            let targets: [HostPattern]
            if let blocklistUrl, let url = URL(string: blocklistUrl) {
                source = .remote(url); targets = []
            } else {
                targets = inline; source = .manual(inline)
            }
            return SiteList(name: name, isEnabled: enabled, targets: targets, source: source,
                            rules: rules.map { $0.toListRule() })
        }
    }

    public struct SyncedListRule: Codable, Sendable {
        public var action: String           // "allow" / "deny"
        public var days: [String]?          // nil = every day; present (incl. empty) = a constraint
        public var window: Window?          // nil = all day
        public var dailyLimitMinutes: Int?

        public init(action: String, days: [String]? = nil,
                    window: Window? = nil, dailyLimitMinutes: Int? = nil) {
            self.action = action; self.days = days
            self.window = window; self.dailyLimitMinutes = dailyLimitMinutes
        }

        public func toListRule() -> ListRule {
            var parts: [Condition] = []
            if let days {
                parts.append(.onDaysOfWeek(Set(days.compactMap(Weekday.init(abbreviation:)))))
            }
            if let window, let start = Self.minutes(window.start), let end = Self.minutes(window.end) {
                parts.append(.duringTimeOfDay(TimeWindow(startMinutes: start, endMinutes: end)))
            }
            let condition: Condition = parts.isEmpty ? .always
                : (parts.count == 1 ? parts[0] : .allOf(parts))
            return ListRule(action: action == "deny" ? .deny : .allow,
                            condition: condition,
                            dailyLimit: dailyLimitMinutes.map { TimeInterval($0 * 60) })
        }

        private static func minutes(_ hhmm: String) -> Int? {
            let parts = hhmm.split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            return h * 60 + m
        }
    }

    // MARK: v1 — one schedule per list (legacy)

    public struct SyncedRule: Codable, Sendable {
        public var name: String
        public var enabled: Bool
        public var domains: [String]
        public var blocklistUrl: String?
        public var days: [String]?
        public var window: Window?
        public var dailyLimitMinutes: Int?
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
