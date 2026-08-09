import Foundation
import RulesEngine

/// iOS coordinator. Owns the block rules (named domain lists) and a global pause switch, and
/// delegates ruleset rebuilding to `MobileEnforcer`. Enabled rules block in Safari unless paused.
@MainActor
final class MobileStore: ObservableObject {
    /// Shared instance so App Intents (Shortcuts/Siri) control the same state as the UI.
    static let shared = MobileStore()

    @Published var rules: [MobileRule] {
        didSet {
            MobileEnforcer.saveRules(rules)
            MobileEnforcer.reevaluate()
        }
    }
    /// When true, nothing is blocked (a temporary break). Inverse of "blocking on".
    @Published private(set) var isPaused: Bool = MobileEnforcer.isPaused

    init() {
        rules = MobileEnforcer.loadRules()
        MobileEnforcer.reevaluate()
    }

    // MARK: Rules

    func add() { rules.append(MobileRule(name: "New Rule")) }
    func delete(_ rule: MobileRule) { rules.removeAll { $0.id == rule.id } }
    func update(_ rule: MobileRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule   // didSet persists + re-evaluates
    }

    /// Replace the rules with a shared config fetched from `url` (Settings → Import). Each config
    /// entry becomes a local rule (inline domains plus any `blocklistUrl` fetched and merged); the
    /// schedule fields don't apply to the site-only build. The Mac is the source of truth.
    func importConfig(from url: URL) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData   // the gist raw URL is CDN-cached
        let (data, _) = try await URLSession.shared.data(for: request)
        let config = try JSONDecoder().decode(SyncedConfig.self, from: data)

        var mirrored: [MobileRule] = []
        for rule in config.rules {
            var domains = rule.domains
            if let string = rule.blocklistUrl, let listURL = URL(string: string),
               let (listData, _) = try? await URLSession.shared.data(from: listURL) {
                domains += SiteRuleset.parse(String(decoding: listData, as: UTF8.self))
            }
            mirrored.append(MobileRule(
                name: rule.name, isEnabled: rule.enabled,
                siteDomains: SiteRuleset.parse(domains.joined(separator: "\n"))))
        }
        rules = mirrored   // didSet persists + rebuilds the Safari content blocker
    }

    // MARK: Pause / resume

    /// "Blocking on" in the UI == not paused.
    var isBlocking: Bool { !isPaused }

    func pause() { setPaused(true) }
    func resume() { setPaused(false) }

    private func setPaused(_ on: Bool) {
        MobileEnforcer.isPaused = on
        isPaused = on
        MobileEnforcer.reevaluate()
    }
}
