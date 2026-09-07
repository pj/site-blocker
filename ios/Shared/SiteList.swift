import Foundation
import RulesEngine

/// New model (experimental, iOS-only): a **site list** is a named set of domains plus an ordered
/// list of **rules**. Each rule is an Allow or Deny that applies on a schedule (weekdays + optional
/// time-of-day) with an optional daily time limit. The list also has a **default** used when no rule
/// is active right now.
///
/// Resolution is *first active rule wins*: walk the rules top-to-bottom; the first enabled rule whose
/// schedule matches the current moment decides the list's fate (Deny → blocked; Allow → allowed,
/// subject to its limit + the global unlock). If none match, fall back to the list default.
///
/// This replaces the old one-schedule-per-list `MobileRule`; see `SiteList.migrating(from:)` for the
/// conversion of saved data.

enum RuleAction: String, Codable, Sendable, CaseIterable {
    case allow
    case deny
}

struct ListRule: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var isEnabled = true
    var action: RuleAction = .deny
    /// Weekdays the rule applies. Empty = never; all seven = every day.
    var days: Set<Weekday> = Set(Weekday.allCases)
    /// When on, the rule only applies inside `window` on those days.
    var timeEnabled = false
    var window = TimeWindow(startHour: 9, endHour: 17)
    /// Optional daily budget (minutes) for an Allow rule — allowed until the shared pool is spent,
    /// and (like today) gated behind the manual unlock. Ignored for Deny rules.
    var dailyLimitMinutes: Int?

    /// Whether the rule's schedule matches `now` (days + optional time-of-day). Ignores action/limit.
    func scheduleActive(now: Date, calendar: Calendar) -> Bool {
        let raw = calendar.component(.weekday, from: now)
        guard let day = Weekday(rawValue: raw), days.contains(day) else { return false }
        return timeEnabled ? window.contains(now, calendar: calendar) : true
    }
}

struct SiteList: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var isEnabled = true
    var domains: [String] = []
    /// The fate of the sites when no rule is active. `false` = blocked (the safe default for a
    /// blocker); `true` = allowed.
    var defaultAllowed = false
    var rules: [ListRule] = []

    enum Decision: Equatable { case allowed, blocked }

    /// Resolve the current decision for this list. `unlocked` + `usedToday` gate limited Allow rules
    /// exactly as the single global unlock + shared daily budget do today.
    func decision(now: Date, calendar: Calendar, unlocked: Bool, usedToday: TimeInterval) -> Decision {
        guard isEnabled else { return .allowed }   // a disabled list governs nothing
        for rule in rules where rule.isEnabled {
            guard rule.scheduleActive(now: now, calendar: calendar) else { continue }
            switch rule.action {
            case .deny:
                return .blocked
            case .allow:
                guard let limit = rule.dailyLimitMinutes else { return .allowed }
                return (unlocked && usedToday < TimeInterval(limit * 60)) ? .allowed : .blocked
            }
        }
        return defaultAllowed ? .allowed : .blocked
    }

    /// A limited Allow rule that is the active decision right now but is being held closed only by the
    /// lock (its schedule matches and budget remains) — i.e. unlocking would open this list.
    func isUnlockableNow(now: Date, calendar: Calendar, usedToday: TimeInterval) -> Bool {
        decision(now: now, calendar: calendar, unlocked: false, usedToday: usedToday) == .blocked
            && decision(now: now, calendar: calendar, unlocked: true, usedToday: usedToday) == .allowed
    }
}

extension SiteList {
    /// Convert a legacy one-schedule `MobileRule` into a list with a single Allow rule (its old
    /// schedule + limit) and a Blocked default — preserving the old behavior.
    init(migrating rule: MobileRule) {
        self.init()
        id = rule.id
        name = rule.name
        isEnabled = rule.isEnabled
        domains = rule.siteDomains
        defaultAllowed = false
        var r = ListRule()
        r.action = .allow
        r.days = rule.days
        r.timeEnabled = rule.timeEnabled
        r.window = rule.window
        r.dailyLimitMinutes = rule.dailyLimitMinutes
        rules = [r]
    }
}

// MARK: - Evaluation over all lists

enum Blocking {
    /// The domains blocked right now across every list.
    static func blockedDomains(_ lists: [SiteList], now: Date, calendar: Calendar,
                               unlocked: Bool, usedToday: TimeInterval) -> [String] {
        var blocked = Set<String>()
        for list in lists where list.decision(now: now, calendar: calendar,
                                               unlocked: unlocked, usedToday: usedToday) == .blocked {
            blocked.formUnion(list.domains.map { HostPattern($0).domain })
        }
        return Array(blocked)
    }

    /// Whether unlocking would open at least one list (a limited Allow rule is active with budget).
    static func canUnlock(_ lists: [SiteList], now: Date, calendar: Calendar,
                          usedToday: TimeInterval) -> Bool {
        lists.contains { $0.isUnlockableNow(now: now, calendar: calendar, usedToday: usedToday) }
    }

    /// Whether any list is currently open via a no-limit Allow rule (auto-open, no unlock needed) —
    /// the "open access" state the Control Center toggle reflects.
    static func openAccessActive(_ lists: [SiteList], now: Date, calendar: Calendar) -> Bool {
        // Locked and un-budgeted: anything allowed now is allowed without an unlock.
        lists.contains { $0.decision(now: now, calendar: calendar, unlocked: false, usedToday: 0) == .allowed
                         && !$0.domains.isEmpty }
    }

    /// The largest daily limit (minutes) among enabled limited Allow rules, for the budget readout.
    static func budgetLimitMinutes(_ lists: [SiteList]) -> Int? {
        lists.filter(\.isEnabled)
            .flatMap { $0.rules }
            .filter { $0.isEnabled && $0.action == .allow }
            .compactMap(\.dailyLimitMinutes)
            .max()
    }
}
