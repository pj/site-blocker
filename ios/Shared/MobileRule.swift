import Foundation
import RulesEngine

/// One iOS block rule: a named list of website domains plus an *allow schedule* — the weekdays and
/// optional time-of-day window during which those sites are allowed. Sites are blocked whenever the
/// window is closed (and, for Face-ID-gated rules, whenever they aren't unlocked). This mirrors the
/// macOS allow model so a synced config means the same thing on both platforms.
///
/// Because a Safari Content Blocker is a *static* ruleset (no per-request time logic), the app
/// re-evaluates the schedule and rewrites the ruleset whenever it runs — on launch, on foreground,
/// on a timer while open, and on background refresh (see `MobileEnforcer`). A window therefore takes
/// effect the next time the app wakes, not to the minute in the background.
///
/// Semantics (matching macOS):
///  - **No days selected** → the window never opens → the sites are a *permanent block*.
///  - **All seven days** → every day (no weekday constraint).
///  - **`requiresUnlock == false`** → the sites open automatically whenever the window is open.
///  - **`requiresUnlock == true`** → they stay blocked during the window until you unlock with Face
///    ID (a friction tier; there is no time budget on iOS — Safari browsing isn't observable).
struct MobileRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var isEnabled = true
    /// Websites, typed or pasted as a list — plain domains you can read, edit, and import.
    var siteDomains: [String] = []

    /// Weekdays the sites are allowed. All seven = every day; empty = never (a permanent block).
    /// Legacy rules (saved before scheduling existed) decode to empty, preserving their old meaning
    /// of "block these sites always."
    var days: Set<Weekday> = []
    /// When on, the sites are only allowed during `window` on the selected days (blocked otherwise).
    var timeEnabled = false
    var window = TimeWindow(startHour: 9, endHour: 17)
    /// When on, the sites stay blocked during their window until you unlock with Face ID.
    var requiresUnlock = false

    static let everyDay = Set(Weekday.allCases)

    // MARK: Engine mapping

    /// The day/time allow window as an engine `Condition` (matching macOS `RuleSchedule.condition`).
    /// No days pins an empty weekday set (never matches → permanent block); all days drops the
    /// weekday constraint.
    var condition: Condition {
        var parts: [Condition] = []
        if days.isEmpty {
            parts.append(.onDaysOfWeek([]))          // never opens → permanent block
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

    /// Map to the shared `BlockEngine`'s `Rule`. A Face-ID-gated rule carries a sentinel `dailyLimit`
    /// so the engine treats it as unlock-gated; iOS passes `unblockedTimeToday: 0`, so the budget
    /// never exhausts — the only gate is whether the user has unlocked.
    var asRule: Rule {
        Rule(name: name,
             isEnabled: isEnabled,
             targets: siteDomains.map { HostPattern($0) },
             condition: condition,
             dailyLimit: requiresUnlock ? Self.unlockGateSentinel : nil)
    }

    /// A budget large enough never to be reached (iOS has no viewing-time measurement), so a gated
    /// rule's only effective gate is the unlock state.
    static let unlockGateSentinel: TimeInterval = 1_000_000_000

    // MARK: Summaries (for the list)

    var siteCountSummary: String {
        guard !siteDomains.isEmpty else { return "no sites" }
        return "\(siteDomains.count) site\(siteDomains.count == 1 ? "" : "s")"
    }

    /// A plain-English line describing when the sites are allowed vs blocked.
    var scheduleSummary: String {
        if days.isEmpty { return "Always blocked" }
        var text = "Allowed \(daysPhrase)"
        if timeEnabled { text += " · \(Self.clock(window.startMinutes))–\(Self.clock(window.endMinutes))" }
        if requiresUnlock { text += " · Face ID" }
        return text
    }

    private var daysPhrase: String {
        if days == Self.everyDay { return "every day" }
        return Weekday.allCases.filter(days.contains).map(\.shortLabel).joined(separator: ", ")
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

// MARK: - Weekday labels (iOS copy; the macOS app has its own in ConditionSchedule.swift)

extension Weekday {
    /// Single-letter label for the compact day toggles.
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
}
