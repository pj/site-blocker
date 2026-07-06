import Foundation

/// A named blocking rule: a set of targets plus the condition under which they are blocked.
public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var targets: [HostPattern]
    public var condition: Condition

    public init(id: UUID = UUID(),
                name: String,
                isEnabled: Bool = true,
                targets: [HostPattern],
                condition: Condition) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.targets = targets
        self.condition = condition
    }

    /// Whether this rule is actively blocking right now.
    public func isActive(in context: RuleContext) -> Bool {
        isEnabled && condition.evaluate(in: context)
    }
}
