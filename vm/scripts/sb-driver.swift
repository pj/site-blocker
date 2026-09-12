// sb-driver.swift — fixtures + snapshot assertions for the SiteBlocker e2e harness.
//
// Compiled on the host together with the RulesEngine sources into a single arm64 binary, then
// copied into the VM (which has no Swift toolchain). Because it is compiled *with* the real engine
// types, the lists.json it writes is guaranteed to decode in the app, and the snapshot check uses
// the exact same membership logic the content-filter extension relies on — no hand-written JSON to
// drift out of shape.
//
// Usage:
//   sb-driver write-lists <scenario> <lists.json path>
//   sb-driver check <policy.json path> <hostname>     -> prints "blocked" or "allowed"
//   sb-driver count <policy.json path>                -> number of blocked host patterns
//   sb-driver age   <policy.json path>                -> whole seconds since the snapshot was written
//
// A missing snapshot file counts as an empty blocked set ("allowed"), so a scenario that expects
// nothing blocked passes whether the app wrote an empty snapshot or skipped the write.

import Foundation

@main
struct SBDriver {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    // Minutes since local midnight, and today's weekday, from the *VM's* clock — the same clock the
    // app evaluates against, so a "covers now" window really does cover the app's now.
    static func nowMinutes() -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    static func today() -> Weekday {
        Weekday(rawValue: Calendar.current.component(.weekday, from: Date())) ?? .monday
    }

    /// The list content for a named scenario. One list named "E2E <scenario>" with fixed targets,
    /// varying only in base state + exception so each scenario asserts one thing.
    static func lists(for scenario: String) -> [SiteList] {
        let targets: [HostPattern] = ["example.com", "tracker.test"]
        let m = nowMinutes()
        // A window that reliably contains now (start=now, 3h of slack, wrapping past midnight if
        // need be) and one that reliably does not (a 2h window starting 2h out).
        let active = TimeWindow(startMinutes: m, endMinutes: (m + 180) % 1440)
        let inactive = TimeWindow(startMinutes: (m + 120) % 1440, endMinutes: (m + 240) % 1440)

        func list(_ name: String, blockedByDefault: Bool, rules: [ListRule]) -> SiteList {
            SiteList(name: name, targets: targets, isBlockedByDefault: blockedByDefault, rules: rules)
        }

        switch scenario {
        case "blocked-basic":        // blocked by default, no exception → targets blocked
            return [list("E2E blocked-basic", blockedByDefault: true, rules: [])]
        case "allow-always":         // always-on allow exception → targets allowed
            return [list("E2E allow-always", blockedByDefault: true,
                         rules: [ListRule(condition: .always)])]
        case "schedule-active":      // allow window covering now → allowed
            return [list("E2E schedule-active", blockedByDefault: true, rules: [
                ListRule(condition: .allOf([.onDaysOfWeek([today()]), .duringTimeOfDay(active)]))])]
        case "schedule-inactive":    // allow window not covering now → blocked
            return [list("E2E schedule-inactive", blockedByDefault: true, rules: [
                ListRule(condition: .allOf([.onDaysOfWeek([today()]), .duringTimeOfDay(inactive)]))])]
        case "location-no-signal":   // allow "while at region" but no location fix → inactive → blocked
            return [list("E2E location-no-signal", blockedByDefault: true, rules: [
                ListRule(condition: .atLocation(GeoRegion(
                    name: "Nowhere", latitude: 0.0001, longitude: 0.0001, radius: 100)))])]
        case "persistence":          // a distinctively-named list to look for after a relaunch
            return [list("E2E Persist Marker", blockedByDefault: true, rules: [])]
        default:
            fail("unknown scenario '\(scenario)' — known: blocked-basic allow-always schedule-active schedule-inactive location-no-signal persistence")
        }
    }

    static func loadSnapshot(_ path: String) -> PolicySnapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(PolicySnapshot.self, from: data)
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            fail("usage: sb-driver <write-lists|check|count|age> ...")
        }

        switch command {
        case "write-lists":
            guard args.count >= 3 else { fail("write-lists needs <scenario> <outpath>") }
            let lists = lists(for: args[1])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(lists) else { fail("could not encode lists") }
            let url = URL(fileURLWithPath: args[2])
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try data.write(to: url) } catch { fail("could not write \(args[2]): \(error)") }
            print("wrote \(lists.count) list(s) for '\(args[1])' to \(args[2])")

        case "check":
            // Missing snapshot == empty blocked set == allowed.
            guard args.count >= 3 else { fail("check needs <snapshot path> <hostname>") }
            let snapshot = loadSnapshot(args[1])
            let blocked = snapshot?.isBlocked(hostname: args[2]) ?? false
            print(blocked ? "blocked" : "allowed")

        case "count":
            guard args.count >= 2 else { fail("count needs <snapshot path>") }
            print(loadSnapshot(args[1])?.blockedPatterns.count ?? 0)

        case "age":
            guard args.count >= 2 else { fail("age needs <snapshot path>") }
            guard let snap = loadSnapshot(args[1]) else { print(-1); return }
            print(Int(Date().timeIntervalSince(snap.updatedAt)))

        default:
            fail("unknown command '\(command)'")
        }
    }
}
