import Foundation
import RulesEngine

#if ENABLE_NETWORK_EXTENSION
@preconcurrency import NetworkExtension
import SystemExtensions
#endif

/// Real enforcer backed by the content-filter system extension.
///
/// ⚠️ Mocked out for now. Everything that requires the NetworkExtension entitlement (system
/// extension activation + `NEFilterManager` configuration) is compiled behind
/// `ENABLE_NETWORK_EXTENSION`, which stays off until the Apple Developer account is provisioned
/// and the entitlements below are signed in. Until then `SiteBlockerApp` wires up `MockEnforcer`.
///
/// Design note: the content filter does not consume a flat blocklist. The extension evaluates
/// each flow itself against the shared `PolicySnapshot` (written by `RuleStore`). So `apply` here
/// is not "set these hosts" — it's "make sure the filter is installed and running"; the snapshot
/// on disk is what actually changes the behavior.
final class SystemExtensionEnforcer: NSObject, Enforcer {

    func apply(blockedPatterns: Set<HostPattern>) {
        #if ENABLE_NETWORK_EXTENSION
        ensureFilterEnabled()
        #endif
        // Snapshot freshness is handled by RuleStore.writeSnapshot; nothing else to do here.
    }

    #if ENABLE_NETWORK_EXTENSION
    private static let extensionBundleID = "com.pauljohnson.siteblocker.app.FilterExtension"

    /// Step 1: activate the system extension (prompts the user to approve in System Settings the
    /// first time). Step 2: enable the content filter configuration.
    func activateAndEnable() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func ensureFilterEnabled() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { _ in
            if manager.providerConfiguration == nil {
                let config = NEFilterProviderConfiguration()
                config.filterSockets = true
                config.filterPackets = false
                manager.providerConfiguration = config
                manager.localizedDescription = "SiteBlocker"
            }
            manager.isEnabled = true
            manager.saveToPreferences { _ in }
        }
    }
    #endif
}

#if ENABLE_NETWORK_EXTENSION
extension SystemExtensionEnforcer: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // The user must approve the extension in System Settings → General → Login Items & Extensions.
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if result == .completed { ensureFilterEnabled() }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        NSLog("System extension request failed: \(error)")
    }
}
#endif
