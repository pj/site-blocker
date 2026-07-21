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

    // MARK: iCloud key-value sync
    //
    // State is mirrored into `NSUbiquitousKeyValueStore` when signed into iCloud (it's a harmless
    // local no-op otherwise). Rules use last-writer-wins by timestamp; usage always merges by max
    // so a sync can never hand back viewing time already spent. Resolved file/URL blocklists are
    // stripped before syncing (they re-resolve per device, and the 1 MB KVS cap is small).

    private var kv: NSUbiquitousKeyValueStore { .default }
    private enum KVKey {
        static let rules = "rules", usage = "usage", rulesUpdatedAt = "rulesUpdatedAt"
    }
    /// Local marker for "when did *this* device last change the rules", to compare against iCloud.
    private var localRulesTimestamp: TimeInterval {
        get { UserDefaults.standard.double(forKey: "localRulesTimestamp") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "localRulesTimestamp") }
    }

    func load() -> Loaded {
        var rules = (try? Data(contentsOf: rulesURL))
            .flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? Self.starterRules
        var usage = (try? Data(contentsOf: usageURL))
            .flatMap { try? JSONDecoder().decode(DailyUsage.self, from: $0) } ?? DailyUsage()

        kv.synchronize()
        // Adopt iCloud rules if another device changed them more recently than this one.
        if kv.double(forKey: KVKey.rulesUpdatedAt) > localRulesTimestamp,
           let data = kv.data(forKey: KVKey.rules),
           let remote = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = remote
            localRulesTimestamp = kv.double(forKey: KVKey.rulesUpdatedAt)
        }
        if let data = kv.data(forKey: KVKey.usage),
           let remote = try? JSONDecoder().decode(DailyUsage.self, from: data) {
            usage.mergeTakingMax(remote)
        }
        return Loaded(rules: rules, usage: usage)
    }

    /// Merge current iCloud state into what's in memory — used when iCloud reports an external
    /// change from another device. Returns `nil` when nothing relevant changed.
    func mergeFromCloud(currentRules: [Rule], currentUsage: DailyUsage) -> Loaded? {
        var changed = false
        var rules = currentRules
        var usage = currentUsage
        if kv.double(forKey: KVKey.rulesUpdatedAt) > localRulesTimestamp,
           let data = kv.data(forKey: KVKey.rules),
           let remote = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = remote
            localRulesTimestamp = kv.double(forKey: KVKey.rulesUpdatedAt)
            changed = true
        }
        if let data = kv.data(forKey: KVKey.usage),
           let remote = try? JSONDecoder().decode(DailyUsage.self, from: data) {
            var merged = usage
            merged.mergeTakingMax(remote)
            if merged != usage { usage = merged; changed = true }
        }
        return changed ? Loaded(rules: rules, usage: usage) : nil
    }

    func save(rules: [Rule], usage: DailyUsage) {
        let rulesData = try? JSONEncoder().encode(rules)
        let usageData = try? JSONEncoder().encode(usage)
        if let rulesData { try? rulesData.write(to: rulesURL) }
        if let usageData { try? usageData.write(to: usageURL) }

        // Mirror to iCloud. Sync a slimmed copy of the rules (resolved file/URL blocklists dropped —
        // they re-resolve per device and would blow the 1 MB cap).
        if let slim = try? JSONEncoder().encode(rules.map(Self.strippedForSync)) {
            kv.set(slim, forKey: KVKey.rules)
            let now = Date().timeIntervalSince1970
            kv.set(now, forKey: KVKey.rulesUpdatedAt)
            localRulesTimestamp = now
        }
        if let usageData { kv.set(usageData, forKey: KVKey.usage) }
        kv.synchronize()
    }

    /// Drop the cached resolved targets for file/URL-sourced rules before syncing — those re-resolve
    /// on each device, and a large blocklist would exceed the key-value store's 1 MB limit.
    private static func strippedForSync(_ rule: Rule) -> Rule {
        guard case .manual = rule.source else {
            var slim = rule
            slim.targets = []
            return slim
        }
        return rule
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
