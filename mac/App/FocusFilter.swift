import Foundation
import AppIntents

/// Shared store of which Focus exceptions are active. There's no API to read the current Focus, so
/// the app ships a **Focus Filter** (`SiteBlockerFocusFilter`); the user attaches it to a Focus in
/// Settings and types a name matching a Focus exception. When that Focus turns on the system runs the
/// filter, which records the name here; the store reads it into `RuleContext.activeFocusIDs`.
///
/// Note: the system invokes the filter as the user's Focus configuration changes. Reliable clearing
/// when a Focus turns *off* depends on that OS callback and is validated on-device.
enum FocusBridge {
    private static let appGroup = "group.com.pauljohnson.siteblocker"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    private static let key = "activeFocusIDs"

    /// A stable identifier for a user-typed Focus name (case/space-insensitive).
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

    static func clear(_ id: String) {
        var set = activeFocusIDs
        set.remove(id)
        defaults?.set(Array(set), forKey: key)
    }
}

/// A Focus Filter the user attaches to a Focus in Settings. Typing a name that matches a Focus
/// exception makes that exception apply whenever the Focus is on.
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
