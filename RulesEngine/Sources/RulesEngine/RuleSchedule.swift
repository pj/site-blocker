import Foundation

/// A decomposed, UI-friendly view of a rule's schedule: which weekdays it applies, an optional
/// time-of-day window, and an optional daily budget. Bridges to/from the engine's `Condition` +
/// `dailyLimit` so both apps can edit schedules with the same controls.
public struct RuleSchedule: Equatable, Sendable {
    /// All selected = every day (no weekday constraint); none selected = never.
    public var days: Set<Weekday>
    public var timeEnabled: Bool
    public var window: TimeWindow
    public var quotaEnabled: Bool
    public var quotaMinutes: Int

    public static let everyDay = Set(Weekday.allCases)

    public init(days: Set<Weekday> = everyDay,
                timeEnabled: Bool = false,
                window: TimeWindow = TimeWindow(startHour: 9, endHour: 17),
                quotaEnabled: Bool = false,
                quotaMinutes: Int = 30) {
        self.days = days
        self.timeEnabled = timeEnabled
        self.window = window
        self.quotaEnabled = quotaEnabled
        self.quotaMinutes = quotaMinutes
    }

    /// Decompose a rule's condition + daily limit into the controls.
    public init(condition: Condition, dailyLimit: TimeInterval?) {
        self.init()
        collect(condition)
        if let dailyLimit {
            quotaEnabled = true
            quotaMinutes = max(1, Int(dailyLimit / 60))
        }
    }

    private mutating func collect(_ condition: Condition) {
        switch condition {
        case .onDaysOfWeek(let d): days = d
        case .duringTimeOfDay(let w): timeEnabled = true; window = w
        case .allOf(let list): list.forEach { collect($0) }
        default: break
        }
    }

    /// The day/time window as a `Condition`. All days selected drops the weekday constraint; *no*
    /// days selected pins an empty set, which never matches (a rule that never applies).
    public var condition: Condition {
        var parts: [Condition] = []
        if days.isEmpty {
            parts.append(.onDaysOfWeek([]))
        } else if days != Self.everyDay {
            parts.append(.onDaysOfWeek(days))
        }
        if timeEnabled { parts.append(.duringTimeOfDay(window)) }
        switch parts.count {
        case 0:  return .always
        case 1:  return parts[0]
        default: return .allOf(parts)
        }
    }

    /// The daily budget in seconds, or `nil` when the limit control is off.
    public var dailyLimit: TimeInterval? {
        quotaEnabled ? TimeInterval(quotaMinutes * 60) : nil
    }
}

// MARK: - Weekday labels (shared by both apps)

public extension Weekday {
    /// Single-letter label for compact day toggles.
    var letter: String {
        switch self {
        case .sunday, .saturday: "S"
        case .monday:            "M"
        case .tuesday, .thursday: "T"
        case .wednesday:         "W"
        case .friday:            "F"
        }
    }

    var shortLabel: String {
        switch self {
        case .sunday:    "Sun"
        case .monday:    "Mon"
        case .tuesday:   "Tue"
        case .wednesday: "Wed"
        case .thursday:  "Thu"
        case .friday:    "Fri"
        case .saturday:  "Sat"
        }
    }

    /// Alias kept for existing call sites.
    var shortName: String { shortLabel }
}
