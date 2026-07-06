import Foundation
import RulesEngine

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

    init(enforcer: Enforcer, persistence: PersistenceController = .shared) {
        self.enforcer = enforcer
        self.persistence = persistence
        let loaded = persistence.load()
        self.usage = loaded.usage
        self.rules = loaded.rules
        startTimer()
        registerHotKey()
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
        // runs out; evaluation is trivial and the snapshot is tiny.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}
