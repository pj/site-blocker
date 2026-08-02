import Foundation

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
