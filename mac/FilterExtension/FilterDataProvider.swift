import NetworkExtension
import Network
import OSLog
import RulesEngine

private let filterLog = Logger(subsystem: "com.pauljohnson.siteblocker", category: "filter")

/// The content-filter system extension. Runs sandboxed (as root), sees every network flow, and
/// returns an allow/drop verdict.
///
/// Rules logic stays app-side: the app resolves the current blocked set and writes it to a fixed
/// shared file (`PolicySnapshot.fileURL`); the extension is a thin check. Because a socket flow's
/// endpoint is the *resolved IP*, not a hostname, we can't match domains at `handleNewFlow` time.
/// Instead we peek the flow's outbound TLS ClientHello and read the SNI server name — the hostname
/// the browser actually asked for — and match that.
final class FilterDataProvider: NEFilterDataProvider {
    /// Blocked domains as a hash set for O(labels) suffix matching — a linear scan of a large
    /// blocklist (hundreds of thousands of entries) per flow would be far too slow.
    private var blockedDomains: Set<String> = []
    /// Modification time of the last snapshot we decoded, so we re-read only when it changes rather
    /// than decoding a multi-megabyte file on every flow.
    private var snapshotMTime: Date?

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        reloadSnapshotIfNeeded()
        filterLog.error("startFilter — \(self.blockedDomains.count, privacy: .public) blocked domains")
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // HTTPS (443): peek the outbound handshake so we can read the SNI hostname. Everything else
        // we allow (the hostname isn't available for plain socket flows).
        guard let socket = flow as? NEFilterSocketFlow, Self.remotePort(socket) == 443 else {
            return .allow()
        }
        return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                  filterOutbound: true, peekOutboundBytes: 4096)
    }

    override func handleOutboundData(from flow: NEFilterFlow,
                                     readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        guard let host = Self.sniHostname(from: readBytes) else {
            // Not a parseable ClientHello (or SNI absent) — let it through and stop inspecting.
            return .allow()
        }
        reloadSnapshotIfNeeded()
        let blocked = isBlocked(host)
        filterLog.error("\(blocked ? "DROP" : "allow", privacy: .public) \(host, privacy: .public)")
        return blocked ? .drop() : .allow()
    }

    /// Blocked if the hostname, or any parent domain of it, is in the blocked set — the standard
    /// "domain and all subdomains" rule, done as O(number of labels) hash lookups.
    private func isBlocked(_ hostname: String) -> Bool {
        guard !blockedDomains.isEmpty else { return false }
        var suffix = Substring(hostname.lowercased())
        while true {
            if blockedDomains.contains(String(suffix)) { return true }
            guard let dot = suffix.firstIndex(of: ".") else { return false }
            suffix = suffix[suffix.index(after: dot)...]
        }
    }

    private func reloadSnapshotIfNeeded() {
        // Read the fixed shared path (see `PolicySnapshot.fileURL`): this extension runs sandboxed as
        // root, so the App Group container (per-user, /var/root) doesn't match the app's. A sandbox
        // temporary-exception entitlement grants read access. Re-decode only when the file changes.
        let path = PolicySnapshot.fileURL.path
        // Stat via FileManager, not URL.resourceValues: the latter caches on the (shared static) URL
        // instance and would never see the app's updates.
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date else {
            filterLog.error("reloadSnapshot: cannot stat \(path, privacy: .public)")
            return
        }
        guard mtime != snapshotMTime else { return }
        guard let data = try? Data(contentsOf: PolicySnapshot.fileURL),
              let snapshot = try? JSONDecoder().decode(PolicySnapshot.self, from: data) else {
            filterLog.error("reloadSnapshot: cannot read/decode \(path, privacy: .public)")
            return
        }
        snapshotMTime = mtime
        blockedDomains = Set(snapshot.blockedPatterns.map { $0.domain.lowercased() })
        filterLog.error("snapshot reloaded — \(self.blockedDomains.count, privacy: .public) domains")
    }

    private static func remotePort(_ socket: NEFilterSocketFlow) -> Int? {
        guard let endpoint = socket.remoteFlowEndpoint,
              case let .hostPort(_, port) = endpoint else { return nil }
        return Int(port.rawValue)
    }

    /// Parse the SNI host_name from a TLS ClientHello. Returns `nil` if `bytes` isn't a ClientHello
    /// or carries no server_name extension. Bounds-checked throughout — the input is attacker-shaped.
    static func sniHostname(from bytes: Data) -> String? {
        let b = [UInt8](bytes)
        var i = 0
        func u8() -> Int? { guard i < b.count else { return nil }; defer { i += 1 }; return Int(b[i]) }
        func u16() -> Int? { guard let h = u8(), let l = u8() else { return nil }; return h << 8 | l }

        // TLS record header: type(0x16 handshake), version(2), length(2)
        guard b.count >= 5, b[0] == 0x16 else { return nil }
        i = 5
        // Handshake header: type(0x01 ClientHello), length(3)
        guard u8() == 0x01 else { return nil }
        i += 3                                   // handshake length
        i += 2                                   // client_version
        i += 32                                  // random
        guard let sessionLen = u8() else { return nil }
        i += sessionLen                          // session_id
        guard let cipherLen = u16() else { return nil }
        i += cipherLen                           // cipher_suites
        guard let compLen = u8() else { return nil }
        i += compLen                             // compression_methods
        guard u16() != nil else { return nil }   // extensions total length

        while i + 4 <= b.count {
            guard let extType = u16(), let extLen = u16() else { return nil }
            if extType == 0x0000 {               // server_name
                guard u16() != nil else { return nil }          // server_name_list length
                guard u8() == 0x00 else { return nil }          // name_type host_name
                guard let nameLen = u16(), i + nameLen <= b.count else { return nil }
                return String(bytes: b[i..<i + nameLen], encoding: .utf8)
            }
            i += extLen                          // skip other extensions
        }
        return nil
    }
}
