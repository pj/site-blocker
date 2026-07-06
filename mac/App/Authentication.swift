import AppKit
import LocalAuthentication

enum Authentication {
    /// Prompt for the device owner: Touch ID with automatic password fallback. Returns true only on
    /// a successful authentication; any failure/cancel/unavailable returns false (so blocking stays
    /// on — the safer default for a self-control barrier).
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password…"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        let confirmed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                           localizedReason: reason)) ?? false
        // The system auth dialog takes focus, and when it dismisses macOS doesn't return focus to
        // an accessory app — any open window (the rules editor) would drop behind the frontmost
        // app. Reclaim activation so it stays visible.
        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
        return confirmed
    }
}
