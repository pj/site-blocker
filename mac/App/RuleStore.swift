import Foundation
import OSLog
import RulesEngine

/// Unified-log logger; view with `just logs` (stream) or
/// `log show --last 1h --predicate 'subsystem == "com.pauljohnson.siteblocker"'`.
let sourceLog = Logger(subsystem: "com.pauljohnson.siteblocker", category: "sources")

/// The app-side coordinator: owns the rules + usage, recomputes what's blocked, and pushes to the
/// enforcer. Pure evaluation lives in `BlockEngine`; this type is just the wiring (clock, timer,
/// persistence, enforcement hand-off) that a pure value type shouldn't hold.
@MainActor
final class RuleStore: ObservableObject {
    @Published var rules: [Rule] {
        didSet { persistence.save(rules: rules, usage: usage); refresh() }
    }

    /// Host patterns actively blocked *right now* (real clock). Drives the status view.
    @Published private(set) var blockedNow: Set<HostPattern> = []

    /// Instant used by the "what would be blocked at…" preview panel.
    @Published var previewDate: Date = Date()

    /// Master switch. When off, nothing is blocked regardless of rules. Turning it off is guarded by
    /// authentication (see `toggleBlocking`). Deliberately **not** persisted — every launch starts
    /// enabled, so quitting/relaunching always re-enables blocking.
    @Published private(set) var blockingEnabled = true

    private var usage: DailyUsage
    private let enforcer: Enforcer
    private let persistence: PersistenceController
    private var timer: Timer?
    private var hotKey: GlobalHotKey?

    /// Set while the master block is off: the moment up to which unblocked time has been accrued.
    /// The daily quota counts wall-clock time with blocking disabled, not time spent on any site.
    private var unblockedSince: Date?

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
        resolveSources(force: Set(rules.map(\.id)))
        refresh()
    }

    /// Today's accrued unblocked time. Published so the counter next to the block button and the
    /// exhausted-quota chip tint update live as the allowance drains.
    @Published private(set) var unblockedTimeToday: TimeInterval = 0

    private func liveContext() -> RuleContext {
        RuleContext(now: Date(), calendar: .current, unblockedTimeToday: usage.unblockedTime())
    }

    /// Recompute the live blocked set, hand it to the enforcer, and refresh the shared snapshot.
    ///
    /// Master on: all rules apply, with quota atoms treated as satisfied (the allowance only
    /// governs unblocked time). Master off: only quota rules survive, evaluated against the real
    /// accrued time — so when the day's allowance hits zero they forcibly re-block their sites.
    func refresh() {
        accrueUnblockedTime()
        if unblockedTimeToday != usage.unblockedTime() {
            unblockedTimeToday = usage.unblockedTime()
        }
        let effectiveRules: [Rule]
        if blockingEnabled {
            effectiveRules = rules.map { rule in
                var adjusted = rule
                adjusted.condition = rule.condition.quotaSatisfied
                return adjusted
            }
        } else {
            effectiveRules = rules.filter { $0.condition.containsQuota }
        }
        let engine = BlockEngine(rules: effectiveRules)
        blockedNow = engine.blockedPatterns(in: liveContext())
        enforcer.apply(blockedPatterns: blockedNow)
        persistence.writeSnapshot(
            PolicySnapshot(rules: effectiveRules, unblockedTimeToday: usage.unblockedTime()))
    }

    /// Which rules would be active at `date`, for the preview panel. Uses today's usage total.
    func activeRules(at date: Date) -> [Rule] {
        let context = RuleContext(now: date, calendar: .current,
                                  unblockedTimeToday: usage.unblockedTime())
        return rules.filter { $0.isActive(in: context) }
    }

    // MARK: Mutations

    func add(_ rule: Rule) { rules.append(rule) }

    func delete(at offsets: IndexSet) { rules.remove(atOffsets: offsets) }

    func delete(_ rule: Rule) { rules.removeAll { $0.id == rule.id } }

    func update(_ rule: Rule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
    }

    func setEnabled(_ rule: Rule, isEnabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx].isEnabled = isEnabled
    }

    /// Flip a rule's enabled flag behind Touch ID / password. Both directions are gated so the
    /// rules screen stays deliberate rather than a free bypass.
    func toggleRuleAuthenticated(_ rule: Rule) async {
        let verb = rule.isEnabled ? "disable" : "enable"
        guard await Authentication.confirm(reason: "\(verb) a blocking rule") else { return }
        setEnabled(rule, isEnabled: !rule.isEnabled)
    }

    /// Delete a rule behind Touch ID / password — otherwise deleting would be an unauthenticated
    /// way around the gated disable.
    func deleteAuthenticated(_ rule: Rule) async {
        guard await Authentication.confirm(reason: "delete a blocking rule") else { return }
        delete(rule)
    }

    // MARK: Master switch

    func setBlockingEnabled(_ enabled: Bool) {
        if enabled {
            accrueUnblockedTime()   // bank the final unblocked chunk while still off
            unblockedSince = nil
        } else {
            unblockedSince = Date()
        }
        blockingEnabled = enabled
        refresh()
    }

    /// Add the wall-clock time since the last accrual to today's usage. Runs on every refresh
    /// tick while the master block is off; no-op while it's on.
    private func accrueUnblockedTime() {
        guard !blockingEnabled, let since = unblockedSince else { return }
        let now = Date()
        usage.record(now.timeIntervalSince(since))
        unblockedSince = now
        persistence.save(rules: rules, usage: usage)
    }

    /// Toggle the master switch. Turning blocking **off** requires authentication (Touch ID /
    /// password) as a barrier; turning it back on is immediate.
    func toggleBlocking() async {
        if blockingEnabled {
            guard await Authentication.confirm(reason: "end the site block") else { return }
            setBlockingEnabled(false)
        } else {
            setBlockingEnabled(true)
        }
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
            Task { @MainActor in await self?.toggleBlocking() }
        }
    }

    /// Debug affordance: without the real extension there's no live flow telemetry, so let the UI
    /// inject "distraction time" to exercise `afterUnblockedTime` rules. In production this number
    /// comes from the extension reporting time spent on allowed target hosts.
    func simulateUnblockedTime(minutes: Double) {
        usage.record(minutes * 60)
        persistence.save(rules: rules, usage: usage)
        refresh()
    }

    private func startTimer() {
        // Re-evaluate periodically so time-of-day transitions and the unblocked-time countdown
        // take effect without user action. 5s keeps the forcible re-block prompt when a quota
        // runs out; evaluation is trivial and the snapshot is tiny. Source resolution piggybacks
        // on the same tick (files re-read only when their mtime changes).
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.resolveSources()
                self?.refresh()
            }
        }
    }
}
