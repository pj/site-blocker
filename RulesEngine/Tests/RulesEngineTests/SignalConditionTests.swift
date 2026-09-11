import XCTest
@testable import RulesEngine

/// Tests for the external-signal exception conditions (calendar / focus / location) and the
/// helpers that tell the apps which sources to resolve.
final class SignalConditionTests: XCTestCase {

    private let cal = CalendarSource(id: "US-Holidays", title: "US Holidays")
    private let focus = FocusSource(id: "focus-work", name: "Work")
    private let region = GeoRegion(id: "region-home", name: "Home",
                                   latitude: 37.33, longitude: -122.03, radius: 100)

    private func ctx(calendars: Set<String> = [], focuses: Set<String> = [],
                     regions: Set<String> = []) -> RuleContext {
        RuleContext(activeCalendarIDs: calendars, activeFocusIDs: focuses, insideRegionIDs: regions)
    }

    func testCalendarConditionMatchesActiveCalendar() {
        let c = Condition.duringCalendarEvent(cal)
        XCTAssertTrue(c.evaluate(in: ctx(calendars: ["US-Holidays"])))
        XCTAssertFalse(c.evaluate(in: ctx(calendars: ["Other"])))
        XCTAssertFalse(c.evaluate(in: ctx()))
    }

    func testFocusConditionMatchesActiveFocus() {
        let c = Condition.duringFocus(focus)
        XCTAssertTrue(c.evaluate(in: ctx(focuses: ["focus-work"])))
        XCTAssertFalse(c.evaluate(in: ctx(focuses: ["focus-sleep"])))
    }

    func testLocationConditionMatchesInsideRegion() {
        let c = Condition.atLocation(region)
        XCTAssertTrue(c.evaluate(in: ctx(regions: ["region-home"])))
        XCTAssertFalse(c.evaluate(in: ctx()))
    }

    func testComposesWithSchedule() {
        // Allow only when it's a holiday AND we're at home.
        let c = Condition.allOf([.duringCalendarEvent(cal), .atLocation(region)])
        XCTAssertTrue(c.evaluate(in: ctx(calendars: ["US-Holidays"], regions: ["region-home"])))
        XCTAssertFalse(c.evaluate(in: ctx(calendars: ["US-Holidays"])))          // not at home
        XCTAssertFalse(c.evaluate(in: ctx(regions: ["region-home"])))            // not a holiday
    }

    func testCollectSourcesWalksTree() {
        let c = Condition.anyOf([.duringFocus(focus),
                                 .allOf([.duringCalendarEvent(cal), .atLocation(region)])])
        let s = c.collectSources()
        XCTAssertEqual(s.calendars, [cal])
        XCTAssertEqual(s.focuses, [focus])
        XCTAssertEqual(s.regions, [region])
    }

    func testReferencedSourcesAcrossListsAreDeduped() {
        let lists = [
            SiteList(name: "A", rules: [ListRule(condition: .duringCalendarEvent(cal)),
                                        ListRule(condition: .duringFocus(focus))]),
            SiteList(name: "B", rules: [ListRule(condition: .duringCalendarEvent(cal)),   // dup
                                        ListRule(condition: .atLocation(region))]),
        ]
        XCTAssertEqual(lists.referencedCalendars, [cal])
        XCTAssertEqual(lists.referencedFocuses, [focus])
        XCTAssertEqual(lists.referencedRegions, [region])
    }

    func testCodableRoundTrip() throws {
        let original = Condition.allOf([.duringCalendarEvent(cal), .duringFocus(focus), .atLocation(region)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Condition.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
