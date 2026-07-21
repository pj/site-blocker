import UserNotifications

/// Thin wrapper over local notifications, used to warn as a rule's daily viewing budget winds down.
enum Notifier {
    /// Ask once (a system prompt the first time). Safe to call on every launch.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post an immediate banner. A stable `id` lets a later post replace an earlier one in place.
    static func notify(_ body: String, id: String, sound: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = "SiteBlocker"
        content.body = body
        content.sound = sound ? .default : nil
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
