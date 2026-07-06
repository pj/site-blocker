import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey via Carbon's `RegisterEventHotKey`. Works while the app is in the background
/// and inside the app sandbox without any Accessibility permission. The trigger runs on the main
/// thread. Keep a strong reference alive for the hotkey's lifetime.
final class GlobalHotKey {
    /// Human-readable form of the default toggle combo, for display in the UI.
    static let defaultDisplayString = "⌃⌥⌘B"

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onTrigger: () -> Void

    /// ⌃⌥⌘B — the blocking on/off toggle.
    static func blockingToggle(onTrigger: @escaping () -> Void) -> GlobalHotKey {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_B),
                     modifiers: UInt32(controlKey | optionKey | cmdKey),
                     onTrigger: onTrigger)
    }

    init(keyCode: UInt32, modifiers: UInt32, onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            if let userData {
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onTrigger()
            }
            return noErr
        }, 1, &spec, context, &eventHandler)

        let id = EventHotKeyID(signature: 0x53424C4B, id: 1) // 'SBLK'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
