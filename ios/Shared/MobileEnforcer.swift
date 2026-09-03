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

    /// Temporarily unblock everything (a break). Persisted in the App Group.
    static var isPaused: Bool {
        get { defaults?.bool(forKey: "isPaused") ?? false }
        set { defaults?.set(newValue, forKey: "isPaused") }
    }

    // MARK: Face-ID unlock state

    /// The day the user unlocked the Face-ID-gated rules. An unlock lasts until they re-lock or the
    /// calendar day rolls over (there's no time budget on iOS, so it can't drain).
    private static var unlockedDay: Date? {
        get { defaults?.object(forKey: "unlockedDay") as? Date }
        set {
            if let newValue { defaults?.set(newValue, forKey: "unlockedDay") }
            else { defaults?.removeObject(forKey: "unlockedDay") }
        }
    }

    /// Whether the gated rules are currently unlocked (only counts if the unlock was today).
    static var isUnlocked: Bool {
        guard let day = unlockedDay else { return false }
        return Calendar.current.isDateInToday(day)
    }

    static func setUnlocked(_ on: Bool) {
        unlockedDay = on ? Calendar.current.startOfDay(for: Date()) : nil
    }

    // MARK: Evaluation

    private static func engine() -> BlockEngine {
        BlockEngine(rules: loadRules().map(\.asRule))
    }

    /// The domains blocked at this instant: paused → nothing; otherwise the engine's blocked set for
    /// the current time and unlock state.
    static func blockedDomainsNow() -> [String] {
        guard !isPaused else { return [] }
        let blocked = engine().blockedPatterns(unlocked: isUnlocked, in: RuleContext())
        return blocked.map(\.domain)
    }

    /// True when some Face-ID-gated rule's window is open right now — i.e. unlocking would reveal
    /// something. Drives whether the Unlock control is offered.
    static func canUnlockNow() -> Bool {
        !engine().unlockableRules(in: RuleContext()).isEmpty
    }

    /// Recompute the blocked domain set and rewrite the Safari ruleset.
    static func reevaluate() {
        SiteRuleset.rebuild(blocking: blockedDomainsNow())
    }
}
