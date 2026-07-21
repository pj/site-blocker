import AppKit

/// Closes open browser tabs whose site just became blocked — the content filter only stops *new*
/// connections, so an already-loaded page keeps rendering until its tab is closed. Drives Safari
/// and Chromium-family browsers over Apple Events (requires the automation entitlement + the user
/// granting Automation permission per browser). Only running browsers are touched, so scripting
/// never launches one.
enum TabCloser {
    private struct Browser { let app: String; let bundleID: String }
    private static let browsers = [
        Browser(app: "Safari", bundleID: "com.apple.Safari"),
        Browser(app: "Google Chrome", bundleID: "com.google.Chrome"),
        Browser(app: "Brave Browser", bundleID: "com.brave.Browser"),
        Browser(app: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
    ]

    /// Close every open tab whose host matches one of `blockedDomains` (the domain itself or a
    /// subdomain of it). Dispatched to the main thread — NSAppleScript / Apple Events don't work off
    /// the main run loop (they return empty silently). `async` so it doesn't block the caller.
    static func closeTabs(blockedDomains: Set<String>) {
        guard !blockedDomains.isEmpty else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let targets = browsers.filter { running.contains($0.bundleID) }
        guard !targets.isEmpty else { return }
        sourceLog.error("TabCloser: \(blockedDomains.count, privacy: .public) blocked domains, browsers=\(targets.map(\.app).joined(separator: ","), privacy: .public)")
        DispatchQueue.main.async {
            for browser in targets { close(in: browser, blockedDomains: blockedDomains) }
        }
    }

    private static func isBlocked(_ host: String, in set: Set<String>) -> Bool {
        var suffix = Substring(host.lowercased())
        while true {
            if set.contains(String(suffix)) { return true }
            guard let dot = suffix.firstIndex(of: ".") else { return false }
            suffix = suffix[suffix.index(after: dot)...]
        }
    }

    private static func close(in browser: Browser, blockedDomains: Set<String>) {
        guard let listing = run(enumerateScript(browser.app)) else { return }
        var coords: [(window: Int, tab: Int)] = []
        for line in listing.split(separator: "\n") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, let win = Int(fields[0]), let tab = Int(fields[1]),
                  let host = URL(string: fields[2])?.host else { continue }
            if isBlocked(host, in: blockedDomains) { coords.append((win, tab)) }
        }
        sourceLog.error("TabCloser: \(browser.app, privacy: .public) — \(coords.count, privacy: .public) blocked tab(s) to close")
        guard !coords.isEmpty else { return }
        // Close from the highest index down so earlier indices stay valid as tabs disappear.
        coords.sort { $0.window != $1.window ? $0.window > $1.window : $0.tab > $1.tab }
        _ = run(closeScript(browser.app, coords))
    }

    /// Emit one "windowIndex\ttabIndex\tURL" line per tab. `tabChar`/`lf` are defined *outside* the
    /// `tell` block: inside it, the token `tab` resolves to the browser's tab class, not the tab
    /// character, which silently corrupts the delimiter. Per-window `try` skips a non-browser window
    /// without dropping the window count, so indices still line up with the close script.
    private static func enumerateScript(_ app: String) -> String {
        """
        set tabChar to character id 9
        set lf to character id 10
        tell application "\(app)"
          set out to ""
          set wi to 0
          repeat with w in windows
            set wi to wi + 1
            try
              set ti to 0
              repeat with t in tabs of w
                set ti to ti + 1
                set out to out & wi & tabChar & ti & tabChar & (URL of t) & lf
              end repeat
            end try
          end repeat
          return out
        end tell
        """
    }

    private static func closeScript(_ app: String, _ coords: [(window: Int, tab: Int)]) -> String {
        let closes = coords.map { "close tab \($0.tab) of window \($0.window)" }.joined(separator: "\n")
        return "tell application \"\(app)\"\n\(closes)\nend tell"
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { sourceLog.error("TabCloser (\(source.prefix(24), privacy: .public)) failed: \(error, privacy: .public)") }
        return result?.stringValue
    }
}
