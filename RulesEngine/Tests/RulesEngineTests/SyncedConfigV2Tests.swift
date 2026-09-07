import XCTest
@testable import RulesEngine

/// Round-trip tests for the v2 (site-lists) sync format, plus v1 back-compat.
final class SyncedConfigV2Tests: XCTestCase {

    private func decode(_ json: String) throws -> SyncedConfig {
        try JSONDecoder().decode(SyncedConfig.self, from: Data(json.utf8))
    }

    func testDecodesV2ListsWithOrderedRules() throws {
        let json = """
        {"version":2,"updatedAt":"now","lists":[
          {"name":"Social","enabled":true,"domains":["x.com","reddit.com"],"defaultAllowed":false,
           "rules":[
             {"action":"allow","enabled":true,"days":["sat","sun"]},
             {"action":"allow","enabled":true,"window":{"start":"12:00","end":"13:00"},"dailyLimitMinutes":30},
             {"action":"deny","enabled":true,"days":["mon","tue","wed","thu","fri"]}
           ]}
        ]}
        """
        let lists = try decode(json).toSiteLists()
        XCTAssertEqual(lists.count, 1)
        let list = lists[0]
        XCTAssertEqual(list.name, "Social")
        XCTAssertEqual(Set(list.targets.map(\.domain)), ["x.com", "reddit.com"])
        XCTAssertEqual(list.rules.count, 3)
        XCTAssertEqual(list.rules[0].action, .allow)
        XCTAssertEqual(list.rules[0].condition, .onDaysOfWeek([.saturday, .sunday]))
        XCTAssertEqual(list.rules[1].dailyLimit, 30 * 60)
        XCTAssertEqual(list.rules[2].action, .deny)
        if case .manual = list.source {} else { XCTFail("expected manual source") }
    }

    func testV2RemoteBlocklistBecomesRemoteSource() throws {
        let json = """
        {"version":2,"updatedAt":"now","lists":[
          {"name":"Ads","enabled":true,"domains":[],"blocklistUrl":"https://example.com/list.txt",
           "defaultAllowed":false,"rules":[{"action":"deny","enabled":true}]}
        ]}
        """
        let list = try decode(json).toSiteLists()[0]
        if case .remote(let url) = list.source {
            XCTAssertEqual(url.absoluteString, "https://example.com/list.txt")
        } else { XCTFail("expected remote source") }
        XCTAssertTrue(list.targets.isEmpty)
        XCTAssertEqual(list.rules[0].action, .deny)
    }

    func testDecodesLegacyV1Rules() throws {
        let json = """
        {"version":1,"updatedAt":"now","rules":[
          {"name":"YT","enabled":true,"domains":["youtube.com"],"dailyLimitMinutes":20}
        ]}
        """
        let lists = try decode(json).toSiteLists()
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists[0].name, "YT")
        XCTAssertEqual(lists[0].targets.map(\.domain), ["youtube.com"])
        // v1 → an Allow rule with the limit, followed by the catch-all Deny.
        XCTAssertEqual(lists[0].rules.count, 2)
        XCTAssertEqual(lists[0].rules[0].action, .allow)
        XCTAssertEqual(lists[0].rules[0].dailyLimit, 20 * 60)
        XCTAssertEqual(lists[0].rules[1].action, .deny)
    }

    /// End-to-end: a v2 config JSON → decode → toSiteLists → ListEngine → the blocked set, the exact
    /// pipeline both apps run. Social is deny Mon–Fri but allow at Sat/Sun and (unlocked) at lunch;
    /// Ads is always blocked.
    func testConfigToBlockedPatternsPipeline() throws {
        let json = """
        {"version":2,"updatedAt":"now","lists":[
          {"name":"Social","enabled":true,"domains":["x.com","reddit.com"],"defaultAllowed":false,
           "rules":[
             {"action":"allow","enabled":true,"days":["sat","sun"]},
             {"action":"allow","enabled":true,"window":{"start":"12:00","end":"13:00"},"dailyLimitMinutes":30},
             {"action":"deny","enabled":true,"days":["mon","tue","wed","thu","fri"]}
           ]},
          {"name":"Ads","enabled":true,"domains":["ads.example"],"defaultAllowed":false,
           "rules":[{"action":"deny","enabled":true}]}
        ]}
        """
        let engine = ListEngine(lists: try decode(json).toSiteLists())
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        func at(_ d: Int, _ h: Int) -> Date {
            var c = DateComponents(); c.year = 2026; c.month = 7; c.day = d; c.hour = h
            c.timeZone = TimeZone(identifier: "UTC")!
            return Calendar(identifier: .gregorian).date(from: c)!
        }
        func blocked(_ date: Date, unlocked: Bool = false, used: TimeInterval = 0) -> Set<String> {
            Set(engine.blockedPatterns(unlocked: unlocked,
                in: RuleContext(now: date, calendar: utc, unblockedTimeToday: used)).map(\.domain))
        }
        // Mon 09:00 → Social denied, Ads always denied.
        XCTAssertEqual(blocked(at(6, 9)), ["x.com", "reddit.com", "ads.example"])
        // Sat 15:00 → Social allowed (rule 1); Ads still denied.
        XCTAssertEqual(blocked(at(11, 15)), ["ads.example"])
        // Mon lunch, unlocked with budget → Social opens (rule 2); Ads denied.
        XCTAssertEqual(blocked(at(6, 12), unlocked: true), ["ads.example"])
        // Mon lunch, locked → Social blocked (limited rule needs unlock).
        XCTAssertEqual(blocked(at(6, 12)), ["x.com", "reddit.com", "ads.example"])
    }

    func testRuleWithNoDaysIsAlways_AndPresentEmptyIsNever() {
        // nil days → .always
        XCTAssertEqual(SyncedConfig.SyncedListRule(action: "allow").toListRule().condition, .always)
        // present-but-empty days → never
        XCTAssertEqual(SyncedConfig.SyncedListRule(action: "deny", days: []).toListRule().condition,
                       .onDaysOfWeek([]))
    }
}
