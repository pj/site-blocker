import XCTest
@testable import RulesEngine

/// Resolution tests for the `SiteList` / `ListEngine` model: a per-list base state with exceptions
/// that flip it (first active exception wins).
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
    private func exception(_ condition: Condition = .always, limit: TimeInterval? = nil) -> ListRule {
        ListRule(condition: condition, dailyLimit: limit)
    }
    private let mon = Weekday.monday, sat = Weekday.saturday, sun = Weekday.sunday

    private func list(_ targets: [HostPattern], blockedByDefault: Bool = true,
                      rules: [ListRule] = []) -> SiteList {
        SiteList(name: "L", targets: targets, isBlockedByDefault: blockedByDefault, rules: rules)
    }
    private func decide(_ l: SiteList, unlocked: Bool = false, used: TimeInterval = 0,
                        at d: Date) -> SiteList.Decision {
        ListEngine(lists: [l]).decision(for: l, unlocked: unlocked, in: ctx(d, used: used))
    }

    func testBaseStateWithNoExceptions() {
        XCTAssertEqual(decide(list(["x.com"], blockedByDefault: true), at: at(2026, 7, 6)), .blocked)
        XCTAssertEqual(decide(list(["x.com"], blockedByDefault: false), at: at(2026, 7, 6)), .allowed)
    }

    func testAllowWindowOpensBlockedList() {
        // Blocked by default, opened on Saturdays.
        let l = list(["x.com"], blockedByDefault: true, rules: [exception(.onDaysOfWeek([sat]))])
        XCTAssertEqual(decide(l, at: at(2026, 7, 6)), .blocked)    // Monday → base
        XCTAssertEqual(decide(l, at: at(2026, 7, 11)), .allowed)   // Saturday → allow window
    }

    func testBlockWindowClosesAllowedList() {
        // Allowed by default, blocked on Mondays.
        let l = list(["x.com"], blockedByDefault: false, rules: [exception(.onDaysOfWeek([mon]))])
        XCTAssertEqual(decide(l, at: at(2026, 7, 6)), .blocked)    // Monday → block window
        XCTAssertEqual(decide(l, at: at(2026, 7, 11)), .allowed)   // Saturday → base
    }

    func testFirstActiveExceptionWins() {
        // Two overlapping windows on Monday; the first decides — but both flip a blocked list to
        // allowed, so the meaningful check is that ordering picks the first one (asserted via limit).
        let l = list(["x.com"], blockedByDefault: true,
                     rules: [exception(.onDaysOfWeek([mon])), exception(.onDaysOfWeek([mon]), limit: 60)])
        XCTAssertEqual(ListEngine().activeRule(for: l, in: ctx(at(2026, 7, 6)))?.id, l.rules[0].id)
        XCTAssertEqual(decide(l, at: at(2026, 7, 6)), .allowed)    // first window is unlimited → open
    }

    func testLimitedAllowWindowGatesOnUnlockAndBudget() {
        let l = list(["x.com"], blockedByDefault: true,
                     rules: [exception(.onDaysOfWeek([mon]), limit: 1800)])  // 30 min
        XCTAssertEqual(decide(l, at: at(2026, 7, 6)), .blocked)                        // locked
        XCTAssertEqual(decide(l, unlocked: true, used: 600, at: at(2026, 7, 6)), .allowed)  // budget left
        XCTAssertEqual(decide(l, unlocked: true, used: 1800, at: at(2026, 7, 6)), .blocked) // spent
    }

    func testBlockedPatternsUnionAndHelpers() {
        let a = list(["a.com"], blockedByDefault: true)                                   // blocked
        let b = list(["b.com"], blockedByDefault: false)                                  // allowed
        let c = list(["c.com"], blockedByDefault: true,
                     rules: [exception(.always, limit: 1800)])                            // limited: locked → blocked
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
        // Blocked by default with a single limited allow-window on its old schedule.
        XCTAssertTrue(migrated.isBlockedByDefault)
        XCTAssertEqual(migrated.rules.count, 1)
        XCTAssertEqual(migrated.rules[0].condition, .onDaysOfWeek([mon]))
        XCTAssertEqual(migrated.rules[0].dailyLimit, 1800)
        // Same behavior as the old allow-rule: locked → blocked, unlocked+budget → allowed.
        XCTAssertEqual(decide(migrated, at: at(2026, 7, 6)), .blocked)
        XCTAssertEqual(decide(migrated, unlocked: true, at: at(2026, 7, 6)), .allowed)
    }
}
