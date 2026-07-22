import Foundation
import FamilyControls

/// iOS coordinator. Owns the rules, requests Screen Time authorization, and delegates all
/// enforcement to `MobileEnforcer` (shared with the DeviceActivityMonitor extension). Rules enforce
/// automatically on their day/time/limit schedule; `isLocked` is a manual "block everything now"
/// override on top of that.
@MainActor
final class MobileStore: ObservableObject {
    /// Shared instance so App Intents (Shortcuts/Siri) control the same state as the UI.
    static let shared = MobileStore()

    @Published var rules: [MobileRule] {
        didSet {
            MobileEnforcer.saveRules(rules)
            MobileEnforcer.refreshSchedules(rules)
            MobileEnforcer.reevaluate()
        }
    }
    @Published private(set) var authorization: AuthorizationStatus =
        AuthorizationCenter.shared.authorizationStatus
    /// Manual override: block everything regardless of schedule.
    @Published private(set) var isLocked: Bool = MobileEnforcer.forceBlock

    init() {
        rules = MobileEnforcer.loadRules()
        MobileEnforcer.refreshSchedules(rules)
        MobileEnforcer.reevaluate()
    }

    var isAuthorized: Bool { authorization == .approved }

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            print("Family Controls authorization failed: \(error)")
        }
        authorization = AuthorizationCenter.shared.authorizationStatus
        MobileEnforcer.refreshSchedules(rules)
        MobileEnforcer.reevaluate()
    }

    // MARK: Rules

    func add() { rules.append(MobileRule(name: "New Rule")) }
    func delete(_ rule: MobileRule) { rules.removeAll { $0.id == rule.id } }
    func update(_ rule: MobileRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule   // didSet persists, reschedules, re-evaluates
    }

    // MARK: Manual override

    func lock() { setOverride(true) }
    func unlock() { setOverride(false) }

    private func setOverride(_ on: Bool) {
        MobileEnforcer.forceBlock = on
        isLocked = on
        MobileEnforcer.reevaluate()
    }
}
