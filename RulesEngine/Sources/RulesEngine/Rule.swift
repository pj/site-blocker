import Foundation

/// Where a rule's site list comes from. Mutually exclusive: a rule is either hand-edited in the
/// app, backed by a local file managed externally, or backed by a downloaded blocklist.
public enum TargetSource: Codable, Hashable, Sendable {
    case manual([HostPattern])
    case file(bookmark: Data)
    case remote(URL)
}

/// A named allow-rule: a set of sites plus the window (days + time-of-day) during which — and a
/// daily time budget up to which — those sites may be viewed. Sites are blocked by default; a rule
/// carves out an allowance. Rules OR together: a site is viewable if *any* rule currently allows it.
public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var targets: [HostPattern]
    public var source: TargetSource
    /// The allow *window*: which weekdays and time-of-day the sites may be viewed. `.always` means
    /// any day/time. Never contains a quota — the budget lives in `dailyLimit`.
    public var condition: Condition
    /// Optional daily budget of viewing time (seconds). `nil` = unlimited within the window.
    public var dailyLimit: TimeInterval?

    public init(id: UUID = UUID(),
                name: String = "",
                isEnabled: Bool = true,
                targets: [HostPattern] = [],
                source: TargetSource? = nil,
                condition: Condition = .always,
                dailyLimit: TimeInterval? = nil) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.targets = targets
        self.source = source ?? .manual(targets)
        self.condition = condition
        self.dailyLimit = dailyLimit
    }

    /// Whether this rule's allow window is open at the given instant (ignores the budget, which the
    /// engine checks against usage).
    public func windowOpen(in context: RuleContext) -> Bool {
        isEnabled && condition.evaluate(in: context)
    }

    // MARK: Codable + migration

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, targets, source, condition, dailyLimit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        targets = try c.decode([HostPattern].self, forKey: .targets)
        source = try c.decodeIfPresent(TargetSource.self, forKey: .source) ?? .manual(targets)

        // Older rules stored the daily budget as an `afterUnblockedTime` atom *inside* the
        // condition (the previous "block after N minutes" model). Split it out into `dailyLimit`
        // and keep only the day/time window in `condition`.
        let storedCondition = try c.decode(Condition.self, forKey: .condition)
        let (window, extractedLimit) = storedCondition.splittingDailyLimit()
        condition = window
        dailyLimit = try c.decodeIfPresent(TimeInterval.self, forKey: .dailyLimit) ?? extractedLimit
    }
}
