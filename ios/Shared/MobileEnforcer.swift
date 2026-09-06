import Foundation
import RulesEngine

/// Site-blocking enforcement for the app. Owns the shared rule storage, the paused flag, and the
/// Face-ID unlock state, and rebuilds the Safari content-blocker ruleset from whatever is blocked
/// *right now*.
///
/// A Safari content blocker is a static ruleset with no per-request time logic, so the app evaluates
/// the allow schedule against the current moment (via the shared `BlockEngine`) and rewrites the
/// ruleset. `reevaluate()` runs on edits, on pause/resume, on lock/unlock, on foreground, on a timer
/// while the app is open, and on background refresh — so a window boundary takes effect the next
/// time the app wakes, not to the minute in the background.
enum MobileEnforcer {
    static let appGroup = "group.com.pauljohnson.siteblocker"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
    private static var calendar: Calendar { .current }

    // MARK: Shared rule storage

    static func loadRules() -> [MobileRule] {
        guard let url = container?.appendingPathComponent("rules.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MobileRule].self, from: data)) ?? []
    }

    static func saveRules(_ rules: [MobileRule]) {
        guard let url = container?.appendingPathComponent("rules.json") else { return }
        if let data = try? JSONEncoder().encode(rules) { try? data.write(to: url) }
    }

    // MARK: Face-ID unlock state + daily usage budget

    /// When the gated lists are currently unlocked, the instant the current unlocked stretch began;
    /// `nil` when locked. Wall-clock time since then is charged to today's usage budget.
    private static var unlockedSince: Date? {
        get { defaults?.object(forKey: "unlockedSince") as? Date }
        set {
            if let newValue { defaults?.set(newValue, forKey: "unlockedSince") }
            else { defaults?.removeObject(forKey: "unlockedSince") }
        }
    }

    /// The shared pool of unlocked time spent per day (mirrors the macOS budget). Persisted in the
    /// App Group so it survives app restarts and the content-blocker extension can't reset it.
    private static var usage: DailyUsage {
        get {
            guard let data = defaults?.data(forKey: "usage"),
                  let value = try? JSONDecoder().decode(DailyUsage.self, from: data) else {
                return DailyUsage(calendar: calendar)
            }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults?.set(data, forKey: "usage") }
        }
    }

    static var isUnlocked: Bool { unlockedSince != nil }

    static func setUnlocked(_ on: Bool) {
        chargeUsage()                       // flush any time from the stretch ending now
        unlockedSince = on ? Date() : nil
    }

    /// Charge wall-clock time elapsed since the unlocked stretch began into today's budget, and
    /// advance the marker. Called on every re-evaluation so the budget stays current (and persists
    /// even if the app is killed mid-stretch). No-op while locked.
    static func chargeUsage(now: Date = Date()) {
        guard let since = unlockedSince else { return }
        var store = usage
        store.record(max(0, now.timeIntervalSince(since)), at: now)
        store.pruneDays(before: now)
        usage = store
        unlockedSince = now
    }

    /// Total unlocked time spent today, including the in-progress stretch.
    private static func unblockedTimeToday(now: Date = Date()) -> TimeInterval {
        var total = usage.total(on: now)
        if let since = unlockedSince { total += max(0, now.timeIntervalSince(since)) }
        return total
    }

    private static func context(now: Date = Date()) -> RuleContext {
        RuleContext(now: now, calendar: calendar, unblockedTimeToday: unblockedTimeToday(now: now))
    }

    // MARK: Evaluation

    private static func engine() -> BlockEngine {
        BlockEngine(rules: loadRules().map(\.asRule))
    }

    /// The domains blocked at this instant: the engine's blocked set for the current time, unlock
    /// state, and budget (no-limit lists open in their windows; limited lists open only while
    /// unlocked and until their budget is spent).
    static func blockedDomainsNow() -> [String] {
        engine().blockedPatterns(unlocked: isUnlocked, in: context()).map(\.domain)
    }

    /// True when some limited list's window is open and its budget isn't yet spent — i.e. unlocking
    /// would reveal something. Drives whether the Unlock control is offered.
    static func canUnlockNow() -> Bool {
        !engine().unlockableRules(in: context()).isEmpty
    }

    /// Today's shared daily-limit budget across the enabled time-limited lists, for the on-screen
    /// readout. `limit` is the overall cap (the largest per-list limit, since they share one pool);
    /// `remaining` is what's left of it. `nil` when no enabled list has a daily limit.
    struct BudgetStatus: Equatable, Sendable {
        var used: TimeInterval
        var limit: TimeInterval
        var remaining: TimeInterval { max(0, limit - used) }
    }

    static func budgetStatus(now: Date = Date()) -> BudgetStatus? {
        let limits = loadRules().filter(\.isEnabled).compactMap(\.dailyLimitMinutes)
        guard let maxMinutes = limits.max() else { return nil }
        return BudgetStatus(used: unblockedTimeToday(now: now),
                            limit: TimeInterval(maxMinutes * 60))
    }

    /// The current allow state and the next moment it flips — drives the "time left" readout.
    /// `openNow` is whether any enabled list's window is open right now; `boundary` is when the
    /// current window next closes (if open now) or when the next window opens (if closed now); `nil`
    /// when it won't change within the search horizon — an always-open list, or nothing scheduled.
    struct AllowanceStatus: Equatable, Sendable {
        var openNow: Bool
        var boundary: Date?
    }

    static func allowanceStatus(now: Date = Date()) -> AllowanceStatus {
        let rules = loadRules().map(\.asRule)
        func openAt(_ instant: Date) -> Bool {
            // Window-based (ignores the budget) so the readout tracks the schedule, not time spent.
            let context = RuleContext(now: instant, calendar: calendar)
            return rules.contains { $0.windowOpen(in: context) }
        }
        let openNow = openAt(now)
        // Windows repeat weekly, so any flip happens within a week; scan 8 days at one-minute steps.
        for minute in 1...(8 * 24 * 60) {
            let instant = now.addingTimeInterval(TimeInterval(minute * 60))
            if openAt(instant) != openNow {
                return AllowanceStatus(openNow: openNow, boundary: instant)
            }
        }
        return AllowanceStatus(openNow: openNow, boundary: nil)
    }

    /// Recompute the blocked domain set and rewrite the Safari ruleset.
    static func reevaluate() {
        SiteRuleset.rebuild(blocking: blockedDomainsNow())
    }
}
