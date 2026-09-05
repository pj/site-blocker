import AppIntents

/// Shortcuts / Siri actions for iOS. They drive the shared `MobileStore`, so they stay in sync with
/// the app UI. Blocking follows each list's schedule; the one manual override is the Face-ID lock.
/// Locking needs no authentication (it only makes things stricter), so it works headless; unlocking
/// requires Face ID and therefore lives in the app UI, not a background Shortcut.

struct LockNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Now"
    static let description = IntentDescription("Re-locks your restricted sites immediately.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MobileStore.shared.lock()
        return .result(dialog: "Locked.")
    }
}

struct UnlockedStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Are Restricted Sites Unlocked"
    static let description = IntentDescription("Returns whether the Face-ID-gated lists are currently unlocked.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: MobileStore.shared.isUnlocked)
    }
}

struct SiteBlockerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LockNowIntent(),
                    phrases: ["Lock \(.applicationName)",
                              "Re-lock \(.applicationName)"],
                    shortTitle: "Lock Now", systemImageName: "lock.fill")
    }
}
