import Foundation

/// Tracks per-rule viewing time spent today, bucketed by local day so each rule's daily budget
/// resets naturally at local midnight. The app records time against a rule while that rule's sites
/// are unlocked and viewable; the engine compares it to the rule's `dailyLimit`.
public struct DailyUsage: Codable, Sendable, Equatable {
    /// Keyed by "<ruleID>|<Y-M-D>".
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

    private func key(rule: UUID, date: Date) -> String {
        "\(rule.uuidString)|\(dayKey(for: date))"
    }

    public mutating func record(_ seconds: TimeInterval, rule: UUID, at date: Date = Date()) {
        self.seconds[key(rule: rule, date: date), default: 0] += seconds
    }

    public func usage(rule: UUID, on date: Date = Date()) -> TimeInterval {
        seconds[key(rule: rule, date: date)] ?? 0
    }

    /// Total viewing time across all rules today — for the summary in the window header.
    public func totalUsage(on date: Date = Date()) -> TimeInterval {
        let suffix = "|\(dayKey(for: date))"
        return seconds.filter { $0.key.hasSuffix(suffix) }.values.reduce(0, +)
    }

    /// Drop buckets from days before `date` so the store doesn't grow without bound.
    public mutating func pruneDays(before date: Date = Date()) {
        let today = "|\(dayKey(for: date))"
        seconds = seconds.filter { $0.key.hasSuffix(today) }
    }

    /// Merge another store in by taking the larger value for each (rule, day) bucket. Used when
    /// reconciling with iCloud: viewing time already spent on any device is never given back.
    public mutating func mergeTakingMax(_ other: DailyUsage) {
        for (key, value) in other.seconds {
            seconds[key] = Swift.max(seconds[key] ?? 0, value)
        }
    }
}
