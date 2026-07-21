import Foundation

/// Pure evaluation of the allow model. Sites named by any rule are blocked by default; a rule
/// *allows* its sites while its window is open, it has budget left, and the user has unlocked.
/// Rules OR together: a site is viewable if any rule currently allows it. Holds no clock or I/O —
/// the app drives it with a `RuleContext` and a per-rule usage lookup.
public struct BlockEngine: Sendable {
    public var rules: [Rule]

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    /// Every site that some enabled rule governs — the universe that can be blocked.
    public func allTargets() -> Set<HostPattern> {
        var out: Set<HostPattern> = []
        for rule in rules where rule.isEnabled { out.formUnion(rule.targets) }
        return out
    }

    /// Whether a rule can currently be unlocked: enabled, window open, and budget remaining.
    public func isEligible(_ rule: Rule, in context: RuleContext,
                           usage: (UUID) -> TimeInterval) -> Bool {
        guard rule.windowOpen(in: context) else { return false }
        guard let limit = rule.dailyLimit else { return true }
        return usage(rule.id) < limit
    }

    /// Rules currently eligible to be unlocked. Drives whether unlock is offered and which budgets
    /// drain while unlocked.
    public func eligibleRules(in context: RuleContext,
                              usage: (UUID) -> TimeInterval) -> [Rule] {
        rules.filter { isEligible($0, in: context, usage: usage) }
    }

    /// The set of host patterns blocked right now. When locked, that's every governed site; when
    /// unlocked, it's every governed site minus those any eligible rule allows.
    public func blockedPatterns(unlocked: Bool, in context: RuleContext,
                                usage: (UUID) -> TimeInterval) -> Set<HostPattern> {
        let all = allTargets()
        guard unlocked else { return all }
        var allowed: Set<HostPattern> = []
        for rule in eligibleRules(in: context, usage: usage) { allowed.formUnion(rule.targets) }
        return all.subtracting(allowed)
    }
}
