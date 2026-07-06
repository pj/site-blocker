import NetworkExtension
import Network
import RulesEngine

/// The content-filter system extension. Runs in its own sandboxed process, sees every network
/// flow, and returns an allow/drop verdict per flow.
///
/// It holds no rules logic of its own: it loads the `PolicySnapshot` the app wrote to the shared
/// App Group container and asks the shared `BlockEngine` to decide. That keeps enforcement and the
/// app perfectly in sync and means all the interesting logic stays unit-tested in `RulesEngine`.
final class FilterDataProvider: NEFilterDataProvider {
    private var snapshot: PolicySnapshot?

    /// Must match `PersistenceController.appGroupID`.
    private static let appGroupID = "group.com.pauljohnson.siteblocker"

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        reloadSnapshot()
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // Re-read on demand so rule/quota changes take effect quickly. (Could be optimized to a
        // file-watch + cached decode; fine as-is for a personal tool.)
        reloadSnapshot()
        guard let snapshot, let hostname = Self.hostname(for: flow) else {
            return .allow()
        }
        let decision = snapshot.engine.decision(forHostname: hostname, in: snapshot.context())
        return decision.isBlocked ? .drop() : .allow()
    }

    private func reloadSnapshot() {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else { return }
        let url = container.appendingPathComponent("policy.json")
        guard let data = try? Data(contentsOf: url) else { return }
        snapshot = try? JSONDecoder().decode(PolicySnapshot.self, from: data)
    }

    /// Extract a hostname from a flow. On macOS every filtered flow is a socket flow; its
    /// `remoteFlowEndpoint` carries the destination. `.name` is the DNS hostname when the
    /// connection was made by name (the usual case — browsers resolve then connect), otherwise we
    /// fall back to the IP literal. Hostname rules therefore key off name/SNI info, not reverse-DNS.
    static func hostname(for flow: NEFilterFlow) -> String? {
        guard let socket = flow as? NEFilterSocketFlow,
              let endpoint = socket.remoteFlowEndpoint,
              case let .hostPort(host, _) = endpoint else {
            return nil
        }
        switch host {
        case .name(let name, _): return name
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        @unknown default: return nil
        }
    }
}
