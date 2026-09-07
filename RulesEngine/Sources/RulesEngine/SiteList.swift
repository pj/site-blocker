import Foundation

/// The redesigned model (shared by both apps): a **site list** is a named set of target hosts plus
/// an *ordered* list of **rules**. Each rule is an Allow or Deny that applies while its `condition`
/// (days + optional time-of-day) is true, optionally bounded by a daily time budget. The list also
/// carries a **default** used when no rule is active.
///
/// Resolution is *first active rule wins*: walk the rules top-to-bottom; the first enabled rule whose
/// condition matches the current moment decides the list's fate (Deny → blocked; Allow → allowed,
/// subject to its `dailyLimit` + the unlock state). If none match, fall back to the list default.
/// Evaluation is pure (`ListEngine`); the app supplies the clock/usage via `RuleContext`.

public enum RuleAction: String, Codable, Sendable, CaseIterable {
    case allow
    case deny
}

public struct ListRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var action: RuleAction
    /// When the rule applies — days + optional time-of-day (never a budget; that's `dailyLimit`).
    /// `.always` = whenever; `.onDaysOfWeek([])` = never.
    public var condition: Condition
    /// Optional daily budget (seconds) for an Allow rule: allowed until the shared pool passes it,
    /// and gated behind the manual unlock. Ignored for Deny rules.
    public var dailyLimit: TimeInterval?

    public init(id: UUID = UUID(), action: RuleAction = .deny,
                condition: Condition = .always, dailyLimit: TimeInterval? = nil) {
        self.id = id
        self.action = action
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
    public var rules: [ListRule]

    public init(id: UUID = UUID(), name: String = "", isEnabled: Bool = true,
                targets: [HostPattern] = [], source: TargetSource? = nil,
                rules: [ListRule] = []) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.targets = targets
        self.source = source ?? .manual(targets)
        self.rules = rules
    }

    /// A new list's starting rule — a catch-all Deny (blocked by default), which the UI adds
    /// automatically. It's an ordinary rule the user can edit or remove like any other.
    public static func defaultRule() -> ListRule { ListRule(action: .deny, condition: .always) }

    public enum Decision: Equatable, Sendable { case allowed, blocked }
}

public extension SiteList {
    /// Migrate a legacy single-schedule `Rule` into a list with its Allow rule (schedule + limit)
    /// followed by a catch-all Deny — reproducing the old "blocked by default, allowed in the
    /// window" behavior with ordinary rules.
    init(migrating rule: Rule) {
        self.init(id: rule.id, name: rule.name, isEnabled: rule.isEnabled,
                  targets: rule.targets, source: rule.source,
                  rules: [ListRule(action: .allow, condition: rule.condition, dailyLimit: rule.dailyLimit),
                          ListRule(action: .deny, condition: .always)])
    }
}

/// Pure evaluation of `[SiteList]` — the redesigned counterpart to `BlockEngine`.
public struct ListEngine: Sendable {
    public var lists: [SiteList]

    public init(lists: [SiteList] = []) { self.lists = lists }

    /// The current decision for one list: first active rule wins, else the default. `unlocked` +
    /// the shared `unblockedTimeToday` in `context` gate limited Allow rules.
    public func decision(for list: SiteList, unlocked: Bool, in context: RuleContext) -> SiteList.Decision {
        guard list.isEnabled else { return .allowed }
        for rule in list.rules {
            guard rule.condition.evaluate(in: context) else { continue }
            switch rule.action {
            case .deny:
                return .blocked
            case .allow:
                guard let limit = rule.dailyLimit else { return .allowed }
                return (unlocked && context.unblockedTimeToday < limit) ? .allowed : .blocked
            }
        }
        return .allowed   // no rule matched → not blocked
    }

    /// The rule currently deciding this list — the first whose condition is active right now — or
    /// `nil` if none match (the list falls through to "allowed") or the list is disabled. A limited
    /// Allow rule counts as active here even when its budget is spent: it's still the rule in force.
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
        for list in lists where list.isEnabled {
            for rule in list.rules where rule.action == .allow {
                guard let limit = rule.dailyLimit, rule.condition.evaluate(in: context) else { continue }
                let remaining = max(0, limit - context.unblockedTimeToday)
                best = max(best ?? 0, remaining)
            }
        }
        return best
    }
}
