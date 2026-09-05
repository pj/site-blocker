import Foundation
import SafariServices
import RulesEngine

/// Generates the Safari Content Blocker rule JSON from typed domains and reloads the extension.
/// Safari content blockers are static rulesets (no per-request time-of-day logic), so the *app*
/// decides which domains are blocked right now (based on lock state) and rewrites the ruleset.
enum SiteRuleset {
    static let contentBlockerID = "com.pauljohnson.siteblocker.ios.ContentBlocker"
    private static let appGroup = "group.com.pauljohnson.siteblocker"
    /// WebKit caps a ruleset at ~150k rules; keep each rule's `if-domain` list well under that and
    /// chunk large lists across several block rules.
    private static let chunkSize = 10_000

    /// Parse a pasted/typed domain list: one per line or hosts format, `# ! ;` comments stripped,
    /// normalized to bare domains (scheme/path/`www.` removed) and de-duplicated.
    static func parse(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        text.enumerateLines { rawLine, _ in
            var line = rawLine
            if let comment = line.firstIndex(where: { "#!;".contains($0) }) {
                line = String(line[..<comment])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) ?? line
            let domain = HostPattern(token).domain
            guard !domain.isEmpty, domain != "localhost", seen.insert(domain).inserted else { return }
            out.append(domain)
        }
        return out
    }

    /// Write the ruleset that blocks `domains` (each domain and its subdomains) and ask Safari to
    /// reload it.
    static func rebuild(blocking domains: [String]) {
        var rules: [[String: Any]] = stride(from: 0, to: domains.count, by: chunkSize).map { start in
            let chunk = domains[start..<min(start + chunkSize, domains.count)]
            return [
                "action": ["type": "block"],
                "trigger": ["url-filter": ".*", "if-domain": chunk.map { "*\($0)" }],
            ]
        }
        // WebKit *rejects* an empty rule array and keeps the previously-compiled ruleset — which
        // would leave sites blocked even after everything is unblocked. When nothing is blocked,
        // emit a single no-op rule (scoped to a domain that can't exist) so a valid, non-empty
        // ruleset always compiles and replaces the old one.
        if rules.isEmpty {
            rules = [[
                "action": ["type": "block"],
                "trigger": ["url-filter": ".*", "if-domain": ["*siteblocker.invalid"]],
            ]]
        }

        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let url = container.appendingPathComponent("blockerList.json")
        if let data = try? JSONSerialization.data(withJSONObject: rules) {
            try? data.write(to: url)
        }
        SFContentBlockerManager.reloadContentBlocker(withIdentifier: contentBlockerID) { error in
            if let error { print("reloadContentBlocker failed: \(error)") }
        }
    }
}
