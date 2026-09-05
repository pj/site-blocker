import Foundation
import BackgroundTasks
import UserNotifications
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
            reevaluate()            // persists + rebuilds the Safari ruleset for the current moment
            scheduleNotifications() // the schedule changed, so the allowance alerts may have too
        }
    }
    /// When true, nothing is blocked (a temporary break). Inverse of "blocking on".
    @Published private(set) var isPaused: Bool = MobileEnforcer.isPaused
    /// Whether Face-ID-gated rules are currently unlocked.
    @Published private(set) var isUnlocked: Bool = MobileEnforcer.isUnlocked
    /// Whether some gated rule's window is open, so unlocking would reveal something.
    @Published private(set) var canUnlock: Bool = MobileEnforcer.canUnlockNow()
    /// Whether a break is allowed right now (some list's allow-window is open). Gates "Blocking off".
    @Published private(set) var canPause = false
    /// Current allow state + the next boundary, for the "time left" readout.
    @Published private(set) var allowance = MobileEnforcer.AllowanceStatus(openNow: false, boundary: nil)

    /// Fires while the app is foregrounded so a window boundary crossed with the app open takes
    /// effect promptly (rather than only on the next foreground).
    private var tick: Timer?

    init() {
        rules = MobileEnforcer.loadRules()
        Notifier.requestAuthorization()   // for allowance wind-down / availability alerts
        reevaluate()
        scheduleNotifications()
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

    /// Take a break (turn blocking off). Only permitted while a window is open — returns whether it
    /// applied, so callers (UI / App Intents) can tell the user when it's not an option right now.
    @discardableResult
    func pause() -> Bool {
        guard MobileEnforcer.allowanceStatus().openNow else { return false }
        MobileEnforcer.isPaused = true
        reevaluate()
        return true
    }

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
        let status = MobileEnforcer.allowanceStatus()
        // A break is only valid while a window is open; when it closes, re-block automatically so a
        // pause can't outlast the allowance that justified it.
        if MobileEnforcer.isPaused && !status.openNow {
            MobileEnforcer.isPaused = false
        }
        MobileEnforcer.reevaluate()
        isPaused = MobileEnforcer.isPaused
        isUnlocked = MobileEnforcer.isUnlocked
        canUnlock = MobileEnforcer.canUnlockNow()
        allowance = status
        canPause = status.openNow
    }

    /// The app came to the foreground: rebuild now, re-arm the alerts, and start the while-open timer.
    func onForeground() {
        reevaluate()
        scheduleNotifications()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        }
    }

    /// The app went to the background: stop the timer, re-arm the alerts for the closed period, and
    /// queue a best-effort background rebuild.
    func onBackground() {
        tick?.invalidate()
        tick = nil
        scheduleNotifications()
        Self.scheduleBackgroundRefresh()
    }

    // MARK: Notifications

    /// (Re)schedule the allowance notifications from the current schedule. Mirrors the desktop's
    /// wind-down warnings — a 5-minute and a final 1-minute (with sound) alert before the current
    /// allowance closes — plus a heads-up when the next allowance opens. Scheduled ahead with time
    /// triggers, so they fire even while the app is closed. Wording stays about the *schedule* (not
    /// "blocked now"), since enforcement only catches up the next time the app wakes.
    private func scheduleNotifications() {
        var requests: [UNNotificationRequest] = []
        let status = MobileEnforcer.allowanceStatus()
        if status.openNow, let close = status.boundary {
            if let r = Notifier.request(id: "allowance-warn-5",
                                        body: "5 minutes of allowed time left.",
                                        at: close.addingTimeInterval(-5 * 60)) { requests.append(r) }
            if let r = Notifier.request(id: "allowance-warn-1",
                                        body: "About 1 minute of allowed time left.",
                                        at: close.addingTimeInterval(-60), sound: true) { requests.append(r) }
            // The window that follows, so there's a heads-up when access returns.
            if let nextOpen = MobileEnforcer.allowanceStatus(now: close.addingTimeInterval(1)).boundary,
               let r = Notifier.request(id: "allowance-open",
                                        body: "Your allowed time is available again.",
                                        at: nextOpen) { requests.append(r) }
        } else if let open = status.boundary {
            if let r = Notifier.request(id: "allowance-open",
                                        body: "Your allowed time is now available.",
                                        at: open) { requests.append(r) }
        }
        Notifier.reschedule(requests)
    }

    // MARK: Background App Refresh (best effort)

    /// Register the background-refresh handler. Call once, before the app finishes launching.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            Task { @MainActor in
                shared.reevaluate()
                shared.scheduleNotifications()   // keep the allowance alerts fresh
                scheduleBackgroundRefresh()      // chain the next one
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
