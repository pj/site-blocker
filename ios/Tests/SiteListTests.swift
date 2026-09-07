import XCTest
import RulesEngine
// SiteList + ListRule are compiled into this test target (see project.yml).

/// Pins down the new first-active-rule-wins resolution for `SiteList`.
final class SiteListTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    /// 2026-07-06 = Monday, 2026-07-11 = Saturday.
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h
        c.timeZone = TimeZone(identifier: "UTC")!
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    private let mon = Weekday.monday, sat = Weekday.saturday, sun = Weekday.sunday

    private func decide(_ list: SiteList, unlocked: Bool = false, used: Double = 0,
                        on date: Date) -> SiteList.Decision {
        list.decision(now: date, calendar: utc, unlocked: unlocked, usedToday: used * 60)
    }

    private func rule(_ action: RuleAction, days: Set<Weekday> = Set(Weekday.allCases),
                      from: Int? = nil, to: Int? = nil, limit: Int? = nil) -> ListRule {
        var r = ListRule(); r.action = action; r.days = days; r.dailyLimitMinutes = limit
        if let from, let to { r.timeEnabled = true; r.window = TimeWindow(startHour: from, endHour: to) }
        return r
    }

    // MARK: Defaults

    func testDefaultBlockedWhenNoRuleMatches() {
        var list = SiteList(); list.domains = ["x.com"]; list.defaultAllowed = false
        XCTAssertEqual(decide(list, on: at(2026, 7, 6)), .blocked)
    }

    func testDefaultAllowedWhenNoRuleMatches() {
        var list = SiteList(); list.domains = ["x.com"]; list.defaultAllowed = true
        XCTAssertEqual(decide(list, on: at(2026, 7, 6)), .allowed)
    }

    // MARK: First active rule wins

    func testFirstActiveRuleWins_AllowBeforeDeny() {
        var list = SiteList(); list.domains = ["x.com"]
        list.rules = [rule(.allow, days: [mon]), rule(.deny, days: [mon])]
        XCTAssertEqual(decide(list, on: at(2026, 7, 6)), .allowed)   // allow is first & active
    }

    func testDenyBlocksOnItsDays() {
        var list = SiteList(); list.domains = ["x.com"]; list.defaultAllowed = true
        list.rules = [rule(.deny, days: [mon])]
        XCTAssertEqual(decide(list, on: at(2026, 7, 6)), .blocked)   // Monday
        XCTAssertEqual(decide(list, on: at(2026, 7, 11)), .allowed)  // Saturday → default allowed
    }

    func testDisabledRuleAndListIgnored() {
        var list = SiteList(); list.domains = ["x.com"]
        var r = rule(.deny, days: [mon]); r.isEnabled = false
        list.rules = [r]
        XCTAssertEqual(decide(list, on: at(2026, 7, 6)), .blocked)   // rule off → default blocked
        list.isEnabled = false
        XCTAssertEqual(decide(list, on: at(2026, 7, 6)), .allowed)   // list off → governs nothing
    }

    // MARK: Limited Allow rules gate on unlock + budget

    func testLimitedAllowNeedsUnlockAndBudget() {
        var list = SiteList(); list.domains = ["x.com"]
        list.rules = [rule(.allow, days: [mon], limit: 30)]
        XCTAssertEqual(decide(list, unlocked: false, on: at(2026, 7, 6)), .blocked)         // locked
        XCTAssertEqual(decide(list, unlocked: true, used: 10, on: at(2026, 7, 6)), .allowed) // budget left
        XCTAssertEqual(decide(list, unlocked: true, used: 30, on: at(2026, 7, 6)), .blocked) // spent
    }

    func testNoLimitAllowAutoOpens() {
        var list = SiteList(); list.domains = ["x.com"]
        list.rules = [rule(.allow, days: [mon])]
        XCTAssertEqual(decide(list, unlocked: false, on: at(2026, 7, 6)), .allowed)
    }

    // MARK: The worked example from the design

    func testWorkedExample() {
        // default Blocked; 1) Allow Sat/Sun, 2) Allow lunch 12–13 30m, 3) Deny Mon–Fri.
        var list = SiteList(); list.domains = ["social.com"]; list.defaultAllowed = false
        list.rules = [
            rule(.allow, days: [sat, sun]),
            rule(.allow, from: 12, to: 13, limit: 30),
            rule(.deny, days: [mon, .tuesday, .wednesday, .thursday, .friday]),
        ]
        XCTAssertEqual(decide(list, on: at(2026, 7, 11, 15)), .allowed)                 // Saturday afternoon
        XCTAssertEqual(decide(list, unlocked: true, used: 0, on: at(2026, 7, 6, 12)), .allowed) // Mon lunch, unlocked
        XCTAssertEqual(decide(list, on: at(2026, 7, 6, 12)), .blocked)                  // Mon lunch, locked
        XCTAssertEqual(decide(list, on: at(2026, 7, 6, 9)), .blocked)                   // Mon 09:00 → deny
    }

    // MARK: Aggregate blocked-domain set

    func testBlockedDomainsUnionsAcrossLists() {
        var a = SiteList(); a.domains = ["a.com"]; a.defaultAllowed = false   // blocked
        var b = SiteList(); b.domains = ["b.com"]; b.defaultAllowed = true    // allowed
        let blocked = Set(Blocking.blockedDomains([a, b], now: at(2026, 7, 6),
                                                  calendar: utc, unlocked: false, usedToday: 0))
        XCTAssertEqual(blocked, ["a.com"])
    }
}
