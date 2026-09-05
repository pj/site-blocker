import UserNotifications

/// Thin wrapper over local notifications — the iOS analog of the macOS `Notifier`. The desktop posts
/// live banners as a viewing-time budget winds down; iOS has no budget, so these track the *schedule
/// window* instead ("allowed time left" / "allowed time available") and are **scheduled ahead** with
/// time triggers, so they fire even while the app is closed.
enum Notifier {
    /// Ask once (a system prompt the first time). Safe to call on every launch.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Replace every pending SiteBlocker notification with `requests` (the app owns them all, so a
    /// blanket clear is safe). Called whenever the schedule or app state changes.
    static func reschedule(_ requests: [UNNotificationRequest]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for request in requests { center.add(request) }
    }

    /// A one-shot notification fixed to fire at `date`. Returns nil when `date` is already past (so
    /// callers can build a list and drop the ones that no longer apply).
    static func request(id: String, body: String, at date: Date, sound: Bool = false)
        -> UNNotificationRequest? {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "SiteBlocker"
        content.body = body
        content.sound = sound ? .default : nil
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}
