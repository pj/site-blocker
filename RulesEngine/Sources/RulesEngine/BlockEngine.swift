import Foundation

/// The result of asking whether a concrete hostname should be blocked.
public struct Decision: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case allowed
        case blocked(ruleID: UUID, ruleName: String, matched: HostPattern)
    }

    public var outcome: Outcome

    public var isBlocked: Bool {
        if case .blocked = outcome { return true }
        return false
    }
}

/// Pure evaluation over a set of rules. Deliberately holds no clock, no I/O and no enforcement:
/// the same engine runs in the app (to preview status) and in the content-filter extension
/// (to decide live flows).
public struct BlockEngine: Sendable {
    public var rules: [Rule]

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    /// The union of host patterns that are actively blocked right now. Useful for a "what's
    /// blocked at the moment" view and for coarse enforcers that take a flat blocklist.
    public func blockedPatterns(in context: RuleContext) -> Set<HostPattern> {
        var out: Set<HostPattern> = []
        for rule in rules where rule.isActive(in: context) {
            out.formUnion(rule.targets)
        }
        return out
    }

    /// Decide a concrete hostname (as the content filter sees it on a flow). Returns the first
    /// active rule whose targets match, so the UI can explain *why* something was blocked.
    public func decision(forHostname hostname: String, in context: RuleContext) -> Decision {
        for rule in rules where rule.isActive(in: context) {
            if let match = rule.targets.first(where: { $0.matches(hostname: hostname) }) {
                return Decision(outcome: .blocked(ruleID: rule.id, ruleName: rule.name, matched: match))
            }
        }
        return Decision(outcome: .allowed)
    }
}
