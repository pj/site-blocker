import Foundation

/// Abstraction over whatever actually enforces blocking.
///
/// On a provisioned Mac this is backed by the `NEFilterDataProvider` system extension (see
/// `mac/App/SystemExtensionEnforcer.swift`). While the Network Extension isn't provisioned we
/// run `MockEnforcer` instead, so the rules engine and UI can be exercised end to end.
public protocol Enforcer: AnyObject {
    /// Push the current set of actively-blocked host patterns to the enforcement layer.
    func apply(blockedPatterns: Set<HostPattern>)
}

/// In-memory stand-in for the Network Extension. Records what *would* be blocked and notifies
/// observers, so the app behaves identically to the real thing minus actual packet dropping.
public final class MockEnforcer: Enforcer, @unchecked Sendable {
    public private(set) var currentlyBlocked: Set<HostPattern> = []
    public private(set) var history: [(date: Date, patterns: Set<HostPattern>)] = []

    /// Called on the main queue whenever the blocked set changes.
    public var onChange: ((Set<HostPattern>) -> Void)?

    public init() {}

    public func apply(blockedPatterns: Set<HostPattern>) {
        guard blockedPatterns != currentlyBlocked else { return }
        currentlyBlocked = blockedPatterns
        history.append((Date(), blockedPatterns))
        onChange?(blockedPatterns)
    }
}
