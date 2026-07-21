import Foundation
import RulesEngine

/// The three static conditions a rule can carry, edited as always-present controls (no chips):
/// which weekdays it applies, an optional time-of-day window, and an optional daily allowance of
/// unblocked time. They AND together; for OR, add another rule (the engine ORs rules).
struct RuleSchedule: Equatable {
    /// All selected = every day (no weekday constraint).
    var days: Set<Weekday>
    var timeEnabled: Bool
    var window: TimeWindow
    var quotaEnabled: Bool
    var quotaMinutes: Int

    static let everyDay = Set(Weekday.allCases)

    init(days: Set<Weekday> = everyDay,
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

    /// Decompose a rule's allow window + daily limit into the three controls. The window `condition`
    /// carries only days/time; the budget arrives separately as `dailyLimit`.
    init(condition: Condition, dailyLimit: TimeInterval?) {
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

    /// The allow *window* — days + time-of-day only (the budget lives in `dailyLimit`). An all-days
    /// (or empty) selection drops the weekday constraint rather than producing an unusable rule.
    var condition: Condition {
        var parts: [Condition] = []
        if days != Self.everyDay && !days.isEmpty { parts.append(.onDaysOfWeek(days)) }
        if timeEnabled { parts.append(.duringTimeOfDay(window)) }
        switch parts.count {
        case 0: return .always
        case 1: return parts[0]
        default: return .allOf(parts)
        }
    }

    /// The daily budget in seconds, or `nil` when the limit control is off.
    var dailyLimit: TimeInterval? {
        quotaEnabled ? TimeInterval(quotaMinutes * 60) : nil
    }
}

// MARK: - Weekday labels

extension Weekday {
    /// Single-letter label for the compact day toggles.
    var letter: String {
        switch self {
        case .sunday, .saturday: "S"
        case .monday: "M"
        case .tuesday, .thursday: "T"
        case .wednesday: "W"
        case .friday: "F"
        }
    }

    var shortLabel: String {
        switch self {
        case .sunday: "Sun"
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        }
    }
}
