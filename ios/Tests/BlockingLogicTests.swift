import XCTest
import RulesEngine
// MobileRule is compiled into this test target directly (see project.yml), so it's referenced
// without importing the app module.

/// Verifies the blocking logic the iOS app relies on: `MobileRule.asRule` → `BlockEngine`, which is
/// what `MobileEnforcer.blockedDomainsNow()` uses.
///
/// Model: a list with **no daily limit** opens automatically during its window (no Face ID); a list
/// **with a daily limit** is Face-ID-gated — blocked until unlocked, then open until the shared daily
/// budget of unlocked time is spent. Empty days = permanent block.
final class BlockingLogicTests: XCTestCase {

    /// 2026-07-06 is a Monday; `hour` lets tests probe inside/outside a time window.
    private func monday(_ hour: Int = 9, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 6; c.hour = hour; c.minute = minute
        c.timeZone = TimeZone(identifier: "UTC")!
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    /// Mirror of `MobileEnforcer.blockedDomainsNow()`: map lists to engine rules and ask what's
    /// blocked at `date` for the given unlock state and minutes of budget already spent today.
    private func blocked(_ rules: [MobileRule], unlocked: Bool,
                         usedMinutes: Double = 0, at date: Date) -> Set<String> {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let engine = BlockEngine(rules: rules.map(\.asRule))
        let ctx = RuleContext(now: date, calendar: cal, unblockedTimeToday: usedMinutes * 60)
        return Set(engine.blockedPatterns(unlocked: unlocked, in: ctx).map(\.domain))
    }

    private func list(_ name: String, _ domains: [String], enabled: Bool = true,
                      days: Set<Weekday> = MobileRule.everyDay, limitMinutes: Int? = nil) -> MobileRule {
        var r = MobileRule()
        r.name = name; r.isEnabled = enabled; r.siteDomains = domains
        r.days = days; r.dailyLimitMinutes = limitMinutes
        return r
    }

    // MARK: No rules / disabled rules block nothing

    func testNoRulesBlockNothing() {
        XCTAssertEqual(blocked([], unlocked: false, at: monday()), [])
    }

    func testDisabledRuleBlocksNothing() {
        let rules = [list("YT", ["youtube.com"], enabled: false, limitMinutes: 30)]
        XCTAssertEqual(blocked(rules, unlocked: false, at: monday()), [])
    }

    // MARK: No-limit lists auto-open during their window (option B — no Face ID)

    /// The reported fix: an enabled, in-window list *without* a limit is accessible with no unlock.
    func testNoLimitListAutoOpensDuringWindow() {
        let rules = [list("News", ["bbc.com"])]
        XCTAssertEqual(blocked(rules, unlocked: false, at: monday()), [])
    }

    /// …but is blocked outside its window.
    func testNoLimitListBlockedOutsideWindow() {
        let rules = [list("Weekend", ["bbc.com"], days: [.sunday])]   // today is Monday
        XCTAssertEqual(blocked(rules, unlocked: false, at: monday()), ["bbc.com"])
    }

    // MARK: Time-limited lists are Face-ID-gated and budget-bounded

    func testLimitedListBlockedWhenLockedAllowedWhenUnlocked() {
        let rules = [list("YT", ["youtube.com"], limitMinutes: 30)]
        XCTAssertEqual(blocked(rules, unlocked: false, at: monday()), ["youtube.com"])
        XCTAssertEqual(blocked(rules, unlocked: true, at: monday()), [])
    }

    /// Once the daily budget is spent, a limited list re-blocks even while unlocked.
    func testLimitedListReblocksWhenBudgetSpent() {
        let rules = [list("YT", ["youtube.com"], limitMinutes: 30)]
        XCTAssertEqual(blocked(rules, unlocked: true, usedMinutes: 10, at: monday()), [])
        XCTAssertEqual(blocked(rules, unlocked: true, usedMinutes: 30, at: monday()), ["youtube.com"])
    }

    func testLimitedListBlocksOnlyItsOwnDomains() {
        let rules = [list("YT", ["youtube.com", "reddit.com"], limitMinutes: 30)]
        let result = blocked(rules, unlocked: false, at: monday())
        XCTAssertEqual(result, ["youtube.com", "reddit.com"])
        XCTAssertFalse(result.contains("example.com"))
    }

    // MARK: Schedule edges

    func testNoDaysIsPermanentBlock() {
        let rules = [list("Perm", ["x.com"], days: [], limitMinutes: 30)]
        XCTAssertEqual(blocked(rules, unlocked: true, at: monday()), ["x.com"])
    }

    /// A limited list outside its time window stays blocked even when unlocked with budget to spare.
    func testTimeWindowGatesLimitedList() {
        var r = list("Evening", ["x.com"], limitMinutes: 60)
        r.timeEnabled = true
        r.window = TimeWindow(startHour: 18, endHour: 21)
        XCTAssertEqual(blocked([r], unlocked: true, at: monday(9)), ["x.com"])   // 09:00 — closed
        XCTAssertEqual(blocked([r], unlocked: true, at: monday(19)), [])         // 19:00 — open + unlocked
        XCTAssertEqual(blocked([r], unlocked: false, at: monday(19)), ["x.com"]) // 19:00 — open but locked
    }
}
