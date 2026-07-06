import Foundation

/// A pattern that matches a hostname. It matches the exact domain or any subdomain of it.
///
///     HostPattern("youtube.com").matches(hostname: "www.youtube.com")  // true
///     HostPattern("youtube.com").matches(hostname: "m.youtube.com")    // true
///     HostPattern("youtube.com").matches(hostname: "notyoutube.com")   // false
///
/// Input is normalized so you can paste a full URL and get sane behavior.
public struct HostPattern: Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral {
    public var domain: String
    public var id: String { domain }

    public init(_ raw: String) {
        self.domain = HostPattern.normalize(raw)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// Lowercase, strip scheme/path/port and a leading `www.` so patterns and live
    /// hostnames compare cleanly.
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        while s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    public func matches(hostname: String) -> Bool {
        let h = HostPattern.normalize(hostname)
        return h == domain || h.hasSuffix("." + domain)
    }
}
