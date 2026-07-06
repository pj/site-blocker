import Foundation
import RulesEngine

/// The chip-based condition model behind the rules UI: a rule's condition is edited as OR-groups
/// of AND-chips (disjunctive normal form). Chips in a group AND together; groups OR together.
/// `[ChipGroup]` ↔ `Condition` conversion lives here.

/// One predicate chip.
enum ConditionAtom: Equatable {
    case days(Set<Weekday>)
    case time(TimeWindow)
    /// Daily allowance (seconds) of unblocked wall-clock time. The countdown runs while blocking
    /// is disabled; once spent, the rule's sites are blocked even with the master switch off.
    case quota(TimeInterval)

    var condition: Condition {
        switch self {
        case .days(let days): .onDaysOfWeek(days)
        case .time(let window): .duringTimeOfDay(window)
        case .quota(let limit): .afterUnblockedTime(limit)
        }
    }

    var kind: AtomKind {
        switch self {
        case .days: .days
        case .time: .time
        case .quota: .quota
        }
    }

    var label: String {
        switch self {
        case .days(let days):
            return Self.daysLabel(days)
        case .time(let window):
            return "\(Self.timeLabel(window.startMinutes))–\(Self.timeLabel(window.endMinutes))"
        case .quota(let limit):
            return "\(Int(limit / 60)) min/day"
        }
    }

    private static func daysLabel(_ days: Set<Weekday>) -> String {
        let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        let weekend: Set<Weekday> = [.saturday, .sunday]
        if days == Set(Weekday.allCases) { return "Every day" }
        if days == weekdays { return "Weekdays" }
        if days == weekend { return "Weekends" }
        if days.isEmpty { return "No days" }
        return days.sorted().map(\.shortLabel).joined(separator: ", ")
    }

    private static func timeLabel(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// The chip types a group can hold (one of each — a second time window in the same AND group could
/// never both be true, so duplicates are just confusing).
enum AtomKind: CaseIterable {
    case days, time, quota

    var addLabel: String {
        switch self {
        case .days: "Days"
        case .time: "Time"
        case .quota: "Usage"
        }
    }

    var defaultAtom: ConditionAtom {
        switch self {
        case .days: .days([.monday, .tuesday, .wednesday, .thursday, .friday])
        case .time: .time(TimeWindow(startHour: 9, endHour: 17))
        case .quota: .quota(30 * 60)
        }
    }
}

/// Identity is per editing session (not persisted), so chips keep selection while edited.
struct Chip: Identifiable, Equatable {
    let id = UUID()
    var atom: ConditionAtom
}

struct ChipGroup: Identifiable, Equatable {
    let id = UUID()
    var chips: [Chip]

    /// An empty group means "always".
    static func decompose(_ condition: Condition) -> [ChipGroup] {
        let groupConditions: [Condition]
        if case .anyOf(let list) = condition {
            groupConditions = list
        } else {
            groupConditions = [condition]
        }
        return groupConditions.map { ChipGroup(chips: atoms(from: $0).map { Chip(atom: $0) }) }
    }

    /// Best-effort flattening. `not` / date ranges have no chip UI and are dropped on the next
    /// edit of that rule; nothing in the app currently creates them.
    private static func atoms(from condition: Condition) -> [ConditionAtom] {
        switch condition {
        case .always: return []
        case .onDaysOfWeek(let days): return [.days(days)]
        case .duringTimeOfDay(let window): return [.time(window)]
        case .afterUnblockedTime(let limit): return [.quota(limit)]
        case .allOf(let list), .anyOf(let list): return list.flatMap { atoms(from: $0) }
        case .not, .duringDateRange: return []
        }
    }

    static func compose(_ groups: [ChipGroup]) -> Condition {
        let groupConditions = groups.map { group -> Condition in
            let atoms = group.chips.map(\.atom.condition)
            switch atoms.count {
            case 0: return .always
            case 1: return atoms[0]
            default: return .allOf(atoms)
            }
        }
        switch groupConditions.count {
        case 0: return .always
        case 1: return groupConditions[0]
        default: return .anyOf(groupConditions)
        }
    }
}

extension Condition {
    /// Whether a quota (`afterUnblockedTime`) atom appears anywhere in the tree.
    var containsQuota: Bool {
        switch self {
        case .afterUnblockedTime: true
        case .not(let inner): inner.containsQuota
        case .allOf(let list), .anyOf(let list): list.contains { $0.containsQuota }
        default: false
        }
    }

    /// A copy with quota atoms replaced by `.always`. Used while the master block is enabled: the
    /// daily allowance governs *unblocked* time, so with blocking on a quota rule blocks outright.
    var quotaSatisfied: Condition {
        switch self {
        case .afterUnblockedTime: .always
        case .not(let inner): .not(inner.quotaSatisfied)
        case .allOf(let list): .allOf(list.map(\.quotaSatisfied))
        case .anyOf(let list): .anyOf(list.map(\.quotaSatisfied))
        default: self
        }
    }
}

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
