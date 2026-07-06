import Foundation
import RulesEngine

/// Loads/saves the rule list + usage, and publishes the `PolicySnapshot` the content-filter
/// extension reads.
///
/// Rules + usage live in Application Support (app-private). The snapshot is written to the shared
/// App Group container so the extension — a separate process — can read it. In mock mode there is
/// no extension reading it, but we still write it so the data flow is exercised and inspectable.
struct PersistenceController {
    static let shared = PersistenceController()

    /// Must match `com.apple.security.application-groups` in both entitlements files.
    static let appGroupID = "group.com.pauljohnson.siteblocker"

    struct Loaded {
        var rules: [Rule]
        var usage: DailyUsage
    }

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SiteBlocker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var rulesURL: URL { supportDir.appendingPathComponent("rules.json") }
    private var usageURL: URL { supportDir.appendingPathComponent("usage.json") }

    /// Shared with the extension. Falls back to Application Support when the App Group container
    /// isn't available (e.g. unsigned local runs before provisioning).
    var snapshotURL: URL {
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
        return (group ?? supportDir).appendingPathComponent("policy.json")
    }

    func load() -> Loaded {
        let rules = (try? Data(contentsOf: rulesURL))
            .flatMap { try? JSONDecoder().decode([Rule].self, from: $0) }
        let usage = (try? Data(contentsOf: usageURL))
            .flatMap { try? JSONDecoder().decode(DailyUsage.self, from: $0) }
        return Loaded(rules: rules ?? Self.starterRules, usage: usage ?? DailyUsage())
    }

    func save(rules: [Rule], usage: DailyUsage) {
        if let data = try? JSONEncoder().encode(rules) { try? data.write(to: rulesURL) }
        if let data = try? JSONEncoder().encode(usage) { try? data.write(to: usageURL) }
    }

    func writeSnapshot(_ snapshot: PolicySnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: snapshotURL) }
    }

    /// Seed content so a fresh install demonstrates each condition kind.
    static let starterRules: [Rule] = [
        Rule(name: "Socials during work hours",
             targets: ["twitter.com", "reddit.com", "instagram.com"],
             condition: .allOf([
                 .onDaysOfWeek([.monday, .tuesday, .wednesday, .thursday, .friday]),
                 .duringTimeOfDay(TimeWindow(startHour: 9, endHour: 17)),
             ])),
        Rule(name: "YouTube after 30 min",
             targets: ["youtube.com"],
             condition: .afterUnblockedTime(30 * 60)),
        Rule(name: "News — always",
             isEnabled: false,
             targets: ["news.ycombinator.com"],
             condition: .always),
    ]
}
