import XCTest
import RulesEngine
// MobileRule is compiled into this test target directly (see project.yml), so it's referenced
// without importing the app module.

/// Verifies the blocking logic the iOS app relies on: `MobileRule.asRule` → `BlockEngine`, which is
/// what `MobileEnforcer.blockedDomainsNow()` uses. Post-1.6 every list is unlock-gated, so an
/// enabled, in-window list blocks its sites until unlocked — these tests pin that down and prove a
/// list only ever blocks its *own* domains.
final class BlockingLogicTests: XCTestCase {

    /// 2026-07-06 is a Monday, 09:00 and 19:00 UTC used for window checks.
    private func monday(_ hour: Int = 9, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 6; c.hour = hour; c.minute = minute
        c.timeZone = TimeZone(identifier: "UTC")!
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    /// Mirror of `MobileEnforcer.blockedDomainsNow()`: map the lists to engine rules and ask the
    /// engine what's blocked at `date` for the given unlock state.
    private func blocked(_ rules: [MobileRule], unlocked: Bool, at date: Date) -> Set<String> {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let engine = BlockEngine(rules: rules.map(\.asRule))
        return Set(engine.blockedPatterns(unlocked: unlocked,
                                          in: RuleContext(now: date, calendar: cal)).map(\.domain))
    }

    /// A list allowed every day (window always open) unless overridden.
    private func list(_ name: String, _ domains: [String],
                      enabled: Bool = true, days: Set<Weekday> = MobileRule.everyDay) -> MobileRule {
        var r = MobileRule()
        r.name = name
        r.isEnabled = enabled
        r.siteDomains = domains
        r.days = days
        return r
    }

    // MARK: No rules / disabled rules block nothing (matches "disable all → sites available")

    func testNoRulesBlockNothing() {
        XCTAssertEqual(blocked([], unlocked: false, at: monday()), [])
    }

    func testDisabledRuleBlocksNothing() {
        let rules = [list("YT", ["youtube.com"], enabled: false)]
        XCTAssertEqual(blocked(rules, unlocked: false, at: monday()), [])
        XCTAssertEqual(blocked(rules, unlocked: true, at: monday()), [])
    }

    // MARK: One enabled, in-window list — the reported scenario

    /// Locked: an enabled, currently-valid list blocks its sites (you must unlock). This is the
    /// post-1.6 behavior the user is seeing.
    func testEnabledInWindowListBlocksWhenLocked() {
        let rules = [list("YT", ["youtube.com"])]
        XCTAssertEqual(blocked(rules, unlocked: false, at: monday()), ["youtube.com"])
    }

    /// Unlocked: the same list's sites become available.
    func testEnabledInWindowListAllowedWhenUnlocked() {
        let rules = [list("YT", ["youtube.com"])]
        XCTAssertEqual(blocked(rules, unlocked: true, at: monday()), [])
    }

    /// A list only ever blocks its *own* domains — enabling one list never blocks unrelated sites.
    func testListBlocksOnlyItsOwnDomains() {
        let rules = [list("YT", ["youtube.com", "reddit.com"])]
        let result = blocked(rules, unlocked: false, at: monday())
        XCTAssertEqual(result, ["youtube.com", "reddit.com"])
        XCTAssertFalse(result.contains("example.com"))
    }

    // MARK: Schedule edges

    /// No days selected is a permanent block — never openable, even unlocked.
    func testNoDaysIsPermanentBlock() {
        let rules = [list("Perm", ["x.com"], days: [])]
        XCTAssertEqual(blocked(rules, unlocked: false, at: monday()), ["x.com"])
        XCTAssertEqual(blocked(rules, unlocked: true, at: monday()), ["x.com"])
    }

    /// Outside the time window the sites stay blocked even when unlocked; inside, unlocking frees them.
    func testTimeWindowGatesUnlock() {
        var r = list("Evening", ["x.com"])
        r.timeEnabled = true
        r.window = TimeWindow(startHour: 18, endHour: 21)
        XCTAssertEqual(blocked([r], unlocked: true, at: monday(9)), ["x.com"])   // 09:00 — closed
        XCTAssertEqual(blocked([r], unlocked: true, at: monday(19)), [])         // 19:00 — open + unlocked
        XCTAssertEqual(blocked([r], unlocked: false, at: monday(19)), ["x.com"]) // 19:00 — open but locked
    }
}
