import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center control (iOS 18+): a one-tap **Unlock** button. It unlocks the time-limited
/// lists directly in the control's background process — no Face ID, no app launch — so it's an
/// instant "let me in" shortcut. (Locking still happens automatically when the budget is spent or
/// the window closes, and via the Lock button in the app.)
@available(iOS 18.0, *)
struct LockControl: ControlWidget {
    static let kind = "com.pauljohnson.siteblocker.ios.LockControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: UnlockIntent()) {
                Label("Unlock SiteBlocker", systemImage: "lock.open.fill")
            }
            .tint(.green)
        }
        .displayName("Unlock SiteBlocker")
        .description("Unlock your restricted sites.")
    }
}

/// Unlocks the time-limited lists with no authentication. Runs in the background from the control.
@available(iOS 18.0, *)
struct UnlockIntent: AppIntent {
    static let title: LocalizedStringResource = "Unlock SiteBlocker"

    func perform() async throws -> some IntentResult {
        MobileEnforcer.setUnlocked(true)
        MobileEnforcer.reevaluate()
        return .result()
    }
}

@available(iOS 18.0, *)
@main
struct SiteBlockerControlBundle: WidgetBundle {
    var body: some Widget {
        LockControl()
    }
}
