import Foundation

/// Takes a server's address and every secret out of the text the app log keeps
/// (gap G24, need B-15).
///
/// Pure and value-typed: a vocabulary (`hosts`, `ports`, `basePaths`,
/// `secrets`) that only ever grows, and `redact(_:)`, which rewrites a text with
/// it. `AppLogStore` owns one and applies it **when a line is recorded**, so the
/// screen, the detail blocks, the clipboard and the export can only ever read
/// lines that are already clean.
///
/// What stays: the path of an API call (`/api/assets/abc`), its status, its
/// duration and the nature of a failure. What goes: the host, the port, the
/// sub-path an installation is served under (`/immich`), every `?query`, and any
/// token, key or password the app has handled.
///
/// Known limits, accepted: a secret shorter than 4 characters is never learnt
/// (masked everywhere it would shred the text); a bare 1–3 digit port is only
/// masked glued to a host; a host that is also an ordinary word (`server`) masks
/// that word in free text, though never inside an API path.
struct AppLogRedactor: Sendable, Equatable {
    /// Replaces every masked value. Language-free on purpose: it is not a word
    /// to translate.
    static let marker = "•••"

    /// Lower-cased host names or IP addresses.
    private(set) var hosts: Set<String> = []
    private(set) var ports: Set<Int> = []
    /// Sub-paths a server is installed under (`/immich`).
    private(set) var basePaths: Set<String> = []
    private(set) var secrets: Set<String> = []

    // MARK: - Learning

    /// The host, explicit port and sub-path of a server address. `true` when the
    /// vocabulary grew.
    @discardableResult
    mutating func learnServer(_ baseURL: URL) -> Bool {
        var grew = false
        if let host = baseURL.host?.lowercased(), !host.isEmpty {
            grew = hosts.insert(host).inserted || grew
        }
        if let port = baseURL.port {
            grew = ports.insert(port).inserted || grew
        }
        var path = baseURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if !path.isEmpty, path != "/", path != "/api" {
            grew = basePaths.insert(path).inserted || grew
        }
        return grew
    }

    /// A secret of at least 4 characters. `true` when the vocabulary grew.
    @discardableResult
    mutating func learnSecret(_ value: String) -> Bool {
        guard value.count >= 4 else { return false }
        return secrets.insert(value).inserted
    }

    /// The secrets one request carries: the values of its credential headers
    /// (a closed list, plus the server's custom header names) and of its
    /// credential-looking query parameters. Every other header is ignored, and
    /// so is `x-immich-checksum` — a digest that differs on every upload would
    /// make the vocabulary grow with the traffic.
    @discardableResult
    mutating func learnRequest(_ request: URLRequest, customHeaderNames: [String]) -> Bool {
        var grew = false
        var watched: Set<String> = ["authorization", "x-immich-user-token", "x-api-key", "cookie"]
        for name in customHeaderNames { watched.insert(name.lowercased()) }
        watched.remove("x-immich-checksum")

        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lowered = name.lowercased()
            guard watched.contains(lowered) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            grew = learnSecret(trimmed) || grew
            if let space = trimmed.firstIndex(of: " ") {
                let rest = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
                grew = learnSecret(rest) || grew
            }
            if lowered == "cookie" {
                for pair in trimmed.split(whereSeparator: { $0 == ";" || $0 == "," }) {
                    guard let equals = pair.firstIndex(of: "=") else { continue }
                    let cookieValue = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                    grew = learnSecret(cookieValue) || grew
                }
            }
        }

        if let url = request.url,
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                guard let value = item.value, Self.isCredentialParameter(item.name) else { continue }
                grew = learnSecret(value) || grew
            }
        }
        return grew
    }

    private static func isCredentialParameter(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered == "key" || lowered == "slug" { return true }
        return ["token", "secret", "password", "apikey"].contains { lowered.contains($0) }
    }

    // MARK: - Redacting

    /// What this vocabulary has that `older` had not: masking a line that
    /// `older` already masked with just this part gives the line this one would
    /// (every rule is idempotent), at the cost of the new items alone.
    func additions(since older: AppLogRedactor) -> AppLogRedactor {
        var delta = AppLogRedactor()
        delta.hosts = hosts.subtracting(older.hosts)
        delta.ports = ports.subtracting(older.ports)
        delta.basePaths = basePaths.subtracting(older.basePaths)
        delta.secrets = secrets.subtracting(older.secrets)
        return delta
    }

    /// The same line, with `path`, `message`, `details` and `stack` redacted.
    /// Nothing the diagnosis reads (date, level, category, method, status,
    /// duration) is touched.
    func redact(_ entry: AppLogEntry) -> AppLogEntry {
        AppLogEntry(
            id: entry.id,
            date: entry.date,
            level: entry.level,
            method: entry.method,
            path: redact(entry.path),
            status: entry.status,
            durationMS: entry.durationMS,
            category: entry.category,
            message: redact(entry.message),
            details: entry.details.map { redact($0) },
            stack: entry.stack.map { redact($0) }
        )
    }

    func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text

        // 1. Secrets, longest first so a secret containing another goes whole.
        for secret in secrets.sorted(by: { $0.count > $1.count }) where out.contains(secret) {
            out = out.replacingOccurrences(of: secret, with: Self.marker)
        }

        // 2. A bare bearer token.
        out = Self.replace(out, Self.bearerPattern) { _, _ in Self.marker }

        // 3. A whole URL keeps only its API tail.
        out = Self.replace(out, Self.urlPattern) { ns, match in
            let raw = ns.substring(with: match.range)
            var url = raw
            var trailing = ""
            while let last = url.last, Self.trailingPunctuation.contains(last) {
                trailing.insert(last, at: trailing.startIndex)
                url.removeLast()
            }
            return Self.marker + Self.apiTail(ofURL: url) + trailing
        }

        // 4. A bare `?name=value`.
        out = Self.replace(out, Self.queryPattern) { _, _ in "" }

        // 5. Hosts, as whole DNS words, never inside an API path.
        for host in hosts.sorted(by: { $0.count > $1.count })
        where out.range(of: host, options: .caseInsensitive) != nil {
            let pattern = "(?<![A-Za-z0-9-])" + NSRegularExpression.escapedPattern(for: host)
                + "(?::[0-9]+)?+(?![A-Za-z0-9-])(?!\\.[A-Za-z0-9-])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = Self.replace(out, regex, skippingAPIPaths: true) { _, _ in Self.marker }
        }

        // 6. Ports of four digits or more, standing alone.
        for port in ports.sorted(by: >) where port >= 1000 && out.contains(String(port)) {
            let pattern = "(?<![A-Za-z0-9])\(port)(?![A-Za-z0-9])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = Self.replace(out, regex, skippingAPIPaths: true) { _, _ in Self.marker }
        }

        // 7. Sub-paths: dropped in front of `/api`, masked at the end of a
        //    segment anywhere else.
        for base in basePaths.sorted(by: { $0.count > $1.count }) where out.contains(base) {
            let escaped = NSRegularExpression.escapedPattern(for: base)
            if let regex = try? NSRegularExpression(pattern: escaped + #"(?=/api(?:/|$|[\s?#"'<>“”‘’]))"#) {
                out = Self.replace(out, regex) { _, _ in "" }
            }
            if let regex = try? NSRegularExpression(pattern: escaped + "(?![A-Za-z0-9._~-])") {
                out = Self.replace(out, regex, skippingAPIPaths: true) { _, _ in Self.marker }
            }
        }
        return out
    }

    // MARK: - Machinery

    private static let bearerPattern = makeRegex(#"\bbearer\s+\S+"#, caseInsensitive: true)
    private static let urlPattern = makeRegex(#"\b(?:https?|wss?)://[^\s"'<>“”‘’]+"#, caseInsensitive: true)
    private static let queryPattern = makeRegex(#"\?[A-Za-z0-9_.~-]+=[^\s]*"#, caseInsensitive: false)
    private static let apiSegmentPattern = makeRegex(#"/api(?=/|$|[\s?#"'<>“”‘’])"#, caseInsensitive: false)
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", ")", "]", "}"]
    private static let terminators: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "?#\"'<>“”‘’")
        return set
    }()

    private static func makeRegex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression {
        // The patterns are constants of this file: a failure here is a typo.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Rewrites every match, right to left so the earlier ranges stay valid.
    /// `transform` returns the replacement. With `skippingAPIPaths`, a match
    /// that touches an API path (see `apiPathRanges`) is left alone.
    private static func replace(
        _ text: String,
        _ regex: NSRegularExpression,
        skippingAPIPaths: Bool = false,
        _ transform: (NSString, NSTextCheckingResult) -> String
    ) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let protected = skippingAPIPaths ? apiPathRanges(in: ns) : []
        let out = NSMutableString(string: text)
        for match in matches.reversed() {
            if protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            out.replaceCharacters(in: match.range, with: transform(ns, match))
        }
        return out as String
    }

    /// An API path: from a `/api` segment to the next terminator (blank, `?`,
    /// `#`, a quote or an angle bracket).
    private static func apiPathRanges(in ns: NSString) -> [NSRange] {
        apiSegmentPattern.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).map { match in
            var end = match.range.location + match.range.length
            while end < ns.length, !isTerminator(ns.character(at: end)) { end += 1 }
            return NSRange(location: match.range.location, length: end - match.range.location)
        }
    }

    private static func isTerminator(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return terminators.contains(scalar)
    }

    /// `/api/assets` out of `https://host:2283/immich/api/assets?key=K`; empty
    /// when the URL's path has no `/api` segment.
    private static func apiTail(ofURL url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return "" }
        let rest = url[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return "" }
        var path = rest[slash...]
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = path[..<cut]
        }
        var from = path.startIndex
        while let hit = path.range(of: "/api", range: from..<path.endIndex) {
            if hit.upperBound == path.endIndex || path[hit.upperBound] == "/" {
                return String(path[hit.lowerBound...])
            }
            from = hit.upperBound
        }
        return ""
    }
}
