import Foundation
import AppKit
import OSLog
import RulesEngine

/// Unified-log logger; view with `just logs`.
let sourceLog = Logger(subsystem: "com.pauljohnson.siteblocker", category: "sources")

/// App-side coordinator for the redesigned model. Each **site list** resolves its ordered Allow/Deny
/// rules against the current moment (first active rule wins; see `ListEngine`). The user *unlocks*
/// (Touch ID) to open the limited Allow rules, whose sites drain a shared daily budget while
/// unlocked. Pure evaluation lives in `ListEngine`; this type is the wiring (clock, timer,
/// persistence, sources, enforcement hand-off).
@MainActor
final class RuleStore: ObservableObject {
    @Published var lists: [SiteList] {
        didSet {
            persistence.save(lists: lists, usage: usage)
            refresh()
            ensureCalendarAccessIfNeeded()
        }
    }

    /// Host patterns actively blocked *right now*. Drives the status view.
    @Published private(set) var blockedNow: Set<HostPattern> = []

    /// Whether the sites are currently unlocked. Locked by default; not persisted, so every launch
    /// starts locked — the safe default.
    @Published private(set) var isUnlocked = false

    /// Master switch: when true, all blocking is paused across every list. Not persisted, so every
    /// launch starts enforcing — the safe default.
    @Published private(set) var isDisabled = false

    /// Whether unlocking would open at least one limited list right now. Drives the Unlock control.
    @Published private(set) var canUnlock = false

    /// Whether some list is open via a no-limit Allow rule (auto-open). Lets the UI show an "open"
    /// state even while locked.
    @Published private(set) var openAccessActive = false

    /// Total unblocked time used today — the shared pool all limited rules draw down. For readouts.
    @Published private(set) var totalUsageToday: TimeInterval = 0

    /// IDs of lists whose sites are blocked *right now* — for the live per-list status dot.
    @Published private(set) var blockedListIDs: Set<UUID> = []

    private var usage: DailyUsage
    private let enforcer: Enforcer
    private let persistence: PersistenceController
    private let calendarResolver = CalendarResolver()
    private var timer: Timer?
    private var hotKey: GlobalHotKey?

    private var unlockedSince: Date?
    private var sleepStart: Date?
    private let sleepLockGrace: TimeInterval = 5 * 60
    private var lastBlocked: Set<HostPattern>?
    private var lastNotifiedTotalMinutes: Int?
    private var totalWarned = false

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
        self.lists = loaded.lists
        startTimer()
        registerHotKey()
        observeCloudChanges()
        observeSleepWake()
        resolveSources(force: Set(lists.map(\.id)))
        refresh()
        ensureCalendarAccessIfNeeded()
    }

    // MARK: iCloud + sleep/wake

    private func observeCloudChanges() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      let merged = self.persistence.mergeFromCloud(currentLists: self.lists,
                                                                   currentUsage: self.usage)
                else { return }
                self.usage = merged.usage
                if merged.lists != self.lists {
                    self.lists = merged.lists   // didSet persists + refreshes
                    self.resolveSources(force: Set(self.lists.map(\.id)))
                } else {
                    self.refresh()
                }
            }
        }
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.handleWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.handleDidWake() }
        }
    }

    private func handleWillSleep() {
        drainViewingTime()
        unlockedSince = nil
        if isUnlocked { sleepStart = Date() }
    }

    private func handleDidWake() {
        let slept = sleepStart.map { Date().timeIntervalSince($0) } ?? .infinity
        sleepStart = nil
        guard isUnlocked else { return }
        if slept > sleepLockGrace {
            lock()
        } else {
            unlockedSince = Date()
            refresh()
        }
    }

    // MARK: Evaluation

    /// How much of a rule's daily limit remains, measured against the shared pool. `nil` = no limit.
    func remainingBudget(for rule: ListRule) -> TimeInterval? {
        guard let limit = rule.dailyLimit else { return nil }
        return max(0, limit - totalUsageToday)
    }

    private func liveContext(_ now: Date = Date()) -> RuleContext {
        let calendarIDs = calendarResolver.activeCalendarIDs(
            among: Set(lists.referencedCalendars.map(\.id)), now: now)
        return RuleContext(now: now, calendar: .current,
                           unblockedTimeToday: usage.total(on: now),
                           activeCalendarIDs: calendarIDs)
    }

    /// Calendars the user can attach to an exception (empty until calendar access is granted).
    func availableCalendars() -> [CalendarSource] { calendarResolver.availableCalendars() }

    /// Ensure calendar access if any list references a calendar; then re-evaluate.
    func ensureCalendarAccessIfNeeded() {
        guard !lists.referencedCalendars.isEmpty, !calendarResolver.authorized else { return }
        Task { await calendarResolver.requestAccess(); refresh() }
    }

    /// Prompt for calendar access on demand (e.g. when the user opens the calendar picker).
    func requestCalendarAccess() async {
        await calendarResolver.requestAccess()
        refresh()
    }

    /// Recompute the live blocked set, hand it to the enforcer, and refresh the shared snapshot.
    func refresh() {
        drainViewingTime()

        // Master switch off → nothing is blocked, regardless of any list's rules.
        if isDisabled {
            canUnlock = false
            openAccessActive = false
            isUnlocked = false
            unlockedSince = nil
            blockedListIDs = []
            blockedNow = []
            enforcer.apply(blockedPatterns: [])
            if lastBlocked != [] {
                lastBlocked = []
                persistence.writeSnapshot(PolicySnapshot(blockedPatterns: []))
            }
            let total = usage.total()
            if totalUsageToday != total { totalUsageToday = total }
            return
        }

        let context = liveContext()
        let engine = ListEngine(lists: lists)

        canUnlock = engine.canUnlock(in: context)
        openAccessActive = engine.openAccessActive(in: context)
        // Auto-lock once nothing limited is left to unlock (windows closed / budgets spent).
        if isUnlocked && !canUnlock {
            isUnlocked = false
            unlockedSince = nil
        }

        blockedListIDs = Set(lists.filter {
            engine.decision(for: $0, unlocked: isUnlocked, in: context) == .blocked
        }.map(\.id))

        let previousBlocked = lastBlocked
        blockedNow = engine.blockedPatterns(unlocked: isUnlocked, in: context)
        enforcer.apply(blockedPatterns: blockedNow)
        if blockedNow != lastBlocked {
            lastBlocked = blockedNow
            persistence.writeSnapshot(PolicySnapshot(blockedPatterns: blockedNow))
        }

        let newlyBlocked = blockedNow.subtracting(previousBlocked ?? [])
        if !newlyBlocked.isEmpty {
            TabCloser.closeTabs(blockedDomains: Set(newlyBlocked.map(\.domain)))
        }

        let total = usage.total()
        if totalUsageToday != total { totalUsageToday = total }
    }

    /// Charge the time since the last tick to the shared daily pool while unlocked. No-op locked.
    private func drainViewingTime() {
        guard isUnlocked, let since = unlockedSince else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(since)
        unlockedSince = now
        guard elapsed > 0 else { return }
        usage.record(elapsed, at: now)
        persistence.save(lists: lists, usage: usage)
        notifyCountdown()
    }

    /// Viewing time left in the current unlock session, for the menu readout.
    var viewingTimeRemaining: TimeInterval? {
        isUnlocked ? ListEngine(lists: lists).sessionRemaining(in: liveContext()) : nil
    }

    private func notifyCountdown() {
        guard let remaining = ListEngine(lists: lists).sessionRemaining(in: liveContext()) else { return }
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

    private func seedBudgetNotifications() {
        totalWarned = false
        lastNotifiedTotalMinutes = ListEngine(lists: lists).sessionRemaining(in: liveContext())
            .map { Int(($0 / 60.0).rounded(.up)) }
    }

    // MARK: List mutations

    func add(_ list: SiteList) { lists.append(list) }
    func delete(_ list: SiteList) { lists.removeAll { $0.id == list.id } }
    func update(_ list: SiteList) {
        guard let idx = lists.firstIndex(where: { $0.id == list.id }) else { return }
        lists[idx] = list
    }
    func move(from offsets: IndexSet, to destination: Int) {
        lists.move(fromOffsets: offsets, toOffset: destination)
    }

    func setEnabled(_ list: SiteList, isEnabled: Bool) {
        guard let idx = lists.firstIndex(where: { $0.id == list.id }) else { return }
        lists[idx].isEnabled = isEnabled
    }

    /// Flip a list's enabled flag behind Touch ID (both directions, so it stays deliberate).
    func toggleListAuthenticated(_ list: SiteList) async {
        let verb = list.isEnabled ? "disable" : "enable"
        guard await Authentication.confirm(reason: "\(verb) a site list") else { return }
        setEnabled(list, isEnabled: !list.isEnabled)
    }

    /// Delete a list behind Touch ID — otherwise deleting is an unauthenticated bypass.
    func deleteAuthenticated(_ list: SiteList) async {
        guard await Authentication.confirm(reason: "delete a site list") else { return }
        delete(list)
    }

    /// Replace all lists from a shared config (Settings → Import). The legacy config format maps each
    /// entry to a list with one Allow rule (a multi-rule sync format is a follow-up).
    func importConfig(from url: URL) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        let config = try JSONDecoder().decode(SyncedConfig.self, from: data)
        lists = config.toSiteLists()   // handles v2 (lists) and legacy v1 (rules)
        resolveSources(force: Set(lists.map(\.id)))
    }

    // MARK: Lock / unlock

    func toggleLock() async {
        if isUnlocked { lock() } else { await unlock() }
    }

    /// Master enable/disable for all blocking. Disabling loosens enforcement, so it's gated behind
    /// Touch ID; re-enabling is stricter and needs no auth.
    func toggleDisabledAuthenticated() async {
        if !isDisabled {
            guard await Authentication.confirm(reason: "disable all blocking") else { return }
            isDisabled = true
        } else {
            isDisabled = false
        }
        refresh()
    }

    func unlock() async {
        guard ListEngine(lists: lists).canUnlock(in: liveContext()) else { return }
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

    // MARK: Target sources (per list)

    func setSource(_ list: SiteList, source: TargetSource) {
        guard let idx = lists.firstIndex(where: { $0.id == list.id }) else { return }
        lists[idx].source = source
        if case .manual(let hosts) = source {
            lists[idx].targets = hosts
            sourceStatus[list.id] = nil
        } else {
            resolveSources(force: [list.id])
        }
    }

    func setFileSource(_ list: SiteList, url: URL) {
        do {
            let bookmark = try url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
            sourceLog.info("Bookmarked file source \(url.path, privacy: .public)")
            setSource(list, source: .file(bookmark: bookmark))
        } catch {
            sourceLog.error("Bookmark failed for \(url.path, privacy: .public): \(error, privacy: .public)")
            setStatus(list.id, error: "Couldn't access file: \(error.localizedDescription)")
        }
    }

    func refreshSource(_ list: SiteList) {
        resolveSources(force: [list.id])
    }

    func fileDisplayPath(for list: SiteList) -> String? {
        guard case .file(let bookmark) = list.source else { return nil }
        var stale = false
        let url = try? URL(resolvingBookmarkData: bookmark, relativeTo: nil, bookmarkDataIsStale: &stale)
        return url?.path
    }

    private func resolveSources(force: Set<UUID> = []) {
        for list in lists {
            switch list.source {
            case .manual:
                break
            case .file(let bookmark):
                resolveFile(list: list, bookmark: bookmark, force: force.contains(list.id))
            case .remote(let url):
                let due = force.contains(list.id) || remoteLastFetch[list.id].map {
                    Date().timeIntervalSince($0) > remoteRefreshInterval
                } ?? true
                if due { fetchRemote(list: list, url: url) }
            }
        }
    }

    private func resolveFile(list: SiteList, bookmark: Data, force: Bool) {
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            if stale,
               let fresh = try? url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil),
               let idx = lists.firstIndex(where: { $0.id == list.id }) {
                sourceLog.info("Refreshed stale bookmark for \(url.path, privacy: .public)")
                lists[idx].source = .file(bookmark: fresh)
            }
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? Date()
            guard force || fileModificationDates[list.id] != modified else { return }
            let text = try String(contentsOf: url, encoding: .utf8)
            fileModificationDates[list.id] = modified
            let hosts = TargetImport.parse(text).map { HostPattern($0) }
            sourceLog.info("Read \(hosts.count) hosts from \(url.path, privacy: .public)")
            applyResolvedTargets(list.id, hosts: hosts)
        } catch {
            sourceLog.error("File source read failed: \(error, privacy: .public)")
            setStatus(list.id, error: "Couldn't read file: \(error.localizedDescription)")
        }
    }

    private func fetchRemote(list: SiteList, url: URL) {
        guard !remoteInFlight.contains(list.id) else { return }
        remoteInFlight.insert(list.id)
        remoteLastFetch[list.id] = Date()
        Task { [weak self] in
            do {
                let domains = try await TargetImport.download(from: url)
                sourceLog.info("Fetched \(domains.count) hosts from \(url.absoluteString, privacy: .public)")
                self?.remoteInFlight.remove(list.id)
                self?.applyResolvedTargets(list.id, hosts: domains.map { HostPattern($0) })
            } catch {
                sourceLog.error("Remote source fetch failed for \(url.absoluteString, privacy: .public): \(error, privacy: .public)")
                self?.remoteInFlight.remove(list.id)
                self?.setStatus(list.id, error: "Download failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyResolvedTargets(_ id: UUID, hosts: [HostPattern]) {
        if let idx = lists.firstIndex(where: { $0.id == id }), lists[idx].targets != hosts {
            lists[idx].targets = hosts
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
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.resolveSources()
                self?.refresh()
            }
        }
    }
}
