import XCTest
@testable import RulesEngine

/// Resolution tests for the redesigned `SiteList` / `ListEngine` (first active rule wins).
final class ListEngineTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    /// 2026-07-06 = Monday, 2026-07-11 = Saturday.
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h
        c.timeZone = TimeZone(identifier: "UTC")!
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    private func ctx(_ d: Date, used: TimeInterval = 0) -> RuleContext {
        RuleContext(now: d, calendar: utc, unblockedTimeToday: used)
    }
    private func allow(_ condition: Condition = .always, limit: TimeInterval? = nil) -> ListRule {
        ListRule(action: .allow, condition: condition, dailyLimit: limit)
    }
    private func deny(_ condition: Condition = .always) -> ListRule {
        ListRule(action: .deny, condition: condition)
    }
    private let mon = Weekday.monday, sat = Weekday.saturday, sun = Weekday.sunday

    private func list(_ targets: [HostPattern], rules: [ListRule] = []) -> SiteList {
        SiteList(name: "L", targets: targets, rules: rules)
    }
    private func decide(_ l: SiteList, unlocked: Bool = false, used: TimeInterval = 0,
                        at d: Date) -> SiteList.Decision {
        ListEngine(lists: [l]).decision(for: l, unlocked: unlocked, in: ctx(d, used: used))
    }

    func testFallbackIsAllowedAndCatchAllDenyBlocks() {
        // No rule matches → not blocked.
        XCTAssertEqual(decide(list(["x.com"]), at: at(2026, 7, 6)), .allowed)
        // A catch-all Deny (the auto-added default) → blocked.
        XCTAssertEqual(decide(list(["x.com"], rules: [deny(.always)]), at: at(2026, 7, 6)), .blocked)
    }

    func testFirstActiveRuleWins() {
        let l = list(["x.com"], rules: [allow(.onDaysOfWeek([mon])), deny(.onDaysOfWeek([mon]))])
        XCTAssertEqual(decide(l, at: at(2026, 7, 6)), .allowed)   // allow is first & active
    }

    func testDenyOnItsDays() {
        let l = list(["x.com"], rules: [deny(.onDaysOfWeek([mon]))])
        XCTAssertEqual(decide(l, at: at(2026, 7, 6)), .blocked)   // Monday → deny
        XCTAssertEqual(decide(l, at: at(2026, 7, 11)), .allowed)  // Saturday → no match → allowed
    }

    func testLimitedAllowGatesOnUnlockAndBudget() {
        let l = list(["x.com"], rules: [allow(.onDaysOfWeek([mon]), limit: 1800)])   // 30 min
        XCTAssertEqual(decide(l, at: at(2026, 7, 6)), .blocked)                        // locked
        XCTAssertEqual(decide(l, unlocked: true, used: 600, at: at(2026, 7, 6)), .allowed)  // budget left
        XCTAssertEqual(decide(l, unlocked: true, used: 1800, at: at(2026, 7, 6)), .blocked) // spent
    }

    func testBlockedPatternsUnionAndHelpers() {
        let a = list(["a.com"], rules: [deny(.always)])                         // blocked
        let b = list(["b.com"])                                                 // no rule → allowed
        let c = list(["c.com"], rules: [allow(.always, limit: 1800)])           // limited: locked → blocked
        let engine = ListEngine(lists: [a, b, c])
        let context = ctx(at(2026, 7, 6))
        XCTAssertEqual(engine.blockedPatterns(unlocked: false, in: context), ["a.com", "c.com"])
        XCTAssertTrue(engine.canUnlock(in: context))          // c would open when unlocked
        XCTAssertTrue(engine.openAccessActive(in: context))   // b is auto-open
        XCTAssertEqual(engine.blockedPatterns(unlocked: true, in: context), ["a.com"])  // c opens
    }

    func testMigratingFromRule() {
        let rule = Rule(name: "Old", targets: ["y.com"],
                        condition: .onDaysOfWeek([mon]), dailyLimit: 1800)
        let migrated = SiteList(migrating: rule)
        XCTAssertEqual(migrated.targets, ["y.com"])
        // The schedule Allow rule followed by a catch-all Deny.
        XCTAssertEqual(migrated.rules.count, 2)
        XCTAssertEqual(migrated.rules[0].action, .allow)
        XCTAssertEqual(migrated.rules[0].dailyLimit, 1800)
        XCTAssertEqual(migrated.rules[1].action, .deny)
        XCTAssertEqual(migrated.rules[1].condition, .always)
        // Same behavior as the old allow-rule: locked → blocked, unlocked+budget → allowed.
        XCTAssertEqual(decide(migrated, at: at(2026, 7, 6)), .blocked)
        XCTAssertEqual(decide(migrated, unlocked: true, at: at(2026, 7, 6)), .allowed)
    }
}
