import XCTest
@testable import RulesEngine

/// Round-trip tests for the v2 (site-lists) sync format, plus v1 back-compat.
final class SyncedConfigV2Tests: XCTestCase {

    private func decode(_ json: String) throws -> SyncedConfig {
        try JSONDecoder().decode(SyncedConfig.self, from: Data(json.utf8))
    }

    func testDecodesV2ListWithBaseStateAndExceptions() throws {
        let json = """
        {"version":2,"updatedAt":"now","lists":[
          {"name":"Social","enabled":true,"blockedByDefault":true,"domains":["x.com","reddit.com"],
           "rules":[
             {"days":["sat","sun"]},
             {"window":{"start":"12:00","end":"13:00"},"dailyLimitMinutes":30}
           ]}
        ]}
        """
        let lists = try decode(json).toSiteLists()
        XCTAssertEqual(lists.count, 1)
        let list = lists[0]
        XCTAssertEqual(list.name, "Social")
        XCTAssertTrue(list.isBlockedByDefault)
        XCTAssertEqual(Set(list.targets.map(\.domain)), ["x.com", "reddit.com"])
        XCTAssertEqual(list.rules.count, 2)
        XCTAssertEqual(list.rules[0].condition, .onDaysOfWeek([.saturday, .sunday]))
        XCTAssertEqual(list.rules[1].dailyLimit, 30 * 60)
        if case .manual = list.source {} else { XCTFail("expected manual source") }
    }

    func testDecodesAllowedByDefaultList() throws {
        let json = """
        {"version":2,"updatedAt":"now","lists":[
          {"name":"News","enabled":true,"blockedByDefault":false,"domains":["news.example"],
           "rules":[{"days":["mon","tue","wed","thu","fri"],"window":{"start":"09:00","end":"17:00"}}]}
        ]}
        """
        let list = try decode(json).toSiteLists()[0]
        XCTAssertFalse(list.isBlockedByDefault)
        XCTAssertEqual(list.rules.count, 1)   // a block-window exception
    }

    func testMissingBlockedByDefaultDecodesAsBlocked() throws {
        let json = """
        {"version":2,"updatedAt":"now","lists":[
          {"name":"Social","enabled":true,"domains":["x.com"],"rules":[]}
        ]}
        """
        XCTAssertTrue(try decode(json).toSiteLists()[0].isBlockedByDefault)
    }

    func testV2RemoteBlocklistBecomesRemoteSource() throws {
        let json = """
        {"version":2,"updatedAt":"now","lists":[
          {"name":"Ads","enabled":true,"blockedByDefault":true,"domains":[],
           "blocklistUrl":"https://example.com/list.txt","rules":[]}
        ]}
        """
        let list = try decode(json).toSiteLists()[0]
        if case .remote(let url) = list.source {
            XCTAssertEqual(url.absoluteString, "https://example.com/list.txt")
        } else { XCTFail("expected remote source") }
        XCTAssertTrue(list.targets.isEmpty)
        XCTAssertTrue(list.rules.isEmpty)   // no exceptions → always blocked
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
        // v1 → blocked-by-default with one allow-window exception carrying the limit.
        XCTAssertTrue(lists[0].isBlockedByDefault)
        XCTAssertEqual(lists[0].rules.count, 1)
        XCTAssertEqual(lists[0].rules[0].dailyLimit, 20 * 60)
    }

    /// End-to-end: a v2 config JSON → decode → toSiteLists → ListEngine → the blocked set, the exact
    /// pipeline both apps run. Social is blocked by default but opens Sat/Sun and (unlocked) at lunch;
    /// Ads is always blocked.
    func testConfigToBlockedPatternsPipeline() throws {
        let json = """
        {"version":2,"updatedAt":"now","lists":[
          {"name":"Social","enabled":true,"blockedByDefault":true,"domains":["x.com","reddit.com"],
           "rules":[
             {"days":["sat","sun"]},
             {"window":{"start":"12:00","end":"13:00"},"dailyLimitMinutes":30}
           ]},
          {"name":"Ads","enabled":true,"blockedByDefault":true,"domains":["ads.example"],"rules":[]}
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
        // Mon 09:00 → Social blocked (base), Ads always blocked.
        XCTAssertEqual(blocked(at(6, 9)), ["x.com", "reddit.com", "ads.example"])
        // Sat 15:00 → Social opens (weekend exception); Ads still blocked.
        XCTAssertEqual(blocked(at(11, 15)), ["ads.example"])
        // Mon lunch, unlocked with budget → Social opens (limited exception); Ads blocked.
        XCTAssertEqual(blocked(at(6, 12), unlocked: true), ["ads.example"])
        // Mon lunch, locked → Social blocked (limited exception needs unlock).
        XCTAssertEqual(blocked(at(6, 12)), ["x.com", "reddit.com", "ads.example"])
    }

    func testExceptionWithNoDaysIsAlways_AndPresentEmptyIsNever() {
        // nil days → .always
        XCTAssertEqual(SyncedConfig.SyncedListRule().toListRule().condition, .always)
        // present-but-empty days → never
        XCTAssertEqual(SyncedConfig.SyncedListRule(days: []).toListRule().condition,
                       .onDaysOfWeek([]))
    }
}
