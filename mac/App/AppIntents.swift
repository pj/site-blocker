import AppIntents

/// Shortcuts / Siri actions for controlling the block. Starting the block is unguarded — the safe,
/// automatable direction (e.g. a "focus time" automation). Stopping it runs through the same
/// authentication barrier and eligibility check as the menu bar, so a shortcut can't bypass it.
///
/// Both reach the running app via `@Dependency` (registered in `AppDelegate`). The menu-bar app
/// launches to service the intent if it isn't already running.

struct StartBlockingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Blocking"
    static let description = IntentDescription("Immediately blocks your sites.")
    static let openAppWhenRun = false

    @Dependency private var store: RuleStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        store.lock()
        return .result(dialog: "Blocking is on.")
    }
}

struct StopBlockingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Blocking"
    static let description =
        IntentDescription("Unlocks your sites. Requires authentication and an active allowance.")
    static let openAppWhenRun = false

    @Dependency private var store: RuleStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard store.canUnlock else {
            return .result(dialog: "Nothing is allowed right now, so it can't be unlocked.")
        }
        await store.unlock()   // Touch ID + eligibility; no-ops if declined
        return .result(dialog: store.isUnlocked ? "Blocking is off." : "Unlock was cancelled.")
    }
}

/// Whether blocking is currently on — useful as a condition in automations.
struct BlockingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Blocking On"
    static let description = IntentDescription("Returns whether SiteBlocker is currently blocking.")
    static let openAppWhenRun = false

    @Dependency private var store: RuleStore

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: !store.isUnlocked)
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
