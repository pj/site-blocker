import AppIntents

/// Shortcuts / Siri actions for controlling site blocking on iOS. They drive the shared
/// `MobileStore`, so they stay in sync with the app UI. "Blocking on" == not paused.

struct StartBlockingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Blocking"
    static let description = IntentDescription("Blocks your selected websites in Safari.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileStore.shared.resume()
        return .result(dialog: "Blocking is on.")
    }
}

struct StopBlockingIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Blocking"
    static let description = IntentDescription("Temporarily unblocks your websites.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let paused = MobileStore.shared.pause()
        return .result(dialog: paused
                       ? "Blocking is paused."
                       : "Blocking can't be paused right now — you're outside an allowed window.")
    }
}

struct BlockingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Blocking On"
    static let description = IntentDescription("Returns whether blocking is currently on.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: MobileStore.shared.isBlocking)
    }
}

struct SiteBlockerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartBlockingIntent(),
                    phrases: ["Start blocking with \(.applicationName)",
                              "Block distractions with \(.applicationName)"],
                    shortTitle: "Start Blocking", systemImageName: "lock.fill")
        AppShortcut(intent: StopBlockingIntent(),
                    phrases: ["Pause blocking with \(.applicationName)"],
                    shortTitle: "Pause Blocking", systemImageName: "lock.open.fill")
    }
}
