import Foundation

/// A predicate over the current moment and today's usage that decides whether blocking is
/// *in effect*. `evaluate` returns `true` when the condition says "block right now".
///
/// Conditions compose with `not` / `allOf` / `anyOf`, so a single rule can express things like
/// "block on weekday mornings, OR any time once I've burned my 30-minute daily allowance."
public indirect enum Condition: Codable, Hashable, Sendable {
    /// Unconditionally block (a plain always-on blocklist entry).
    case always
    /// Block while the current local time-of-day is inside the window.
    case duringTimeOfDay(TimeWindow)
    /// Block on any of these weekdays.
    case onDaysOfWeek(Set<Weekday>)
    /// Block while the current date is within the (inclusive) range.
    case duringDateRange(DateRange)
    /// Block once today's accumulated unblocked time reaches `limit` seconds.
    case afterUnblockedTime(_ limit: TimeInterval)

    case not(Condition)
    case allOf([Condition])
    case anyOf([Condition])

    /// Split a legacy condition into its day/time *window* and any daily budget that was encoded
    /// as an `afterUnblockedTime` atom. Used to migrate the old "block after N minutes" rules to
    /// the allow model, where the budget is a separate `Rule.dailyLimit`.
    public func splittingDailyLimit() -> (window: Condition, limit: TimeInterval?) {
        switch self {
        case .afterUnblockedTime(let limit):
            return (.always, limit)
        case .allOf(let list):
            var limit: TimeInterval?
            var rest: [Condition] = []
            for condition in list {
                if case .afterUnblockedTime(let l) = condition { limit = l } else { rest.append(condition) }
            }
            let window: Condition = rest.isEmpty ? .always : (rest.count == 1 ? rest[0] : .allOf(rest))
            return (window, limit)
        default:
            return (self, nil)
        }
    }

    public func evaluate(in context: RuleContext) -> Bool {
        switch self {
        case .always:
            return true
        case .duringTimeOfDay(let window):
            return window.contains(context.now, calendar: context.calendar)
        case .onDaysOfWeek(let days):
            let raw = context.calendar.component(.weekday, from: context.now)
            guard let day = Weekday(rawValue: raw) else { return false }
            return days.contains(day)
        case .duringDateRange(let range):
            return range.contains(context.now)
        case .afterUnblockedTime(let limit):
            return context.unblockedTimeToday >= limit
        case .not(let inner):
            return !inner.evaluate(in: context)
        case .allOf(let conditions):
            return conditions.allSatisfy { $0.evaluate(in: context) }
        case .anyOf(let conditions):
            return conditions.contains { $0.evaluate(in: context) }
        }
    }
}
