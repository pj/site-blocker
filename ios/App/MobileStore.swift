import Foundation
import BackgroundTasks
import WidgetKit
import RulesEngine

/// iOS coordinator. Owns the site lists (each a set of domains + ordered Allow/Deny rules), the
/// unlock state, and the daily budget, and delegates ruleset rebuilding to `MobileEnforcer`.
///
/// Because a Safari content blocker is static, the *app* decides what's blocked right now. This
/// object re-evaluates and rewrites the ruleset whenever anything changes and on every wake signal —
/// launch, foreground, a timer while open, and background refresh.
@MainActor
final class MobileStore: ObservableObject {
    /// Shared instance so App Intents / the Control Center control reach the same state as the UI.
    static let shared = MobileStore()

    /// Background App Refresh task id. `nonisolated` so the background-queue handler can read it.
    nonisolated static let refreshTaskID = "com.pauljohnson.siteblocker.ios.refresh"

    @Published var lists: [SiteList] {
        didSet {
            MobileEnforcer.saveLists(lists)
            reevaluate()   // persists + rebuilds the Safari ruleset for the current moment
        }
    }
    /// Whether the limited lists are currently unlocked (budget draining).
    @Published private(set) var isUnlocked: Bool = MobileEnforcer.isUnlocked
    /// Whether unlocking would open something right now (enables the Unlock control).
    @Published private(set) var canUnlock: Bool = MobileEnforcer.canUnlockNow()
    /// Today's shared daily-limit budget, for the on-screen readout. `nil` when nothing is limited.
    @Published private(set) var budget: MobileEnforcer.BudgetStatus? = MobileEnforcer.budgetStatus()

    /// Fires while foregrounded so a schedule boundary crossed with the app open takes effect promptly.
    private var tick: Timer?

    init() {
        lists = MobileEnforcer.loadLists()
        reevaluate()
    }

    // MARK: List CRUD (the editor commits a whole list, including its ordered rules)

    func addList() { lists.append(SiteList(name: "New List")) }
    func delete(_ list: SiteList) { lists.removeAll { $0.id == list.id } }
    func update(_ list: SiteList) {
        guard let idx = lists.firstIndex(where: { $0.id == list.id }) else { return }
        lists[idx] = list   // didSet persists + re-evaluates
    }
    func moveLists(from offsets: IndexSet, to destination: Int) {
        lists.move(fromOffsets: offsets, toOffset: destination)
    }

    // MARK: Sync import

    /// Replace the lists with a shared config fetched from `url` (the Mac is the source of truth).
    /// Each config entry becomes a list of domains with a single Allow rule carrying its schedule +
    /// limit, and a Blocked default.
    func importConfig(from url: URL) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        let config = try JSONDecoder().decode(SyncedConfig.self, from: data)

        var mirrored: [SiteList] = []
        for rule in config.rules {
            var domains = rule.domains
            if let string = rule.blocklistUrl, let listURL = URL(string: string),
               let (listData, _) = try? await URLSession.shared.data(from: listURL) {
                domains += SiteRuleset.parse(String(decoding: listData, as: UTF8.self))
            }
            mirrored.append(makeList(from: rule,
                                     domains: SiteRuleset.parse(domains.joined(separator: "\n"))))
        }
        lists = mirrored
    }

    private func makeList(from synced: SyncedConfig.SyncedRule, domains: [String]) -> SiteList {
        var list = SiteList(name: synced.name)
        list.isEnabled = synced.enabled
        list.domains = domains
        list.defaultAllowed = false
        var r = ListRule()
        r.action = .allow
        r.days = synced.days.map { Set($0.compactMap(Weekday.init(abbreviation:))) } ?? Set(Weekday.allCases)
        if let window = synced.window,
           let start = Self.minutes(window.start), let end = Self.minutes(window.end) {
            r.timeEnabled = true
            r.window = TimeWindow(startMinutes: start, endMinutes: end)
        }
        r.dailyLimitMinutes = synced.dailyLimitMinutes
        list.rules = [r]
        return list
    }

    private static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    // MARK: Lock / unlock

    /// Prompt for Face ID and, on success, unlock the limited lists (budget starts draining).
    @discardableResult
    func unlock() async -> Bool {
        guard MobileEnforcer.canUnlockNow() else { return false }
        let ok = await Authentication.confirm(reason: "Unlock your limited sites")
        if ok {
            MobileEnforcer.setUnlocked(true)
            reevaluate()
        }
        return ok
    }

    /// Re-lock immediately (no authentication needed to make things stricter).
    func lock() {
        MobileEnforcer.setUnlocked(false)
        reevaluate()
    }

    // MARK: Wake signals

    func reevaluate() {
        MobileEnforcer.chargeUsage()   // charge elapsed unlocked time to today's budget
        // Auto-relock once nothing is left to unlock (budgets spent / windows closed).
        if MobileEnforcer.isUnlocked && !MobileEnforcer.canUnlockNow() {
            MobileEnforcer.setUnlocked(false)
        }
        MobileEnforcer.reevaluate()
        isUnlocked = MobileEnforcer.isUnlocked
        canUnlock = MobileEnforcer.canUnlockNow()
        budget = MobileEnforcer.budgetStatus()
        reloadControl()
    }

    /// Refresh the Control Center toggle so it reflects the current state.
    private func reloadControl() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: "com.pauljohnson.siteblocker.ios.LockControl")
        }
    }

    func onForeground() {
        reevaluate()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        }
    }

    func onBackground() {
        tick?.invalidate()
        tick = nil
        Self.scheduleBackgroundRefresh()
    }

    // MARK: Background App Refresh (best effort)

    /// Register the background-refresh handler. Call once, before the app finishes launching.
    /// `nonisolated` so the background-queue launch handler isn't main-actor-isolated (that would
    /// trap when iOS runs it off the main thread).
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            task.expirationHandler = { task.setTaskCompleted(success: false) }
            MobileEnforcer.reevaluate()
            scheduleBackgroundRefresh()
            task.setTaskCompleted(success: true)
        }
    }

    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
