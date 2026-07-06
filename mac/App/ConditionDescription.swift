import Foundation
import RulesEngine

/// Human-readable summaries of conditions for the UI. Kept in the app layer (not the engine) so
/// the engine stays free of presentation concerns.
extension Condition {
    var summary: String {
        switch self {
        case .always:
            return "always"
        case .duringTimeOfDay(let w):
            return "during \(Self.clock(w.startMinutes))–\(Self.clock(w.endMinutes))"
        case .onDaysOfWeek(let days):
            let names = days.sorted().map(\.shortName).joined(separator: ", ")
            return "on \(names)"
        case .duringDateRange(let r):
            let f = DateFormatter()
            f.dateStyle = .medium
            return "from \(f.string(from: r.start)) to \(f.string(from: r.end))"
        case .afterUnblockedTime(let seconds):
            return "after \(Int(seconds / 60)) min of use today"
        case .not(let inner):
            return "not (\(inner.summary))"
        case .allOf(let cs):
            return cs.map(\.summary).joined(separator: " AND ")
        case .anyOf(let cs):
            return cs.map(\.summary).joined(separator: " OR ")
        }
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

extension Weekday {
    var shortName: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }
}
