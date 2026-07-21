import Foundation

/// The serializable hand-off between the app and the content-filter extension.
///
/// All the allow-model logic (windows, per-rule budgets, lock state, unlock timing) lives in the
/// app. Rather than duplicate it in the extension, the app resolves the current blocked set and
/// writes just that: the extension is a thin membership check. The app rewrites the snapshot
/// whenever the blocked set changes (and on a short timer, so windows/budgets take effect).
public struct PolicySnapshot: Codable, Sendable {
    /// Where the app writes and the extension reads the snapshot. A fixed path under `/Users/Shared`
    /// (user-writable, root-readable) rather than an App Group container: the content-filter system
    /// extension runs as **root**, so its per-user group container (`/var/root/…`) does not match
    /// the app's (`/Users/<you>/…`) and the hand-off silently fails.
    public static let fileURL = URL(fileURLWithPath: "/Users/Shared/SiteBlocker/policy.json")

    public var blockedPatterns: [HostPattern]
    public var updatedAt: Date

    public init(blockedPatterns: Set<HostPattern>, updatedAt: Date = Date()) {
        self.blockedPatterns = Array(blockedPatterns)
        self.updatedAt = updatedAt
    }

    /// Whether a concrete hostname (as the filter sees it on a flow) is currently blocked.
    public func isBlocked(hostname: String) -> Bool {
        blockedPatterns.contains { $0.matches(hostname: hostname) }
    }
}
