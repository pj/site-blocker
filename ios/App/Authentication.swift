import LocalAuthentication

enum Authentication {
    /// Prompt for the device owner: Face ID / Touch ID with automatic passcode fallback. Returns
    /// true only on a successful authentication; any failure/cancel/unavailable returns false (so
    /// blocking stays on — the safer default for a self-control barrier).
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: reason)) ?? false
    }
}
