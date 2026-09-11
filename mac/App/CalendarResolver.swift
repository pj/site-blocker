import Foundation
import EventKit
import RulesEngine

/// Resolves calendar-based exceptions: which of the configured calendars have an event active right
/// now. Holidays live in a subscribed all-day calendar (e.g. "US Holidays"), so "active" for those
/// means simply that today is a holiday. Kept in the app layer — the engine stays EventKit-free.
@MainActor
final class CalendarResolver {
    private let store = EKEventStore()
    private(set) var authorized: Bool

    init() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Prompt for full calendar access if not already granted. Safe to call repeatedly.
    func requestAccess() async {
        if authorized { return }
        authorized = (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Event calendars the user can pick from, sorted by title.
    func availableCalendars() -> [CalendarSource] {
        guard authorized else { return [] }
        return store.calendars(for: .event)
            .map { CalendarSource(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The subset of `ids` whose calendar has an event overlapping `now`. An all-day holiday event
    /// spans the whole day, so its calendar reads active all day.
    func activeCalendarIDs(among ids: Set<String>, now: Date = Date()) -> Set<String> {
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
