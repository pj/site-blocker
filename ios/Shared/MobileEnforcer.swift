import Foundation

/// Site-blocking enforcement for the app. Owns the shared rule storage and the paused flag, and
/// rebuilds the Safari content-blocker ruleset from the currently-blocked domains.
///
/// Model: every enabled rule's domains are blocked in Safari unless blocking is paused. There's no
/// schedule (that needs DeviceActivity/Family Controls); `reevaluate()` just recomputes the blocked
/// set and hands it to `SiteRuleset`. The app calls it on edits and on pause/resume.
enum MobileEnforcer {
    static let appGroup = "group.com.pauljohnson.siteblocker"

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
        get { UserDefaults(suiteName: appGroup)?.bool(forKey: "isPaused") ?? false }
        set { UserDefaults(suiteName: appGroup)?.set(newValue, forKey: "isPaused") }
    }

    // MARK: Evaluation

    /// Recompute the blocked domain set and rewrite the Safari ruleset.
    static func reevaluate() {
        let domains = isPaused ? [] : loadRules()
            .filter(\.isEnabled)
            .flatMap(\.siteDomains)
        SiteRuleset.rebuild(blocking: Array(Set(domains)))
    }
}
