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

    /// True while the given calendar has an event active right now (resolved by the app via
    /// `RuleContext.activeCalendarIDs`). E.g. a US-holidays calendar → true on holidays.
    case duringCalendarEvent(CalendarSource)
    /// True while the given Focus is active (resolved via `RuleContext.activeFocusIDs`).
    case duringFocus(FocusSource)
    /// True while the device is inside the given region (resolved via `RuleContext.insideRegionIDs`).
    case atLocation(GeoRegion)

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

    /// The external-signal sources anywhere in this condition tree, so the app knows what to resolve.
    public func collectSources() -> (calendars: [CalendarSource], focuses: [FocusSource], regions: [GeoRegion]) {
        switch self {
        case .duringCalendarEvent(let s): return ([s], [], [])
        case .duringFocus(let f): return ([], [f], [])
        case .atLocation(let r): return ([], [], [r])
        case .not(let inner): return inner.collectSources()
        case .allOf(let list), .anyOf(let list):
            var c: [CalendarSource] = [], f: [FocusSource] = [], r: [GeoRegion] = []
            for cond in list {
                let x = cond.collectSources(); c += x.calendars; f += x.focuses; r += x.regions
            }
            return (c, f, r)
        default:
            return ([], [], [])
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
        case .duringCalendarEvent(let source):
            return context.activeCalendarIDs.contains(source.id)
        case .duringFocus(let focus):
            return context.activeFocusIDs.contains(focus.id)
        case .atLocation(let region):
            return context.insideRegionIDs.contains(region.id)
        case .not(let inner):
            return !inner.evaluate(in: context)
        case .allOf(let conditions):
            return conditions.allSatisfy { $0.evaluate(in: context) }
        case .anyOf(let conditions):
            return conditions.contains { $0.evaluate(in: context) }
        }
    }
}
