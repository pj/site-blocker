import XCTest
import RulesEngine
// PersistenceController is compiled into this test target (see project.yml).

/// Integration tests for the macOS persistence layer: save/load round-trip and the one-time
/// migration of the legacy `[Rule]` `rules.json` into `[SiteList]` `lists.json`.
final class PersistenceTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSaveLoadRoundTrip() {
        let dir = tempDir()
        let lists = [
            SiteList(name: "Social", targets: ["x.com", "reddit.com"],
                     rules: [ListRule(action: .allow, condition: .onDaysOfWeek([.saturday])),
                             ListRule(action: .deny)]),
            SiteList(name: "Ads", targets: [], source: .remote(URL(string: "https://e.com/l.txt")!),
                     rules: [ListRule(action: .deny)]),
        ]
        PersistenceController(overrideDir: dir).save(lists: lists, usage: DailyUsage())
        let loaded = PersistenceController(overrideDir: dir).load()
        XCTAssertEqual(loaded.lists, lists)
    }

    func testMigratesLegacyRulesJson() throws {
        let dir = tempDir()
        let rule = Rule(name: "YouTube", targets: ["youtube.com"],
                        condition: .always, dailyLimit: 1200)
        try JSONEncoder().encode([rule]).write(to: dir.appendingPathComponent("rules.json"))

        let loaded = PersistenceController(overrideDir: dir).load()
        XCTAssertEqual(loaded.lists.count, 1)
        let list = loaded.lists[0]
        XCTAssertEqual(list.name, "YouTube")
        XCTAssertEqual(list.targets.map(\.domain), ["youtube.com"])
        // Allow rule (schedule + limit) followed by the catch-all Deny.
        XCTAssertEqual(list.rules.count, 2)
        XCTAssertEqual(list.rules[0].action, .allow)
        XCTAssertEqual(list.rules[0].dailyLimit, 1200)
        XCTAssertEqual(list.rules[1].action, .deny)

        // Migration wrote lists.json, so a second load reads it directly (no re-migration).
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("lists.json").path))
    }

    func testStarterListsWhenEmpty() {
        let loaded = PersistenceController(overrideDir: tempDir()).load()
        XCTAssertFalse(loaded.lists.isEmpty)   // seeded starter content
    }
}
