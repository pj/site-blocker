import Foundation

/// Tracks the single pool of "unblocked" viewing time spent today, bucketed by local day so the
/// budget resets naturally at local midnight. The app charges wall-clock time to today's bucket
/// while sites are unlocked; the engine compares this shared total against each rule's `dailyLimit`
/// (see `BlockEngine`). One total per day — not per rule — so all rules draw down the same pool.
public struct DailyUsage: Codable, Sendable, Equatable {
    /// Keyed by "<Y-M-D>".
    private var seconds: [String: TimeInterval]
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.seconds = [:]
        self.calendar = calendar
    }

    private func dayKey(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    public mutating func record(_ seconds: TimeInterval, at date: Date = Date()) {
        self.seconds[dayKey(for: date), default: 0] += seconds
    }

    /// Total unblocked time used on the given day.
    public func total(on date: Date = Date()) -> TimeInterval {
        seconds[dayKey(for: date)] ?? 0
    }

    /// Drop buckets from days other than `date` so the store doesn't grow without bound.
    public mutating func pruneDays(before date: Date = Date()) {
        let today = dayKey(for: date)
        seconds = seconds.filter { $0.key == today }
    }

    /// Merge another store in by taking the larger value for each day. Used when reconciling with
    /// iCloud: viewing time already spent on any device is never given back.
    public mutating func mergeTakingMax(_ other: DailyUsage) {
        for (key, value) in other.seconds {
            seconds[key] = Swift.max(seconds[key] ?? 0, value)
        }
    }
}
