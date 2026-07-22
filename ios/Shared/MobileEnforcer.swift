import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import RulesEngine

/// Shared enforcement used by both the app and the `DeviceActivityMonitor` extension.
///
/// Model (mirrors macOS): apps/sites are blocked by default and *allowed* only inside a rule's
/// day/time window. Each rule owns a named `ManagedSettingsStore` for its apps; the Safari content
/// blocker holds the union of currently-blocked domains. `reevaluate()` recomputes the whole state
/// from the shared rules + current clock — the app calls it on edits, the monitor calls it at
/// window boundaries and budget thresholds.
enum MobileEnforcer {
    static let appGroup = "group.com.pauljohnson.siteblocker"

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    // MARK: Shared rule storage (app writes, monitor reads)

    static func loadRules() -> [MobileRule] {
        guard let url = container?.appendingPathComponent("rules.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MobileRule].self, from: data)) ?? []
    }

    static func saveRules(_ rules: [MobileRule]) {
        guard let url = container?.appendingPathComponent("rules.json") else { return }
        if let data = try? JSONEncoder().encode(rules) { try? data.write(to: url) }
    }

    /// Manual override: block everything now, regardless of schedule (the app's Lock / "Start
    /// Blocking" intent). Persisted so the monitor honors it too.
    static var forceBlock: Bool {
        get { UserDefaults(suiteName: appGroup)?.bool(forKey: "forceBlock") ?? false }
        set { UserDefaults(suiteName: appGroup)?.set(newValue, forKey: "forceBlock") }
    }

    // MARK: Per-day app-budget exhaustion (set by the monitor's threshold callback)

    private static func budgetKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "budgetSpent-\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    static func markAppBudgetSpent(_ ruleID: UUID, at date: Date = .now) {
        let defaults = UserDefaults(suiteName: appGroup)
        var ids = Set(defaults?.stringArray(forKey: budgetKey(date)) ?? [])
        ids.insert(ruleID.uuidString)
        defaults?.set(Array(ids), forKey: budgetKey(date))
    }

    static func appBudgetSpent(at date: Date = .now) -> Set<UUID> {
        Set((UserDefaults(suiteName: appGroup)?.stringArray(forKey: budgetKey(date)) ?? [])
            .compactMap(UUID.init))
    }

    // MARK: Evaluation

    /// Whether a rule's allow window is open now (enabled, allowed weekday, inside the time window).
    static func inAllowWindow(_ rule: MobileRule, at date: Date = .now) -> Bool {
        guard rule.isEnabled else { return false }
        let calendar = Calendar.current
        if rule.days != Set(Weekday.allCases),
           let weekday = Weekday(rawValue: calendar.component(.weekday, from: date)),
           !rule.days.contains(weekday) {
            return false
        }
        if let window = rule.window, !window.contains(date, calendar: calendar) { return false }
        return true
    }

    /// Recompute and apply the whole enforcement state from the shared rules + clock.
    static func reevaluate(at date: Date = .now) {
        let rules = loadRules()
        let override = forceBlock
        let budgetSpent = appBudgetSpent(at: date)

        for rule in rules {
            // Apps are allowed only in-window, not overridden, and not over their app budget today.
            let appsAllowed = !override && inAllowWindow(rule, at: date) && !budgetSpent.contains(rule.id)
            appsAllowed ? clearApps(rule.id) : blockApps(rule)
        }

        // Sites: blocked when not in the allow window (the app budget applies to apps only, since
        // Screen Time can't measure content-blocker viewing time) or under the manual override.
        let blockedDomains = rules
            .filter { $0.isEnabled && (override || !inAllowWindow($0, at: date)) }
            .flatMap(\.siteDomains)
        SiteRuleset.rebuild(blocking: Array(Set(blockedDomains)))
    }

    // MARK: Per-rule shields

    private static func store(_ ruleID: UUID) -> ManagedSettingsStore {
        ManagedSettingsStore(named: .init(ruleID.uuidString))
    }

    private static func blockApps(_ rule: MobileRule) {
        let s = store(rule.id)
        let apps = rule.selection.applicationTokens
        let cats = rule.selection.categoryTokens
        s.shield.applications = apps.isEmpty ? nil : apps
        s.shield.applicationCategories = cats.isEmpty ? nil : .specific(cats)
    }

    private static func clearApps(_ ruleID: UUID) { store(ruleID).clearAllSettings() }

    // MARK: Scheduling (app side)

    /// (Re)register a daily `DeviceActivitySchedule` per enabled rule — the interval is its allow
    /// window (whole day if none). Rules with an app budget also get a usage-threshold event, so the
    /// monitor re-blocks the apps once the budget is spent. Day-of-week gating happens in the
    /// monitor via `inAllowWindow`.
    static func refreshSchedules(_ rules: [MobileRule]) {
        let center = DeviceActivityCenter()
        center.stopMonitoring()
        for rule in rules where rule.isEnabled {
            let start = rule.window.map { DateComponents(hour: $0.startMinutes / 60, minute: $0.startMinutes % 60) }
                ?? DateComponents(hour: 0, minute: 0)
            let end = rule.window.map { DateComponents(hour: $0.endMinutes / 60, minute: $0.endMinutes % 60) }
                ?? DateComponents(hour: 23, minute: 59)
            let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true)

            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            if let limit = rule.dailyLimitMinutes {
                let apps = rule.selection.applicationTokens
                let cats = rule.selection.categoryTokens
                if !apps.isEmpty || !cats.isEmpty {
                    events[.init("budget")] = DeviceActivityEvent(
                        applications: apps, categories: cats,
                        threshold: DateComponents(minute: limit))
                }
            }
            try? center.startMonitoring(DeviceActivityName(rule.id.uuidString),
                                        during: schedule, events: events)
        }
    }
}
