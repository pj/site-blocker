import Foundation

/// Pure evaluation of the allow model. Sites named by any rule are blocked by default; a rule
/// *allows* its sites while its window is open, the shared daily budget hasn't passed the rule's
/// limit, and the user has unlocked. Rules OR together: a site is viewable if any rule currently
/// allows it. Holds no clock or I/O — the app drives it with a `RuleContext`.
///
/// Budget model: there is a *single* pool of unblocked time used today
/// (`RuleContext.unblockedTimeToday`), which drains at wall-clock rate while unlocked. Each rule's
/// `dailyLimit` is a threshold on that shared pool — the rule's sites stay allowed until the pool
/// reaches its limit. Rules with smaller limits cut off first; the overall cap is the largest limit
/// among the active rules.
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

    /// Whether a rule currently allows its sites: enabled, window open, and the shared pool of
    /// unblocked time hasn't yet reached this rule's daily limit.
    public func isEligible(_ rule: Rule, in context: RuleContext) -> Bool {
        guard rule.windowOpen(in: context) else { return false }
        guard let limit = rule.dailyLimit else { return true }
        return context.unblockedTimeToday < limit
    }

    /// Rules currently allowing their sites. Drives whether unlock is offered and, while unlocked,
    /// which sites are viewable.
    public func eligibleRules(in context: RuleContext) -> [Rule] {
        rules.filter { isEligible($0, in: context) }
    }

    /// The set of host patterns blocked right now. When locked, that's every governed site; when
    /// unlocked, it's every governed site minus those any eligible rule allows.
    public func blockedPatterns(unlocked: Bool, in context: RuleContext) -> Set<HostPattern> {
        let all = allTargets()
        guard unlocked else { return all }
        var allowed: Set<HostPattern> = []
        for rule in eligibleRules(in: context) { allowed.formUnion(rule.targets) }
        return all.subtracting(allowed)
    }
}
