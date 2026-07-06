import Foundation

/// Tracks how much "unblocked" (distraction) time has been spent, bucketed by local day.
/// The enforcement layer (or a timer in the app) calls `record(_:at:)` as unblocked time
/// elapses; `afterUnblockedTime` conditions read `unblockedTime(on:)`.
///
/// Bucketing by day means the daily allowance resets naturally at local midnight without any
/// explicit reset step.
public struct DailyUsage: Codable, Sendable {
    private var secondsByDay: [String: TimeInterval]
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.secondsByDay = [:]
        self.calendar = calendar
    }

    private func key(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    public mutating func record(_ seconds: TimeInterval, at date: Date = Date()) {
        secondsByDay[key(for: date), default: 0] += seconds
    }

    public func unblockedTime(on date: Date = Date()) -> TimeInterval {
        secondsByDay[key(for: date)] ?? 0
    }

    /// Drop buckets older than `date`'s day so the store doesn't grow without bound.
    public mutating func pruneDays(before date: Date = Date()) {
        let cutoff = key(for: date)
        secondsByDay = secondsByDay.filter { $0.key >= cutoff }
    }
}
