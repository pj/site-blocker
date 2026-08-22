import Foundation
import AppKit
import OSLog
import RulesEngine

/// Unified-log logger; view with `just logs` (stream) or
/// `/usr/bin/log show --last 1h --predicate 'subsystem == "com.pauljohnson.siteblocker"'`.
let sourceLog = Logger(subsystem: "com.pauljohnson.siteblocker", category: "sources")

/// The app-side coordinator for the allow model. Sites named by rules are blocked by default; the
/// user *unlocks* (Touch ID) to view them, but only while some rule's day/time window is open and
/// its daily budget isn't spent. While unlocked, each allowed rule's budget drains in wall-clock;
/// when it runs out (or its window closes) that rule's sites re-block. Pure evaluation lives in
/// `BlockEngine`; this type is the wiring (clock, timer, persistence, enforcement hand-off).
@MainActor
final class RuleStore: ObservableObject {
    @Published var rules: [Rule] {
        didSet { persistence.save(rules: rules, usage: usage); refresh() }
    }

    /// Host patterns actively blocked *right now*. Drives the status view.
    @Published private(set) var blockedNow: Set<HostPattern> = []

    /// Whether the sites are currently unlocked (viewable). Locked by default; **not** persisted, so
    /// every launch starts locked/blocked — the safe default.
    @Published private(set) var isUnlocked = false

    /// Whether at least one *budgeted* rule is eligible to unlock right now (window open + budget
    /// left). No-limit rules open automatically, so they don't count here. Drives the Unlock control.
    @Published private(set) var canUnlock = false

    /// Whether some no-limit rule's window is open right now, so its sites are available without any
    /// unlock. Lets the UI show an "open" state even while locked.
    @Published private(set) var openAccessActive = false

    /// Total unblocked time used today — the shared pool all rules draw down. For the readouts.
    @Published private(set) var totalUsageToday: TimeInterval = 0

    private var usage: DailyUsage
    private let enforcer: Enforcer
    private let persistence: PersistenceController
    private var timer: Timer?
    private var hotKey: GlobalHotKey?

    /// Set while unlocked: the moment up to which viewing time has been charged to the allowed rules.
    private var unlockedSince: Date?

    /// When the Mac went to sleep while unlocked, so wake can tell a brief lid-close from a long one.
    private var sleepStart: Date?
    /// A wake within this window of sleeping resumes the session without re-auth; longer re-locks.
    private let sleepLockGrace: TimeInterval = 5 * 60

    /// The last blocked set handed to the enforcer/snapshot, so we skip rewriting the (potentially
    /// multi-megabyte) snapshot file when nothing changed between ticks.
    private var lastBlocked: Set<HostPattern>?

    /// Budget-countdown notification state for the unlock session: the last whole-minute value we
    /// posted a 5-minute update for, and whether the final 1-minute warning has fired.
    private var lastNotifiedTotalMinutes: Int?
    private var totalWarned = false

    /// Health of each rule's external target source, for the sites popover.
    struct SourceStatus: Equatable {
        var lastUpdated: Date?
        var error: String?
    }
    @Published private(set) var sourceStatus: [UUID: SourceStatus] = [:]

    private var fileModificationDates: [UUID: Date] = [:]
    private var remoteLastFetch: [UUID: Date] = [:]
    private var remoteInFlight: Set<UUID> = []
    private let remoteRefreshInterval: TimeInterval = 4 * 3600

    init(enforcer: Enforcer, persistence: PersistenceController = .shared) {
        self.enforcer = enforcer
        self.persistence = persistence
        let loaded = persistence.load()
        self.usage = loaded.usage
        self.rules = loaded.rules
        startTimer()
        registerHotKey()
        observeCloudChanges()
        observeSleepWake()
        resolveSources(force: Set(rules.map(\.id)))
        refresh()
    }

    /// React to iCloud key-value changes pushed from another device: merge them into memory (usage
    /// by max, rules by last-writer-wins) and re-resolve any file/URL sources whose caches were
    /// stripped for sync.
    private func observeCloudChanges() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      let merged = self.persistence.mergeFromCloud(currentRules: self.rules,
                                                                   currentUsage: self.usage)
                else { return }
                self.usage = merged.usage
                if merged.rules != self.rules {
                    self.rules = merged.rules   // didSet persists + refreshes
                    self.resolveSources(force: Set(self.rules.map(\.id)))
                } else {
                    self.refresh()
                }
            }
        }
    }

    /// Stop the budget from draining while the Mac sleeps (e.g. lid closed), and re-lock on wake.
    /// Without this, the 5s timer is suspended during sleep but the next tick after wake charges the
    /// whole sleep span (`now - unlockedSince`) — so an unlocked session left closed burns the day's
    /// budget. NSWorkspace's sleep/wake notifications post on the main thread.
    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.handleWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.handleDidWake() }
        }
    }

    /// About to sleep: charge the time used while awake, then freeze the clock so sleep doesn't count.
    private func handleWillSleep() {
        drainViewingTime()          // records awake time up to now
        unlockedSince = nil         // freeze: no accrual while asleep
        if isUnlocked { sleepStart = Date() }
    }

    /// Woke up (lid reopened). A brief nap (≤ grace) resumes the session, charging from wake so the
    /// sleep itself is free; a longer sleep re-locks so viewing time isn't spent unattended and
    /// unlock is required again. Either way, sleep time is never charged (`unlockedSince` was nil).
    private func handleDidWake() {
        let slept = sleepStart.map { Date().timeIntervalSince($0) } ?? .infinity
        sleepStart = nil
        guard isUnlocked else { return }
        if slept > sleepLockGrace {
            lock()
        } else {
            unlockedSince = Date()  // resume the clock from now
            refresh()
        }
    }

    /// How much of a rule's daily limit remains, measured against the shared pool. `nil` = no limit.
    func remainingBudget(for rule: Rule) -> TimeInterval? {
        guard let limit = rule.dailyLimit else { return nil }
        return max(0, limit - totalUsageToday)
    }

    private func liveContext(_ now: Date = Date()) -> RuleContext {
        RuleContext(now: now, calendar: .current, unblockedTimeToday: usage.total(on: now))
    }

    /// Recompute the live blocked set, hand it to the enforcer, and refresh the shared snapshot.
    /// Charges elapsed viewing time to the shared daily pool first, so a budget that runs out this
    /// tick re-blocks immediately.
    func refresh() {
        drainViewingTime()

        let context = liveContext()
        let engine = BlockEngine(rules: rules)
        let eligible = engine.eligibleRules(in: context)
        let unlockable = eligible.filter { $0.dailyLimit != nil }

        canUnlock = !unlockable.isEmpty
        openAccessActive = eligible.contains { $0.dailyLimit == nil }
        // Auto-lock once no *budgeted* rule is eligible (windows closed / budgets spent). No-limit
        // rules open on their own, so they neither need nor keep an unlock alive.
        if isUnlocked && unlockable.isEmpty {
            isUnlocked = false
            unlockedSince = nil
        }

        let previousBlocked = lastBlocked
        blockedNow = engine.blockedPatterns(unlocked: isUnlocked, in: context)
        enforcer.apply(blockedPatterns: blockedNow)
        if blockedNow != lastBlocked {
            lastBlocked = blockedNow
            persistence.writeSnapshot(PolicySnapshot(blockedPatterns: blockedNow))
        }

        // Sites that just became blocked (re-lock, window closed, budget spent, launch): close any
        // open browser tab still showing them, so an already-loaded page can't be kept reading.
        let newlyBlocked = blockedNow.subtracting(previousBlocked ?? [])
        if !newlyBlocked.isEmpty {
            TabCloser.closeTabs(blockedDomains: Set(newlyBlocked.map(\.domain)))
        }

        let total = usage.total()
        if totalUsageToday != total { totalUsageToday = total }
    }

    /// Charge the time since the last tick to the shared daily pool while unlocked. No-op while
    /// locked. One pool for all rules, so it drains at wall-clock rate regardless of how many rules
    /// are currently allowing sites — each rule re-blocks when the pool passes its own limit.
    private func drainViewingTime() {
        guard isUnlocked, let since = unlockedSince else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(since)
        unlockedSince = now
        guard elapsed > 0 else { return }
        usage.record(elapsed, at: now)
        persistence.save(rules: rules, usage: usage)
        notifyCountdown()
    }

    /// Viewing time left in the current unlock session, for the menu readout. `nil` when locked or
    /// nothing budget-limited is currently eligible.
    var viewingTimeRemaining: TimeInterval? {
        isUnlocked ? sessionRemaining() : nil
    }

    /// Viewing time left in the session: how long until every budget-limited rule has re-blocked —
    /// the largest remaining budget in the shared pool. `nil` when nothing budget-limited is active.
    private func sessionRemaining() -> TimeInterval? {
        let context = liveContext()
        let engine = BlockEngine(rules: rules)
        return engine.eligibleRules(in: context)
            .compactMap { rule in rule.dailyLimit.map { max(0, $0 - context.unblockedTimeToday) } }
            .max()
    }

    /// Post a single "time remaining" update every 5 minutes, then a final warning ~1 minute before
    /// the budget runs out. Tracks the total session time, not any one site.
    private func notifyCountdown() {
        guard let remaining = sessionRemaining() else { return }
        if remaining <= 60 {
            if !totalWarned {
                totalWarned = true
                Notifier.notify("About 1 minute of viewing time left.", id: "budget-final", sound: true)
            }
            return
        }
        let minutes = Int((remaining / 60.0).rounded(.up))
        if minutes % 5 == 0, lastNotifiedTotalMinutes != minutes {
            lastNotifiedTotalMinutes = minutes
            Notifier.notify("\(minutes) minutes of viewing time left.", id: "budget-\(minutes)")
        }
    }

    /// Seed the countdown so notifications track *decreases* from the current level rather than
    /// firing at unlock.
    private func seedBudgetNotifications() {
        totalWarned = false
        lastNotifiedTotalMinutes = sessionRemaining().map { Int(($0 / 60.0).rounded(.up)) }
    }

    // MARK: Mutations

    func add(_ rule: Rule) { rules.append(rule) }

    func delete(_ rule: Rule) { rules.removeAll { $0.id == rule.id } }

    func update(_ rule: Rule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
    }

    /// Replace all rules with those in a shared config fetched from `url` (Settings → Import). The
    /// config is the source of truth (published by `just publish-config`); remote/file-sourced rules
    /// resolve their target lists on the next refresh.
    func importConfig(from url: URL) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData   // the gist raw URL is CDN-cached
        let (data, _) = try await URLSession.shared.data(for: request)
        let config = try JSONDecoder().decode(SyncedConfig.self, from: data)
        rules = config.rules.map { $0.toRule() }              // didSet persists + refreshes
        resolveSources(force: Set(rules.map(\.id)))
    }

    func setEnabled(_ rule: Rule, isEnabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx].isEnabled = isEnabled
    }

    /// Flip a rule's enabled flag behind Touch ID. Both directions are gated so the rules screen
    /// stays deliberate rather than a free bypass.
    func toggleRuleAuthenticated(_ rule: Rule) async {
        let verb = rule.isEnabled ? "disable" : "enable"
        guard await Authentication.confirm(reason: "\(verb) an allow rule") else { return }
        setEnabled(rule, isEnabled: !rule.isEnabled)
    }

    /// Delete a rule behind Touch ID — otherwise deleting would be an unauthenticated way around
    /// the gated disable.
    func deleteAuthenticated(_ rule: Rule) async {
        guard await Authentication.confirm(reason: "delete an allow rule") else { return }
        delete(rule)
    }

    // MARK: Lock / unlock

    /// Toggle the lock. Unlocking (making sites viewable) requires Touch ID and that some rule is
    /// eligible right now; locking is immediate.
    func toggleLock() async {
        if isUnlocked { lock() } else { await unlock() }
    }

    /// Unlock the currently-allowed sites. Refused (no-op) when nothing is eligible.
    func unlock() async {
        let context = liveContext()
        let engine = BlockEngine(rules: rules)
        guard !engine.unlockableRules(in: context).isEmpty else { return }
        guard await Authentication.confirm(reason: "unlock the blocked sites") else { return }
        isUnlocked = true
        unlockedSince = Date()
        seedBudgetNotifications()
        refresh()
    }

    func lock() {
        drainViewingTime()
        isUnlocked = false
        unlockedSince = nil
        lastNotifiedTotalMinutes = nil
        totalWarned = false
        refresh()
    }

    // MARK: Target sources

    /// Point a rule at a new source. Manual sources apply immediately; file/remote kick off a
    /// resolve so the cached targets refresh right away.
    func setSource(_ rule: Rule, source: TargetSource) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx].source = source
        if case .manual(let hosts) = source {
            rules[idx].targets = hosts
            sourceStatus[rule.id] = nil
        } else {
            resolveSources(force: [rule.id])
        }
    }

    /// Bookmark a user-chosen file so the reference survives relaunches. The app is not sandboxed,
    /// so a plain bookmark (no security scope) is all that's needed to re-read the file later.
    func setFileSource(_ rule: Rule, url: URL) {
        do {
            let bookmark = try url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
            sourceLog.info("Bookmarked file source \(url.path, privacy: .public)")
            setSource(rule, source: .file(bookmark: bookmark))
        } catch {
            sourceLog.error("Bookmark failed for \(url.path, privacy: .public): \(error, privacy: .public)")
            setStatus(rule.id, error: "Couldn't access file: \(error.localizedDescription)")
        }
    }

    /// Re-fetch a remote source now (the periodic refresh is hours apart).
    func refreshSource(_ rule: Rule) {
        resolveSources(force: [rule.id])
    }

    /// The chosen file's path, for display. `nil` when the bookmark can't resolve.
    func fileDisplayPath(for rule: Rule) -> String? {
        guard case .file(let bookmark) = rule.source else { return nil }
        var stale = false
        let url = try? URL(resolvingBookmarkData: bookmark, relativeTo: nil, bookmarkDataIsStale: &stale)
        return url?.path
    }

    /// Bring file/remote-sourced target caches up to date. Files re-read when their modification
    /// date changes (checked every refresh tick — cheap stat); remotes re-fetch every few hours.
    /// Failures keep the cached list — a broken source should never silently unblock sites.
    private func resolveSources(force: Set<UUID> = []) {
        for rule in rules {
            switch rule.source {
            case .manual:
                break
            case .file(let bookmark):
                resolveFile(rule: rule, bookmark: bookmark, force: force.contains(rule.id))
            case .remote(let url):
                let due = force.contains(rule.id) || remoteLastFetch[rule.id].map {
                    Date().timeIntervalSince($0) > remoteRefreshInterval
                } ?? true
                if due { fetchRemote(rule: rule, url: url) }
            }
        }
    }

    private func resolveFile(rule: Rule, bookmark: Data, force: Bool) {
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            if stale,
               let fresh = try? url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil),
               let idx = rules.firstIndex(where: { $0.id == rule.id }) {
                sourceLog.info("Refreshed stale bookmark for \(url.path, privacy: .public)")
                rules[idx].source = .file(bookmark: fresh)
            }
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? Date()
            guard force || fileModificationDates[rule.id] != modified else { return }
            let text = try String(contentsOf: url, encoding: .utf8)
            fileModificationDates[rule.id] = modified
            let hosts = TargetImport.parse(text).map { HostPattern($0) }
            sourceLog.info("Read \(hosts.count) hosts from \(url.path, privacy: .public)")
            applyResolvedTargets(rule.id, hosts: hosts)
        } catch {
            sourceLog.error("File source read failed: \(error, privacy: .public)")
            setStatus(rule.id, error: "Couldn't read file: \(error.localizedDescription)")
        }
    }

    private func fetchRemote(rule: Rule, url: URL) {
        guard !remoteInFlight.contains(rule.id) else { return }
        remoteInFlight.insert(rule.id)
        remoteLastFetch[rule.id] = Date()
        Task { [weak self] in
            do {
                let domains = try await TargetImport.download(from: url)
                sourceLog.info("Fetched \(domains.count) hosts from \(url.absoluteString, privacy: .public)")
                self?.remoteInFlight.remove(rule.id)
                self?.applyResolvedTargets(rule.id, hosts: domains.map { HostPattern($0) })
            } catch {
                sourceLog.error("Remote source fetch failed for \(url.absoluteString, privacy: .public): \(error, privacy: .public)")
                self?.remoteInFlight.remove(rule.id)
                self?.setStatus(rule.id, error: "Download failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyResolvedTargets(_ id: UUID, hosts: [HostPattern]) {
        if let idx = rules.firstIndex(where: { $0.id == id }), rules[idx].targets != hosts {
            rules[idx].targets = hosts
        }
        setStatus(id, lastUpdated: Date(), error: nil)
    }

    private func setStatus(_ id: UUID, lastUpdated: Date? = nil, error: String?) {
        var status = sourceStatus[id] ?? SourceStatus()
        if let lastUpdated { status.lastUpdated = lastUpdated }
        status.error = error
        sourceStatus[id] = status
    }

    private func registerHotKey() {
        hotKey = GlobalHotKey.blockingToggle { [weak self] in
            Task { @MainActor in await self?.toggleLock() }
        }
    }

    private func startTimer() {
        // Re-evaluate periodically so day/time windows, budget drain, and auto-lock take effect
        // without user action. 5s is responsive enough for a re-block; evaluation is trivial and
        // the snapshot is tiny. Source resolution piggybacks (files re-read only when mtime changes).
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.resolveSources()
                self?.refresh()
            }
        }
    }
}
