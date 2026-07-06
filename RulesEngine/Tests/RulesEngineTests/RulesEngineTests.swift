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

private func ctx(_ d: Date, unblocked: TimeInterval = 0) -> RuleContext {
    RuleContext(now: d, calendar: utc, unblockedTimeToday: unblocked)
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
        let d = date(2026, 7, 6, 10) // some concrete day
        let raw = utc.component(.weekday, from: d)
        let today = Weekday(rawValue: raw)!
        let notToday = Set(Weekday.allCases).subtracting([today])

        XCTAssertTrue(Condition.onDaysOfWeek([today]).evaluate(in: ctx(d)))
        XCTAssertFalse(Condition.onDaysOfWeek(notToday).evaluate(in: ctx(d)))
    }

    func testAfterUnblockedTime() {
        let c = Condition.afterUnblockedTime(30 * 60) // 30 minutes
        XCTAssertFalse(c.evaluate(in: ctx(date(2026, 7, 6, 10), unblocked: 20 * 60)))
        XCTAssertTrue(c.evaluate(in: ctx(date(2026, 7, 6, 10), unblocked: 30 * 60)))
        XCTAssertTrue(c.evaluate(in: ctx(date(2026, 7, 6, 10), unblocked: 45 * 60)))
    }

    func testCombinators() {
        let morning = Condition.duringTimeOfDay(TimeWindow(startHour: 6, endHour: 12))
        let overBudget = Condition.afterUnblockedTime(30 * 60)

        // "block in the morning, OR once I've blown my budget"
        let anyOf = Condition.anyOf([morning, overBudget])
        XCTAssertTrue(anyOf.evaluate(in: ctx(date(2026, 7, 6, 8))))                 // morning
        XCTAssertTrue(anyOf.evaluate(in: ctx(date(2026, 7, 6, 20), unblocked: 3600))) // budget
        XCTAssertFalse(anyOf.evaluate(in: ctx(date(2026, 7, 6, 20), unblocked: 60)))

        // "block in the afternoon only when NOT over budget" — exercises allOf + not
        let allOf = Condition.allOf([
            .duringTimeOfDay(TimeWindow(startHour: 12, endHour: 18)),
            .not(overBudget),
        ])
        XCTAssertTrue(allOf.evaluate(in: ctx(date(2026, 7, 6, 14), unblocked: 60)))
        XCTAssertFalse(allOf.evaluate(in: ctx(date(2026, 7, 6, 14), unblocked: 3600)))
        XCTAssertFalse(allOf.evaluate(in: ctx(date(2026, 7, 6, 9), unblocked: 60)))
    }
}

final class BlockEngineTests: XCTestCase {
    private func sampleRules() -> [Rule] {
        [
            Rule(name: "Socials during work",
                 targets: ["twitter.com", "reddit.com"],
                 condition: .allOf([
                     .onDaysOfWeek([.monday, .tuesday, .wednesday, .thursday, .friday]),
                     .duringTimeOfDay(TimeWindow(startHour: 9, endHour: 17)),
                 ])),
            Rule(name: "Video budget",
                 targets: ["youtube.com"],
                 condition: .afterUnblockedTime(30 * 60)),
            Rule(name: "Disabled rule",
                 isEnabled: false,
                 targets: ["example.com"],
                 condition: .always),
        ]
    }

    func testBlockedPatternsRespectsConditionsAndEnabled() {
        let engine = BlockEngine(rules: sampleRules())

        // Monday 10:00, under budget → socials blocked, youtube allowed, disabled rule inert.
        let monday10 = ctx(date(2026, 7, 6, 10), unblocked: 0)
        XCTAssertEqual(engine.blockedPatterns(in: monday10), ["twitter.com", "reddit.com"])

        // Same time but over the video budget → youtube joins the blocklist.
        let overBudget = ctx(date(2026, 7, 6, 10), unblocked: 40 * 60)
        XCTAssertEqual(engine.blockedPatterns(in: overBudget),
                       ["twitter.com", "reddit.com", "youtube.com"])

        // Evening → nothing blocked (disabled rule stays inert even though it's `.always`).
        let evening = ctx(date(2026, 7, 6, 21), unblocked: 0)
        XCTAssertTrue(engine.blockedPatterns(in: evening).isEmpty)
    }

    func testDecisionExplainsWhy() {
        let engine = BlockEngine(rules: sampleRules())
        let monday10 = ctx(date(2026, 7, 6, 10))

        let d = engine.decision(forHostname: "www.reddit.com", in: monday10)
        guard case let .blocked(_, ruleName, matched) = d.outcome else {
            return XCTFail("expected reddit to be blocked")
        }
        XCTAssertEqual(ruleName, "Socials during work")
        XCTAssertEqual(matched, "reddit.com")

        XCTAssertFalse(engine.decision(forHostname: "youtube.com", in: monday10).isBlocked)
    }
}

final class DailyUsageTests: XCTestCase {
    func testBucketsByLocalDay() {
        var usage = DailyUsage(calendar: utc)
        usage.record(10 * 60, at: date(2026, 7, 6, 9))
        usage.record(5 * 60, at: date(2026, 7, 6, 14))
        usage.record(20 * 60, at: date(2026, 7, 7, 9))

        XCTAssertEqual(usage.unblockedTime(on: date(2026, 7, 6, 23)), 15 * 60)
        XCTAssertEqual(usage.unblockedTime(on: date(2026, 7, 7, 1)), 20 * 60)
        XCTAssertEqual(usage.unblockedTime(on: date(2026, 7, 8)), 0)
    }
}

final class CodableTests: XCTestCase {
    func testPolicySnapshotRoundTrips() throws {
        let snapshot = PolicySnapshot(
            rules: [
                Rule(name: "Nested",
                     targets: ["news.ycombinator.com"],
                     condition: .anyOf([
                         .not(.always),
                         .duringDateRange(DateRange(start: date(2026, 1, 1), end: date(2026, 12, 31))),
                         .afterUnblockedTime(600),
                     ])),
            ],
            unblockedTimeToday: 123)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PolicySnapshot.self, from: data)
        XCTAssertEqual(decoded.rules, snapshot.rules)
        XCTAssertEqual(decoded.unblockedTimeToday, 123)
    }
}
