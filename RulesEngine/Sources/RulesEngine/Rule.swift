import Foundation

/// Where a rule's blocked-site list comes from. Mutually exclusive: a rule is either hand-edited
/// in the app, backed by a local file managed externally, or backed by a downloaded blocklist.
public enum TargetSource: Codable, Hashable, Sendable {
    /// Hand-edited in the app; the list is the source of truth.
    case manual([HostPattern])
    /// A user-chosen local file (stored as a security-scoped bookmark so the sandboxed app can
    /// reopen it across launches). Re-read when the file changes.
    case file(bookmark: Data)
    /// A blocklist URL, re-fetched periodically.
    case remote(URL)
}

/// A named blocking rule: a target source plus the condition under which its sites are blocked.
public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// The resolved host list — what the engine evaluates. For `.manual` this mirrors the source;
    /// for `.file`/`.remote` it's the cache of the last successful read/fetch.
    public var targets: [HostPattern]
    public var source: TargetSource
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
        self.source = .manual(targets)
        self.condition = condition
    }

    public init(id: UUID = UUID(),
                name: String,
                isEnabled: Bool = true,
                source: TargetSource,
                condition: Condition) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.source = source
        if case .manual(let hosts) = source {
            self.targets = hosts
        } else {
            self.targets = []   // filled in once the file/URL resolves
        }
        self.condition = condition
    }

    /// Whether this rule is actively blocking right now.
    public func isActive(in context: RuleContext) -> Bool {
        isEnabled && condition.evaluate(in: context)
    }

    // MARK: Codable (rules saved before `source` existed migrate to `.manual`)

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, targets, source, condition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        targets = try container.decode([HostPattern].self, forKey: .targets)
        condition = try container.decode(Condition.self, forKey: .condition)
        source = try container.decodeIfPresent(TargetSource.self, forKey: .source)
            ?? .manual(targets)
    }
}
