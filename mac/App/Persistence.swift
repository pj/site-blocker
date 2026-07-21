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

    /// Shared with the (root) extension via a fixed `/Users/Shared` path — see `PolicySnapshot.fileURL`.
    var snapshotURL: URL { PolicySnapshot.fileURL }

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
        let dir = snapshotURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: snapshotURL) }
    }

    /// Seed content so a fresh install shows the allow model: sites blocked by default, viewable
    /// only inside the rule's window and up to its daily budget.
    static let starterRules: [Rule] = [
        Rule(name: "Socials — weekday lunch",
             targets: ["twitter.com", "x.com", "reddit.com", "instagram.com"],
             condition: .allOf([
                 .onDaysOfWeek([.monday, .tuesday, .wednesday, .thursday, .friday]),
                 .duringTimeOfDay(TimeWindow(startHour: 12, endHour: 13)),
             ]),
             dailyLimit: 30 * 60),
        Rule(name: "YouTube — 20 min/day",
             targets: ["youtube.com"],
             condition: .always,
             dailyLimit: 20 * 60),
    ]
}
