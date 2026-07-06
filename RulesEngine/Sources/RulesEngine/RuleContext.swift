import Foundation

/// Everything the engine needs to evaluate conditions at one instant. Passing this in (rather
/// than reading the clock / usage store inside the engine) keeps evaluation pure and testable.
public struct RuleContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    /// Accumulated "unblocked" (distraction) time spent so far today, in seconds.
    public var unblockedTimeToday: TimeInterval

    public init(now: Date = Date(),
                calendar: Calendar = .current,
                unblockedTimeToday: TimeInterval = 0) {
        self.now = now
        self.calendar = calendar
        self.unblockedTimeToday = unblockedTimeToday
    }
}
