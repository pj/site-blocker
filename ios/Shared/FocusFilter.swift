import Foundation
import AppIntents

/// Shared store of which Focus exceptions are active (mirrors the macOS `FocusBridge`). There's no
/// API to read the current Focus, so the app ships a Focus Filter the user attaches to a Focus in
/// Settings; when that Focus is on the system runs the filter, which records its name here for the
/// engine to read via `RuleContext.activeFocusIDs`.
///
/// Note: reliable clearing when a Focus turns *off* depends on the OS re-invoking the filter, and is
/// validated on-device.
enum FocusBridge {
    private static let appGroup = "group.com.pauljohnson.siteblocker"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    private static let key = "activeFocusIDs"

    static func identifier(for name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var activeFocusIDs: Set<String> {
        Set(defaults?.stringArray(forKey: key) ?? [])
    }

    /// Make `id` the (only) active Focus exception — one Focus is active at a time.
    static func setOnlyActive(_ id: String) {
        defaults?.set([id], forKey: key)
    }
}

struct SiteBlockerFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "SiteBlocker Focus exception"
    static let description = IntentDescription(
        "Applies SiteBlocker list exceptions whose Focus name matches, while this Focus is on.")

    @Parameter(title: "Focus name",
               description: "Match this to a list exception's Focus name in SiteBlocker (e.g. Work).")
    var focusName: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "SiteBlocker: \(focusName ?? "")")
    }

    func perform() async throws -> some IntentResult {
        if let name = focusName, !name.isEmpty {
            FocusBridge.setOnlyActive(FocusBridge.identifier(for: name))
        }
        return .result()
    }
}
