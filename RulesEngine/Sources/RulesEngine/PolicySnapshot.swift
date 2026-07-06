import Foundation

/// The serializable hand-off between the app and the content-filter extension.
///
/// The app owns the rules and the usage clock; the extension is a thin evaluator. Rather than
/// live IPC on every flow, the app writes a `PolicySnapshot` into the shared App Group container
/// whenever anything relevant changes, and the extension reloads it and evaluates locally.
public struct PolicySnapshot: Codable, Sendable {
    public var rules: [Rule]
    public var unblockedTimeToday: TimeInterval
    public var updatedAt: Date

    public init(rules: [Rule], unblockedTimeToday: TimeInterval, updatedAt: Date = Date()) {
        self.rules = rules
        self.unblockedTimeToday = unblockedTimeToday
        self.updatedAt = updatedAt
    }

    /// Build the engine + context the extension uses to decide a flow. `now` is passed in so
    /// time-of-day and date conditions evaluate against the extension's current clock, while the
    /// slowly-changing usage total rides along in the snapshot.
    public func context(now: Date = Date(), calendar: Calendar = .current) -> RuleContext {
        RuleContext(now: now, calendar: calendar, unblockedTimeToday: unblockedTimeToday)
    }

    public var engine: BlockEngine { BlockEngine(rules: rules) }
}
