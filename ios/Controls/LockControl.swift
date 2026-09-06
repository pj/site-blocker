import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center control (iOS 18+): a toggle showing whether SiteBlocker's time-limited lists are
/// locked. Flipping it **on** (locking) is instant and happens in the control's background process;
/// flipping it **off** (unlocking) needs Face ID, which a control can't prompt — so it hands off to
/// the app, which runs the unlock on next foreground (see `MobileEnforcer.pendingUnlockRequest`).
@available(iOS 18.0, *)
struct LockControl: ControlWidget {
    static let kind = "com.pauljohnson.siteblocker.ios.LockControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { locked in
            ControlWidgetToggle("SiteBlocker", isOn: locked, action: SetLockedIntent()) { isOn in
                Label(isOn ? "Locked" : "Unlocked",
                      systemImage: isOn ? "lock.fill" : "lock.open.fill")
            }
            .tint(.red)
        }
        .displayName("SiteBlocker Lock")
        .description("Lock your restricted sites, or unlock them with Face ID.")
    }

    /// `true` == locked (SiteBlocker active). The control reads the shared unlock state.
    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }
        func currentValue() async throws -> Bool { !MobileEnforcer.isUnlocked }
    }
}

/// Drives the toggle. `value` is the desired on-state (locked). A control can't prompt Face ID and
/// conditional app-opening isn't available to app extensions, so this opens the app and applies the
/// change there: locking takes effect immediately; unlocking flags a request the app fulfils with
/// Face ID on foreground (see `MobileEnforcer.pendingUnlockRequest`).
@available(iOS 18.0, *)
struct SetLockedIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set SiteBlocker Lock"
    static let openAppWhenRun = true

    @Parameter(title: "Locked")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        if value {
            MobileEnforcer.setUnlocked(false)   // lock — no authentication needed
            MobileEnforcer.reevaluate()
        } else {
            MobileEnforcer.pendingUnlockRequest = true   // unlock needs Face ID — the app runs it
        }
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
