import Foundation
import RulesEngine

/// Loads/saves the site lists + usage, and publishes the `PolicySnapshot` the content-filter
/// extension reads.
///
/// Lists + usage live in Application Support (app-private). The snapshot goes to the shared App Group
/// container so the extension — a separate process — can read it. New storage is `lists.json`; the
/// legacy `rules.json` (`[Rule]`) is migrated once and left in place.
struct PersistenceController {
    static let shared = PersistenceController()

    /// Must match `com.apple.security.application-groups` in both entitlements files.
    static let appGroupID = "group.com.pauljohnson.siteblocker"

    /// An isolated storage directory for tests. When set, iCloud sync is skipped so tests can't
    /// touch (or be perturbed by) the real key-value store.
    private let overrideDir: URL?
    init(overrideDir: URL? = nil) { self.overrideDir = overrideDir }
    private var syncsCloud: Bool { overrideDir == nil }

    struct Loaded {
        var lists: [SiteList]
        var usage: DailyUsage
    }

    private var supportDir: URL {
        if let overrideDir {
            try? FileManager.default.createDirectory(at: overrideDir, withIntermediateDirectories: true)
            return overrideDir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SiteBlocker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var listsURL: URL { supportDir.appendingPathComponent("lists.json") }
    private var legacyRulesURL: URL { supportDir.appendingPathComponent("rules.json") }
    private var usageURL: URL { supportDir.appendingPathComponent("usage.json") }

    /// Shared with the (root) extension via a fixed `/Users/Shared` path — see `PolicySnapshot.fileURL`.
    var snapshotURL: URL { PolicySnapshot.fileURL }

    // MARK: iCloud key-value sync

    private var kv: NSUbiquitousKeyValueStore { .default }
    private enum KVKey {
        static let lists = "lists", usage = "usage", listsUpdatedAt = "listsUpdatedAt"
    }
    private var localListsTimestamp: TimeInterval {
        get { UserDefaults.standard.double(forKey: "localListsTimestamp") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "localListsTimestamp") }
    }

    /// Read `lists.json`, else migrate the legacy `[Rule]` `rules.json`, else the starter set.
    private func loadLocalLists() -> [SiteList] {
        if let data = try? Data(contentsOf: listsURL),
           let lists = try? JSONDecoder().decode([SiteList].self, from: data) {
            return lists
        }
        if let data = try? Data(contentsOf: legacyRulesURL),
           let legacy = try? JSONDecoder().decode([Rule].self, from: data) {
            let migrated = legacy.map(SiteList.init(migrating:))
            try? JSONEncoder().encode(migrated).write(to: listsURL)
            return migrated
        }
        return Self.starterLists
    }

    func load() -> Loaded {
        var lists = loadLocalLists()
        var usage = (try? Data(contentsOf: usageURL))
            .flatMap { try? JSONDecoder().decode(DailyUsage.self, from: $0) } ?? DailyUsage()

        if syncsCloud {
            kv.synchronize()
            if kv.double(forKey: KVKey.listsUpdatedAt) > localListsTimestamp,
               let data = kv.data(forKey: KVKey.lists),
               let remote = try? JSONDecoder().decode([SiteList].self, from: data) {
                lists = remote
                localListsTimestamp = kv.double(forKey: KVKey.listsUpdatedAt)
            }
            if let data = kv.data(forKey: KVKey.usage),
               let remote = try? JSONDecoder().decode(DailyUsage.self, from: data) {
                usage.mergeTakingMax(remote)
            }
        }
        return Loaded(lists: lists, usage: usage)
    }

    /// Merge current iCloud state into what's in memory — used when iCloud reports an external change.
    func mergeFromCloud(currentLists: [SiteList], currentUsage: DailyUsage) -> Loaded? {
        var changed = false
        var lists = currentLists
        var usage = currentUsage
        if kv.double(forKey: KVKey.listsUpdatedAt) > localListsTimestamp,
           let data = kv.data(forKey: KVKey.lists),
           let remote = try? JSONDecoder().decode([SiteList].self, from: data) {
            lists = remote
            localListsTimestamp = kv.double(forKey: KVKey.listsUpdatedAt)
            changed = true
        }
        if let data = kv.data(forKey: KVKey.usage),
           let remote = try? JSONDecoder().decode(DailyUsage.self, from: data) {
            var merged = usage
            merged.mergeTakingMax(remote)
            if merged != usage { usage = merged; changed = true }
        }
        return changed ? Loaded(lists: lists, usage: usage) : nil
    }

    /// Serial queue for persistence I/O so saving never blocks the main thread (JSON encoding + two
    /// file writes + the iCloud key-value `synchronize()` were ~150ms on the edit path).
    private static let ioQueue = DispatchQueue(label: "com.pauljohnson.siteblocker.persistence")

    func save(lists: [SiteList], usage: DailyUsage) {
        let listsURL = self.listsURL
        let usageURL = self.usageURL
        let syncsCloud = self.syncsCloud
        Self.ioQueue.async {
            if let data = try? JSONEncoder().encode(lists) { try? data.write(to: listsURL) }
            let usageData = try? JSONEncoder().encode(usage)
            if let usageData { try? usageData.write(to: usageURL) }

            guard syncsCloud else { return }
            let kv = NSUbiquitousKeyValueStore.default
            if let slim = try? JSONEncoder().encode(lists.map(Self.strippedForSync)) {
                kv.set(slim, forKey: KVKey.lists)
                let now = Date().timeIntervalSince1970
                kv.set(now, forKey: KVKey.listsUpdatedAt)
                UserDefaults.standard.set(now, forKey: "localListsTimestamp")
            }
            if let usageData { kv.set(usageData, forKey: KVKey.usage) }
            kv.synchronize()
        }
    }

    /// Drop cached resolved targets for file/URL-sourced lists before syncing (they re-resolve per
    /// device, and a large blocklist would exceed the key-value store's 1 MB limit).
    private static func strippedForSync(_ list: SiteList) -> SiteList {
        guard case .manual = list.source else {
            var slim = list
            slim.targets = []
            return slim
        }
        return list
    }

    /// Block until queued save/snapshot writes have flushed. For tests that save then immediately
    /// load in the same process — the app itself only reloads from disk at launch (a fresh process),
    /// so the async writes have always drained by then.
    func flushPendingWrites() { Self.ioQueue.sync {} }

    func writeSnapshot(_ snapshot: PolicySnapshot) {
        let url = snapshotURL
        Self.ioQueue.async {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url) }
        }
    }

    /// Seed content for a fresh install: sites blocked by default, opened by an allow-window
    /// exception on its schedule and up to its daily budget.
    static let starterLists: [SiteList] = [
        SiteList(name: "Socials — weekday lunch",
                 targets: ["twitter.com", "x.com", "reddit.com", "instagram.com"],
                 isBlockedByDefault: true,
                 rules: [ListRule(condition: .allOf([
                     .onDaysOfWeek([.monday, .tuesday, .wednesday, .thursday, .friday]),
                     .duringTimeOfDay(TimeWindow(startHour: 12, endHour: 13)),
                 ]), dailyLimit: 30 * 60)]),
        SiteList(name: "YouTube — 20 min/day",
                 targets: ["youtube.com"],
                 isBlockedByDefault: true,
                 rules: [ListRule(condition: .always, dailyLimit: 20 * 60)]),
    ]
}
