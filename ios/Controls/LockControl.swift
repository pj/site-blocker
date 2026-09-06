import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center control (iOS 18+): a toggle whose state reflects whether your sites are currently
/// open — either you've unlocked the time-limited lists, or a no-limit list's window is open (the
/// macOS "open access" state). Flipping it unlocks/locks directly in the control's background process
/// (no Face ID, no app launch). Locking during an open no-limit window has no effect — those sites
/// are scheduled open — so the toggle stays on, mirroring the Mac.
@available(iOS 18.0, *)
struct LockControl: ControlWidget {
    static let kind = "com.pauljohnson.siteblocker.ios.LockControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { open in
            ControlWidgetToggle("SiteBlocker", isOn: open, action: SetUnlockedIntent()) { isOn in
                Label(isOn ? "Unlocked" : "Locked",
                      systemImage: isOn ? "lock.open.fill" : "lock.fill")
            }
            .tint(.green)
        }
        .displayName("SiteBlocker")
        .description("Unlock or lock your restricted sites.")
    }

    /// `true` == open now (unlocked, or a no-limit window is open). Read live from the shared state.
    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }
        func currentValue() async throws -> Bool { MobileEnforcer.accessOpenNow() }
    }
}

/// Flips the unlock state. `value` is the desired on-state (unlocked). No authentication — runs in
/// the background from the control.
@available(iOS 18.0, *)
struct SetUnlockedIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set SiteBlocker Unlock"

    @Parameter(title: "Unlocked")
    var value: Bool

    func perform() async throws -> some IntentResult {
        MobileEnforcer.setUnlocked(value)
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
