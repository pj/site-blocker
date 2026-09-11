import Foundation
import EventKit
import RulesEngine

/// Calendar-based exception resolution for iOS (mirrors the macOS `CalendarResolver`). The engine
/// stays EventKit-free; this answers "which of the configured calendars have an event active now",
/// which the store feeds into `RuleContext`. A shared store instance keeps queries cheap, including
/// from the background-refresh handler.
enum MobileCalendar {
    // EKEventStore isn't Sendable, but we only *read* from it (queries + auth), which is safe to do
    // across threads — including the background-refresh handler.
    nonisolated(unsafe) private static let store = EKEventStore()

    static var authorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    /// Prompt for calendar access (full access on iOS 17+, classic access on 16). Returns granted.
    @discardableResult
    static func requestAccess() async -> Bool {
        if authorized { return true }
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            return await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { granted, _ in cont.resume(returning: granted) }
            }
        }
    }

    static func availableCalendars() -> [CalendarSource] {
        guard authorized else { return [] }
        return store.calendars(for: .event)
            .map { CalendarSource(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The subset of `ids` whose calendar has an event overlapping `now` (all-day events span the day).
    static func activeCalendarIDs(among ids: Set<String>, now: Date = Date()) -> Set<String> {
        guard authorized, !ids.isEmpty else { return [] }
        let calendars = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(1),
                                                 calendars: calendars)
        var active: Set<String> = []
        for event in store.events(matching: predicate) {
            if let id = event.calendar?.calendarIdentifier { active.insert(id) }
        }
        return active
    }
}
