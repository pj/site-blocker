import AppIntents

/// Shortcuts / Siri actions for controlling the block on iOS. They drive the shared `MobileStore`,
/// so they stay in sync with the app UI. (When real per-rule scheduling + an unlock barrier land,
/// gate `StopBlockingIntent` the same way as the in-app control.)

struct StartBlockingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Blocking"
    static let description = IntentDescription("Blocks your selected apps and websites.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileStore.shared.lock()
        return .result(dialog: "Blocking is on.")
    }
}

struct StopBlockingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Blocking"
    static let description = IntentDescription("Unblocks your selected apps and websites.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileStore.shared.unlock()
        return .result(dialog: "Blocking is off.")
    }
}

struct BlockingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Blocking On"
    static let description = IntentDescription("Returns whether blocking is currently on.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: MobileStore.shared.isLocked)
    }
}

struct SiteBlockerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartBlockingIntent(),
                    phrases: ["Start blocking with \(.applicationName)",
                              "Block distractions with \(.applicationName)"],
                    shortTitle: "Start Blocking", systemImageName: "lock.fill")
        AppShortcut(intent: StopBlockingIntent(),
                    phrases: ["Stop blocking with \(.applicationName)"],
                    shortTitle: "Stop Blocking", systemImageName: "lock.open.fill")
    }
}
