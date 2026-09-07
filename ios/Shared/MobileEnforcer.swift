import Foundation
import RulesEngine

/// Site-blocking enforcement for the app. Owns the shared list storage, the unlock state + daily
/// usage budget, and rebuilds the Safari content-blocker ruleset from whatever is blocked *right
/// now* — resolving each `SiteList`'s ordered rules against the current moment (see `Blocking`).
///
/// A Safari content blocker is static, so `reevaluate()` recomputes the blocked set and rewrites the
/// ruleset on every wake (launch, foreground, a timer while open, background refresh) — a schedule
/// boundary takes effect the next time the app runs, not to the minute in the background.
enum MobileEnforcer {
    static let appGroup = "group.com.pauljohnson.siteblocker"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
    private static var calendar: Calendar { .current }

    // MARK: List storage (lists.json; migrates the legacy [MobileRule] rules.json once)

    static func loadLists() -> [SiteList] {
        if let url = container?.appendingPathComponent("lists.json"),
           let data = try? Data(contentsOf: url),
           let lists = try? JSONDecoder().decode([SiteList].self, from: data) {
            return lists
        }
        if let url = container?.appendingPathComponent("rules.json"),
           let data = try? Data(contentsOf: url),
           let legacy = try? JSONDecoder().decode([MobileRule].self, from: data) {
            let migrated = legacy.map { SiteList(migrating: $0.asRule) }
            saveLists(migrated)
            return migrated
        }
        return []
    }

    static func saveLists(_ lists: [SiteList]) {
        guard let url = container?.appendingPathComponent("lists.json") else { return }
        if let data = try? JSONEncoder().encode(lists) { try? data.write(to: url) }
    }

    // MARK: Unlock state + daily usage budget

    /// When unlocked, the instant the current unlocked stretch began; `nil` when locked. Wall-clock
    /// time since then is charged to today's usage budget.
    private static var unlockedSince: Date? {
        get { defaults?.object(forKey: "unlockedSince") as? Date }
        set {
            if let newValue { defaults?.set(newValue, forKey: "unlockedSince") }
            else { defaults?.removeObject(forKey: "unlockedSince") }
        }
    }

    /// The shared pool of unlocked time spent per day (mirrors the macOS budget). Persisted in the
    /// App Group so it survives app restarts.
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
    /// advance the marker. Called on every re-evaluation so the budget stays current. No-op locked.
    static func chargeUsage(now: Date = Date()) {
        guard let since = unlockedSince else { return }
        var store = usage
        store.record(max(0, now.timeIntervalSince(since)), at: now)
        store.pruneDays(before: now)
        usage = store
        unlockedSince = now
    }

    /// Total unlocked time spent today, including the in-progress stretch.
    static func unblockedTimeToday(now: Date = Date()) -> TimeInterval {
        var total = usage.total(on: now)
        if let since = unlockedSince { total += max(0, now.timeIntervalSince(since)) }
        return total
    }

    // MARK: Evaluation (via the shared ListEngine)

    private static func context(now: Date = Date()) -> RuleContext {
        RuleContext(now: now, calendar: calendar, unblockedTimeToday: unblockedTimeToday(now: now))
    }

    static func blockedDomainsNow(now: Date = Date()) -> [String] {
        ListEngine(lists: loadLists())
            .blockedPatterns(unlocked: isUnlocked, in: context(now: now)).map(\.domain)
    }

    /// The ids of the lists that are blocked right now (drives the live status in the UI).
    static func blockedListIDs(now: Date = Date()) -> Set<UUID> {
        let ctx = context(now: now)
        let engine = ListEngine()
        return Set(loadLists()
            .filter { engine.decision(for: $0, unlocked: isUnlocked, in: ctx) == .blocked }
            .map(\.id))
    }

    /// The rule currently deciding `list` (the first with an active condition), for the "active now"
    /// marker. Evaluated against the shared clock/usage, matching what enforcement uses.
    static func activeRuleID(for list: SiteList, now: Date = Date()) -> UUID? {
        ListEngine().activeRule(for: list, in: context(now: now))?.id
    }

    /// True when unlocking would open at least one list (a limited Allow rule is active with budget).
    static func canUnlockNow(now: Date = Date()) -> Bool {
        ListEngine(lists: loadLists()).canUnlock(in: context(now: now))
    }

    /// True when some list is open via a no-limit Allow rule (auto-open, no unlock needed).
    static func openAccessActive(now: Date = Date()) -> Bool {
        ListEngine(lists: loadLists()).openAccessActive(in: context(now: now))
    }

    /// Whether anything is currently open — manually unlocked, or an auto-open Allow rule is active.
    /// Drives the Control Center toggle's on-state.
    static func accessOpenNow(now: Date = Date()) -> Bool {
        isUnlocked || openAccessActive(now: now)
    }

    /// Today's shared daily-limit budget across the enabled limited Allow rules, for the readout.
    struct BudgetStatus: Equatable, Sendable {
        var used: TimeInterval
        var limit: TimeInterval
        var remaining: TimeInterval { max(0, limit - used) }
    }

    static func budgetStatus(now: Date = Date()) -> BudgetStatus? {
        let limit = loadLists().filter(\.isEnabled).flatMap(\.rules)
            .filter { $0.action == .allow }
            .compactMap(\.dailyLimit).max()
        guard let limit else { return nil }
        return BudgetStatus(used: unblockedTimeToday(now: now), limit: limit)
    }

    /// Recompute the blocked domain set and rewrite the Safari ruleset.
    static func reevaluate() {
        SiteRuleset.rebuild(blocking: blockedDomainsNow())
    }
}
