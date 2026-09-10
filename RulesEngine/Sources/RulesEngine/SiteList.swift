import Foundation

/// The model (shared by both apps): a **site list** is a named set of target hosts with a **base
/// state** — blocked or allowed by default — plus an *ordered* list of **exceptions**. An exception
/// (`ListRule`) has no allow/deny of its own; while its `condition` (days + optional time-of-day) is
/// true it simply *flips* the base state: an allow-window on a blocked list, or a block-window on an
/// allowed list. An allow-window may carry a daily time budget.
///
/// Resolution: the first exception whose condition matches the current moment flips the base;
/// otherwise the base stands. Evaluation is pure (`ListEngine`); the app supplies the clock/usage via
/// `RuleContext`.

public struct ListRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// When this exception applies — days + optional time-of-day. `.always` = whenever;
    /// `.onDaysOfWeek([])` = never.
    public var condition: Condition
    /// Optional daily budget (seconds). Meaningful only for an *allow* window (a list that's blocked
    /// by default): the sites open until the shared pool passes this, gated behind the manual unlock.
    /// Ignored when the list is allowed by default (a block-window has no budget).
    public var dailyLimit: TimeInterval?

    public init(id: UUID = UUID(), condition: Condition = .always, dailyLimit: TimeInterval? = nil) {
        self.id = id
        self.condition = condition
        self.dailyLimit = dailyLimit
    }
}

public struct SiteList: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Resolved hosts this list governs (from `source`).
    public var targets: [HostPattern]
    /// Where the targets come from: hand-edited, a local file, or a downloaded blocklist.
    public var source: TargetSource
    /// The list's base state. Its `rules` are exceptions that flip this while active.
    public var isBlockedByDefault: Bool
    public var rules: [ListRule]

    public init(id: UUID = UUID(), name: String = "", isEnabled: Bool = true,
                targets: [HostPattern] = [], source: TargetSource? = nil,
                isBlockedByDefault: Bool = true, rules: [ListRule] = []) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.targets = targets
        self.source = source ?? .manual(targets)
        self.isBlockedByDefault = isBlockedByDefault
        self.rules = rules
    }

    public enum Decision: Equatable, Sendable { case allowed, blocked }
}

public extension SiteList {
    /// Migrate a legacy single-schedule `Rule` into a blocked-by-default list with one allow-window
    /// exception carrying its schedule + limit — reproducing the old "blocked by default, allowed in
    /// the window" behavior.
    init(migrating rule: Rule) {
        self.init(id: rule.id, name: rule.name, isEnabled: rule.isEnabled,
                  targets: rule.targets, source: rule.source,
                  isBlockedByDefault: true,
                  rules: [ListRule(condition: rule.condition, dailyLimit: rule.dailyLimit)])
    }
}

/// Pure evaluation of `[SiteList]` — the redesigned counterpart to `BlockEngine`.
public struct ListEngine: Sendable {
    public var lists: [SiteList]

    public init(lists: [SiteList] = []) { self.lists = lists }

    /// The current decision for one list: the first active exception flips the base state, else the
    /// base stands. `unlocked` + the shared `unblockedTimeToday` in `context` gate a budgeted
    /// allow-window (only relevant on a blocked-by-default list).
    public func decision(for list: SiteList, unlocked: Bool, in context: RuleContext) -> SiteList.Decision {
        guard list.isEnabled else { return .allowed }
        if let exception = list.rules.first(where: { $0.condition.evaluate(in: context) }) {
            if list.isBlockedByDefault {
                // Allow-window: opens the list, subject to any daily budget + the unlock state.
                guard let limit = exception.dailyLimit else { return .allowed }
                return (unlocked && context.unblockedTimeToday < limit) ? .allowed : .blocked
            } else {
                return .blocked   // block-window on an allowed list
            }
        }
        return list.isBlockedByDefault ? .blocked : .allowed
    }

    /// The exception currently in force for this list — the first whose condition is active right
    /// now — or `nil` if none match (the list's base state stands) or the list is disabled. A
    /// budgeted allow-window counts as active here even when its budget is spent.
    public func activeRule(for list: SiteList, in context: RuleContext) -> ListRule? {
        guard list.isEnabled else { return nil }
        return list.rules.first { $0.condition.evaluate(in: context) }
    }

    /// Every host blocked right now across all lists.
    public func blockedPatterns(unlocked: Bool, in context: RuleContext) -> Set<HostPattern> {
        var blocked: Set<HostPattern> = []
        for list in lists where decision(for: list, unlocked: unlocked, in: context) == .blocked {
            blocked.formUnion(list.targets)
        }
        return blocked
    }

    /// True when unlocking would open at least one list (a limited Allow rule is the active decision
    /// with budget remaining). Drives whether the Unlock control is offered.
    public func canUnlock(in context: RuleContext) -> Bool {
        lists.contains {
            decision(for: $0, unlocked: false, in: context) == .blocked
                && decision(for: $0, unlocked: true, in: context) == .allowed
        }
    }

    /// True when some list is open via a no-limit Allow rule (auto-open, no unlock needed).
    public func openAccessActive(in context: RuleContext) -> Bool {
        lists.contains {
            !$0.targets.isEmpty
                && decision(for: $0, unlocked: false, in: context) == .allowed
        }
    }

    /// Remaining budget in the current unlock session: the largest remaining limit among limited
    /// Allow rules that are the active decision right now. `nil` when nothing budgeted is active.
    public func sessionRemaining(in context: RuleContext) -> TimeInterval? {
        var best: TimeInterval?
        for list in lists where list.isEnabled && list.isBlockedByDefault {
            for rule in list.rules {
                guard let limit = rule.dailyLimit, rule.condition.evaluate(in: context) else { continue }
                let remaining = max(0, limit - context.unblockedTimeToday)
                best = max(best ?? 0, remaining)
            }
        }
        return best
    }
}
