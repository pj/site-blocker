import Foundation

/// Everything the engine needs to evaluate conditions at one instant. Passing this in (rather
/// than reading the clock / usage store inside the engine) keeps evaluation pure and testable.
public struct RuleContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    /// Accumulated "unblocked" (distraction) time spent so far today, in seconds.
    public var unblockedTimeToday: TimeInterval

    /// Resolved external signals — the app fills these before evaluating so the engine stays pure.
    /// Identifiers of calendars that have an event active right now.
    public var activeCalendarIDs: Set<String>
    /// Identifiers of Focus filters currently active (a Focus the user attached our filter to is on).
    public var activeFocusIDs: Set<String>
    /// Identifiers of geofenced regions the device is currently inside.
    public var insideRegionIDs: Set<String>

    public init(now: Date = Date(),
                calendar: Calendar = .current,
                unblockedTimeToday: TimeInterval = 0,
                activeCalendarIDs: Set<String> = [],
                activeFocusIDs: Set<String> = [],
                insideRegionIDs: Set<String> = []) {
        self.now = now
        self.calendar = calendar
        self.unblockedTimeToday = unblockedTimeToday
        self.activeCalendarIDs = activeCalendarIDs
        self.activeFocusIDs = activeFocusIDs
        self.insideRegionIDs = insideRegionIDs
    }
}
