import Foundation

/// One iOS block rule: a named list of website domains blocked in Safari via the Content Blocker.
///
/// This build is site-only (no Family Controls), so there are no app targets and no day/time/limit
/// schedule — Safari content blockers are static rulesets with no per-request time logic. Enabled
/// rules' domains are blocked whenever blocking isn't paused. Grouping into named rules just lets
/// you toggle a set of sites together.
struct MobileRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var isEnabled = true
    /// Websites, typed or pasted as a list — plain domains you can read, edit, and import.
    var siteDomains: [String] = []

    var summary: String {
        guard !siteDomains.isEmpty else { return "no sites" }
        return "\(siteDomains.count) site\(siteDomains.count == 1 ? "" : "s")"
    }
}
