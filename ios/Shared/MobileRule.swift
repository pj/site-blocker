import Foundation
import FamilyControls
import RulesEngine

/// One iOS allow-rule: a Screen Time selection of apps/websites, plus the schedule during which
/// they may be used. Mirrors the Mac's allow model — the selection is blocked (shielded) by
/// default and permitted only inside the day/time window, up to an optional daily limit.
///
/// The *targets* differ from macOS (opaque Screen Time tokens via `FamilyActivitySelection`, not
/// hostnames), but the *schedule* reuses `RulesEngine` types so the model stays consistent.
struct MobileRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var isEnabled = true
    /// Apps / categories chosen with `FamilyActivityPicker` (opaque, privacy-safe) — blocked via
    /// Screen Time shields.
    var selection = FamilyActivitySelection()
    /// Websites, typed or pasted as a list — blocked via the Safari Content Blocker. Unlike the
    /// picker's opaque tokens, these are plain domains you can read, edit, and import.
    var siteDomains: [String] = []

    /// Days the allowance applies (all = every day).
    var days: Set<Weekday> = Set(Weekday.allCases)
    /// Optional time-of-day window the selection may be used.
    var window: TimeWindow?
    /// Optional daily usage budget, in minutes.
    var dailyLimitMinutes: Int?

    var summary: String {
        var parts: [String] = []
        let apps = selection.applicationTokens.count + selection.categoryTokens.count
        if apps > 0 { parts.append("\(apps) app(s)") }
        if !siteDomains.isEmpty { parts.append("\(siteDomains.count) site(s)") }
        if parts.isEmpty { parts.append("nothing selected") }
        if days != Set(Weekday.allCases) { parts.append(days.sorted().map(\.shortName).joined(separator: "")) }
        if let window { parts.append("\(window.startMinutes / 60):00–\(window.endMinutes / 60):00") }
        if let dailyLimitMinutes { parts.append("\(dailyLimitMinutes) min/day") }
        return parts.joined(separator: " · ")
    }
}

extension Weekday {
    var shortName: String {
        switch self {
        case .sunday: "Su"; case .monday: "M"; case .tuesday: "Tu"; case .wednesday: "W"
        case .thursday: "Th"; case .friday: "F"; case .saturday: "Sa"
        }
    }
}
