import Foundation

public enum Weekday: Int, Codable, Sendable, CaseIterable, Comparable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A window within a day, expressed as minutes since local midnight.
/// Supports wrap-around windows (e.g. 22:00–06:00).
public struct TimeWindow: Codable, Hashable, Sendable {
    public var startMinutes: Int   // 0..<1440
    public var endMinutes: Int     // 0..<1440

    public init(startMinutes: Int, endMinutes: Int) {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    public init(startHour: Int, startMinute: Int = 0, endHour: Int, endMinute: Int = 0) {
        self.init(startMinutes: startHour * 60 + startMinute,
                  endMinutes: endHour * 60 + endMinute)
    }

    /// True when `date`'s local time-of-day falls within `[start, end)`.
    /// If the window wraps past midnight, membership is `>= start || < end`.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let m = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if startMinutes <= endMinutes {
            return m >= startMinutes && m < endMinutes
        } else {
            return m >= startMinutes || m < endMinutes
        }
    }
}

/// A closed calendar-date range (both ends inclusive).
public struct DateRange: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }
}
