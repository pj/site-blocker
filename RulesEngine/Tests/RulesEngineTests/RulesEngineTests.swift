import XCTest
@testable import RulesEngine

/// A gregorian calendar pinned to UTC so time-of-day / weekday / date assertions are stable
/// regardless of where the tests run.
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
    c.timeZone = TimeZone(identifier: "UTC")!
    return Calendar(identifier: .gregorian).date(from: c)!
}

private func ctx(_ d: Date, used: TimeInterval = 0) -> RuleContext {
    RuleContext(now: d, calendar: utc, unblockedTimeToday: used)
}

final class HostPatternTests: XCTestCase {
    func testMatchesExactAndSubdomains() {
        let p = HostPattern("youtube.com")
        XCTAssertTrue(p.matches(hostname: "youtube.com"))
        XCTAssertTrue(p.matches(hostname: "www.youtube.com"))
        XCTAssertTrue(p.matches(hostname: "m.youtube.com"))
        XCTAssertFalse(p.matches(hostname: "notyoutube.com"))
        XCTAssertFalse(p.matches(hostname: "youtube.com.evil.com"))
    }

    func testNormalizesPastedURLsAndWWW() {
        XCTAssertEqual(HostPattern("https://www.Reddit.com/r/all").domain, "reddit.com")
        XCTAssertEqual(HostPattern("HTTP://News.YCombinator.com:443").domain, "news.ycombinator.com")
        XCTAssertEqual(HostPattern("  twitter.com.  ").domain, "twitter.com")
    }
}

final class TimeWindowTests: XCTestCase {
    func testDaytimeWindow() {
        let w = TimeWindow(startHour: 9, endHour: 17)
        XCTAssertFalse(w.contains(date(2026, 7, 6, 8, 59), calendar: utc))
        XCTAssertTrue(w.contains(date(2026, 7, 6, 9, 0), calendar: utc))
        XCTAssertTrue(w.contains(date(2026, 7, 6, 16, 59), calendar: utc))
        XCTAssertFalse(w.contains(date(2026, 7, 6, 17, 0), calendar: utc)) // end-exclusive
    }

    func testWrapAroundWindow() {
        let w = TimeWindow(startHour: 22, endHour: 6) // 22:00 → 06:00
        XCTAssertTrue(w.contains(date(2026, 7, 6, 23, 30), calendar: utc))
        XCTAssertTrue(w.contains(date(2026, 7, 6, 2, 0), calendar: utc))
        XCTAssertFalse(w.contains(date(2026, 7, 6, 12, 0), calendar: utc))
        XCTAssertFalse(w.contains(date(2026, 7, 6, 6, 0), calendar: utc))
    }
}

final class ConditionTests: XCTestCase {
    func testDaysOfWeek() {
        let d = date(2026, 7, 6, 10) // a Monday
        let raw = utc.component(.weekday, from: d)
        let today = Weekday(rawValue: raw)!
        let notToday = Set(Weekday.allCases).subtracting([today])

        XCTAssertTrue(Condition.onDaysOfWeek([today]).evaluate(in: ctx(d)))
        XCTAssertFalse(Condition.onDaysOfWeek(notToday).evaluate(in: ctx(d)))
    }

    func testAllOfWindow() {
        let window = Condition.allOf([
            .onDaysOfWeek([.monday]),
            .duringTimeOfDay(TimeWindow(startHour: 9, endHour: 17)),
        ])
        XCTAssertTrue(window.evaluate(in: ctx(date(2026, 7, 6, 10))))   // Monday 10:00
        XCTAssertFalse(window.evaluate(in: ctx(date(2026, 7, 6, 20))))  // Monday 20:00
        XCTAssertFalse(window.evaluate(in: ctx(date(2026, 7, 7, 10))))  // Tuesday 10:00
    }

    /// Legacy conditions carried the daily budget as an `afterUnblockedTime` atom; migration
    /// splits it out into `Rule.dailyLimit`, leaving only the day/time window.
    func testSplittingDailyLimit() {
        let legacy = Condition.allOf([
            .onDaysOfWeek([.monday]),
            .duringTimeOfDay(TimeWindow(startHour: 9, endHour: 17)),
            .afterUnblockedTime(1800),
        ])
        let (window, limit) = legacy.splittingDailyLimit()
        XCTAssertEqual(limit, 1800)
        XCTAssertEqual(window, .allOf([
            .onDaysOfWeek([.monday]),
            .duringTimeOfDay(TimeWindow(startHour: 9, endHour: 17)),
        ]))

        // A bare quota condition becomes "always" + the limit.
        let (w2, l2) = Condition.afterUnblockedTime(600).splittingDailyLimit()
        XCTAssertEqual(w2, .always)
        XCTAssertEqual(l2, 600)
    }
}

final class BlockEngineTests: XCTestCase {
    private let socials = Rule(name: "Socials — weekday daytime",
                               targets: ["twitter.com", "reddit.com"],
                               condition: .allOf([
                                   .onDaysOfWeek([.monday, .tuesday, .wednesday, .thursday, .friday]),
                                   .duringTimeOfDay(TimeWindow(startHour: 9, endHour: 17)),
                               ]),
                               dailyLimit: 30 * 60)
    private let video = Rule(name: "Video — anytime, 20 min",
                             targets: ["youtube.com"],
                             condition: .always,
                             dailyLimit: 20 * 60)
    private let disabled = Rule(name: "Disabled", isEnabled: false,
                                targets: ["example.com"], condition: .always)

    private func engine() -> BlockEngine { BlockEngine(rules: [socials, video, disabled]) }

    func testLockedBlocksEveryGovernedSite() {
        // Locked: every enabled rule's sites are blocked; the disabled rule contributes nothing.
        let blocked = engine().blockedPatterns(unlocked: false, in: ctx(date(2026, 7, 6, 10)))
        XCTAssertEqual(blocked, ["twitter.com", "reddit.com", "youtube.com"])
    }

    func testUnlockedInsideWindowAllowsThoseSites() {
        // Monday 10:00, pool empty → both rules eligible → nothing blocked.
        let blocked = engine().blockedPatterns(unlocked: true, in: ctx(date(2026, 7, 6, 10)))
        XCTAssertTrue(blocked.isEmpty)
    }

    func testSharedPoolReblocksRulesPastTheirOwnLimit() {
        // Shared pool at 20 min: video (20m limit) re-blocks; socials (30m) still allowed.
        let blocked = engine().blockedPatterns(unlocked: true,
                                               in: ctx(date(2026, 7, 6, 10), used: 20 * 60))
        XCTAssertEqual(blocked, ["youtube.com"])
    }

    func testSharedPoolPastLargestLimitBlocksEverything() {
        // At 30 min the pool reaches the largest limit → all governed sites re-block.
        let blocked = engine().blockedPatterns(unlocked: true,
                                               in: ctx(date(2026, 7, 6, 10), used: 30 * 60))
        XCTAssertEqual(blocked, ["twitter.com", "reddit.com", "youtube.com"])
    }

    func testUnlockedOutsideWindowBlocksThatRule() {
        // Monday 21:00: socials window closed (ineligible); video always eligible.
        let blocked = engine().blockedPatterns(unlocked: true, in: ctx(date(2026, 7, 6, 21)))
        XCTAssertEqual(blocked, ["twitter.com", "reddit.com"])
    }

    func testEligibleRules() {
        let sat = engine().eligibleRules(in: ctx(date(2026, 7, 11, 10))) // Saturday
        XCTAssertEqual(sat.map(\.name), ["Video — anytime, 20 min"])     // socials off on weekend
    }
}

final class DailyUsageTests: XCTestCase {
    func testSharedTotalPerLocalDay() {
        var usage = DailyUsage(calendar: utc)
        usage.record(10 * 60, at: date(2026, 7, 6, 9))
        usage.record(5 * 60, at: date(2026, 7, 6, 14))
        usage.record(20 * 60, at: date(2026, 7, 6, 9))
        usage.record(3 * 60, at: date(2026, 7, 7, 9))

        XCTAssertEqual(usage.total(on: date(2026, 7, 6, 23)), 35 * 60)  // all of the 6th
        XCTAssertEqual(usage.total(on: date(2026, 7, 7, 1)), 3 * 60)    // separate day
        XCTAssertEqual(usage.total(on: date(2026, 7, 8)), 0)            // untouched day
    }

    func testMergeTakingMaxNeverGivesBackTime() {
        var local = DailyUsage(calendar: utc)
        local.record(20 * 60, at: date(2026, 7, 6, 9))            // spent 20m here
        var remote = DailyUsage(calendar: utc)
        remote.record(25 * 60, at: date(2026, 7, 6, 9))           // more spent on another device
        remote.record(15 * 60, at: date(2026, 7, 7, 9))           // and time on a different day

        local.mergeTakingMax(remote)
        XCTAssertEqual(local.total(on: date(2026, 7, 6, 12)), 25 * 60)  // kept the larger
        XCTAssertEqual(local.total(on: date(2026, 7, 7, 12)), 15 * 60)  // gained the other day
    }
}

final class CodableTests: XCTestCase {
    func testPolicySnapshotRoundTrips() throws {
        let snapshot = PolicySnapshot(blockedPatterns: ["x.com", "twitter.com"])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PolicySnapshot.self, from: data)
        XCTAssertEqual(Set(decoded.blockedPatterns), ["x.com", "twitter.com"])
        XCTAssertTrue(decoded.isBlocked(hostname: "www.x.com"))
        XCTAssertFalse(decoded.isBlocked(hostname: "youtube.com"))
    }

    /// A rule persisted in the old "quota-in-condition, no dailyLimit" shape decodes into the new
    /// window + `dailyLimit` split.
    func testRuleMigratesLegacyQuota() throws {
        let legacyCondition = Condition.allOf([.onDaysOfWeek([.monday]), .afterUnblockedTime(1800)])
        let condJSON = String(decoding: try JSONEncoder().encode(legacyCondition), as: UTF8.self)
        let ruleJSON = """
        {"id":"\(UUID().uuidString)","name":"Legacy","isEnabled":true,\
        "targets":[{"domain":"x.com"}],"condition":\(condJSON)}
        """
        let rule = try JSONDecoder().decode(Rule.self, from: Data(ruleJSON.utf8))
        XCTAssertEqual(rule.dailyLimit, 1800)
        XCTAssertEqual(rule.condition, .onDaysOfWeek([.monday]))
        XCTAssertEqual(rule.targets, ["x.com"])
    }
}
