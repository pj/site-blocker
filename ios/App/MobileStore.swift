import Foundation
import BackgroundTasks
import RulesEngine

/// iOS coordinator. Owns the block rules (named domain lists with an allow schedule), the global
/// pause switch, and the Face-ID unlock state, and delegates ruleset rebuilding to `MobileEnforcer`.
///
/// Because a Safari content blocker is static, the *app* decides what's blocked right now. This
/// object re-evaluates the schedule and rewrites the ruleset whenever anything changes and on every
/// wake signal — launch, foreground, a timer while open, and background refresh — so a schedule
/// boundary takes effect the next time the app runs.
@MainActor
final class MobileStore: ObservableObject {
    /// Shared instance so App Intents (Shortcuts/Siri) control the same state as the UI.
    static let shared = MobileStore()

    /// Background App Refresh task id — opportunistic, best-effort rebuilds while the app is closed.
    static let refreshTaskID = "com.pauljohnson.siteblocker.ios.refresh"

    @Published var rules: [MobileRule] {
        didSet {
            MobileEnforcer.saveRules(rules)
            reevaluate()   // persists + rebuilds the Safari ruleset for the current moment
        }
    }
    /// When true, nothing is blocked (a temporary break). Inverse of "blocking on".
    @Published private(set) var isPaused: Bool = MobileEnforcer.isPaused
    /// Whether Face-ID-gated rules are currently unlocked.
    @Published private(set) var isUnlocked: Bool = MobileEnforcer.isUnlocked
    /// Whether some gated rule's window is open, so unlocking would reveal something.
    @Published private(set) var canUnlock: Bool = MobileEnforcer.canUnlockNow()

    /// Fires while the app is foregrounded so a window boundary crossed with the app open takes
    /// effect promptly (rather than only on the next foreground).
    private var tick: Timer?

    init() {
        rules = MobileEnforcer.loadRules()
        reevaluate()
    }

    // MARK: Rules

    func add() { rules.append(MobileRule(name: "New List")) }
    func delete(_ rule: MobileRule) { rules.removeAll { $0.id == rule.id } }
    func update(_ rule: MobileRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule   // didSet persists + re-evaluates
    }

    /// Replace the rules with a shared config fetched from `url` (Settings → Import). Each config
    /// entry becomes a local rule: inline domains plus any `blocklistUrl` fetched and merged, and the
    /// day/time window and unlock gating mapped across. The Mac is the source of truth.
    func importConfig(from url: URL) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData   // the gist raw URL is CDN-cached
        let (data, _) = try await URLSession.shared.data(for: request)
        let config = try JSONDecoder().decode(SyncedConfig.self, from: data)

        var mirrored: [MobileRule] = []
        for rule in config.rules {
            var domains = rule.domains
            if let string = rule.blocklistUrl, let listURL = URL(string: string),
               let (listData, _) = try? await URLSession.shared.data(from: listURL) {
                domains += SiteRuleset.parse(String(decoding: listData, as: UTF8.self))
            }
            mirrored.append(makeRule(from: rule,
                                     domains: SiteRuleset.parse(domains.joined(separator: "\n"))))
        }
        rules = mirrored   // didSet persists + rebuilds the Safari content blocker
    }

    /// Map a synced config entry's schedule onto a local rule. A missing day list means every day; a
    /// missing window means all day; a daily-limit entry becomes a Face-ID-gated rule (iOS has no
    /// time budget, so only the unlock gate carries over).
    private func makeRule(from synced: SyncedConfig.SyncedRule, domains: [String]) -> MobileRule {
        var rule = MobileRule(name: synced.name, isEnabled: synced.enabled, siteDomains: domains)
        if let days = synced.days {
            rule.days = Set(days.compactMap(Weekday.init(abbreviation:)))
        } else {
            rule.days = MobileRule.everyDay        // nil = every day
        }
        if let window = synced.window,
           let start = Self.minutes(window.start), let end = Self.minutes(window.end) {
            rule.timeEnabled = true
            rule.window = TimeWindow(startMinutes: start, endMinutes: end)
        }
        rule.requiresUnlock = synced.dailyLimitMinutes != nil
        return rule
    }

    private static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    // MARK: Pause / resume

    /// "Blocking on" in the UI == not paused.
    var isBlocking: Bool { !isPaused }

    func pause() { MobileEnforcer.isPaused = true; reevaluate() }
    func resume() { MobileEnforcer.isPaused = false; reevaluate() }

    // MARK: Face-ID lock / unlock

    /// Prompt for Face ID and, on success, reveal the gated rules' sites for the rest of the day.
    @discardableResult
    func unlock() async -> Bool {
        guard MobileEnforcer.canUnlockNow() else { return false }
        let ok = await Authentication.confirm(reason: "Unlock your restricted sites")
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

    /// Recompute the blocked set for *now*, rewrite the ruleset, and refresh the published state
    /// (an unlock may have lapsed at midnight; a window may have opened or closed).
    func reevaluate() {
        MobileEnforcer.reevaluate()
        isPaused = MobileEnforcer.isPaused
        isUnlocked = MobileEnforcer.isUnlocked
        canUnlock = MobileEnforcer.canUnlockNow()
    }

    /// The app came to the foreground: rebuild now and start the while-open timer.
    func onForeground() {
        reevaluate()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        }
    }

    /// The app went to the background: stop the timer and queue a best-effort background rebuild.
    func onBackground() {
        tick?.invalidate()
        tick = nil
        Self.scheduleBackgroundRefresh()
    }

    // MARK: Background App Refresh (best effort)

    /// Register the background-refresh handler. Call once, before the app finishes launching.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            Task { @MainActor in
                shared.reevaluate()
                scheduleBackgroundRefresh()   // chain the next one
                task.setTaskCompleted(success: true)
            }
        }
    }

    /// Ask iOS to wake us later to re-evaluate. iOS decides if/when — this only nudges the schedule
    /// forward while the app is closed; foreground is still the reliable path.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
