import Foundation

/// Public URL of a shared link — ONE builder, used by every surface that shows
/// or copies a link.
///
/// The rule is the server's, mirrored from the Flutter client
/// (`mobile/lib/utils/url_helper.dart`, `buildSharedLinkUrl`) and the web
/// routes `(user)/s/[slug]` and `/share/[key]`:
///
/// * the base is `externalDomain` when the server advertises one, otherwise
///   the server URL the app is connected to — a server behind a reverse proxy
///   is reached through its public domain, not its internal address;
/// * the path is `s/<slug>` when the link carries a custom slug, otherwise
///   `share/<key>`.
///
/// The app used to hardcode `share/<key>` in two places, which produced a dead
/// link for any link carrying a slug, and for any proxied server (the
/// onboarding screen already displayed `externalDomain`, so the field was known
/// but unused).
struct SharedLinkURL: Equatable, Sendable {
    /// Server URL the app is connected to. Used when `externalDomain` is empty.
    let serverURL: URL
    /// `ServerConfig.externalDomain` — empty when the admin did not set one.
    let externalDomain: String

    init(serverURL: URL, externalDomain: String = "") {
        self.serverURL = serverURL
        self.externalDomain = externalDomain
    }

    /// Base actually used for links: the external domain when the server
    /// advertises one, the server URL otherwise. Trailing slashes are dropped
    /// so joining a path never doubles a separator; a domain without a scheme
    /// is taken as HTTPS (the admin UI accepts a bare host).
    var baseURL: URL {
        let domain = externalDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { return serverURL }

        var trimmed = domain
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url
        }
        return URL(string: "https://\(trimmed)") ?? serverURL
    }

    /// The link's public URL. A slug always wins over the key — that is the
    /// point of a custom slug — and `key` is the `SharedLinkResponseDto.key`.
    func url(slug: String?, key: String) -> URL {
        let slugged = slug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = slugged.isEmpty ? "share/\(key)" : "s/\(slugged)"
        return baseURL.appendingPathComponent(path)
    }

    /// Same URL as a string, for the pasteboard and the share sheet.
    func urlString(slug: String?, key: String) -> String {
        url(slug: slug, key: key).absoluteString
    }

    // MARK: - Reading a link someone sent you (issue #22)

    /// A link in the visitor's hands: the server it names (when the text
    /// carried one) plus the credential to present.
    struct Reference: Equatable, Sendable {
        let host: String?
        let credential: SharedLinkCredential
    }

    /// Parses a shared link the way a person pastes it, and settles the
    /// key-or-slug question the wire needs answered.
    ///
    /// Accepted shapes — all of them things the app itself produces or that a
    /// chat app hands over verbatim:
    ///
    /// * `https://host/s/<slug>` — the custom-slug public URL;
    /// * `https://host/share/<key>` — the key public URL;
    /// * `host/s/<slug>` (no scheme) — what a copied link sometimes loses;
    /// * a bare token — a key or a slug typed by hand.
    ///
    /// The bare token is disambiguated by shape: a key is
    /// `CryptoRepository.randomBytes(50).toString('base64url')`, so ~67
    /// base64url characters (the server still accepts a legacy 100-char hex
    /// key — same alphabet), while a slug is a short human word. Anything
    /// shorter than 40 characters, or carrying a character outside the
    /// alphabet, is read as a slug.
    ///
    /// Returns `nil` for text with no credential in it at all.
    static func reference(from text: String) -> Reference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A URL — with a scheme, or the scheme-less form a copy sometimes
        // leaves behind (`URL(string:)` needs the scheme to populate `host`).
        if let url = URL(string: trimmed), url.host != nil, let parsed = credential(in: url) {
            return Reference(host: url.host?.lowercased(), credential: parsed)
        }
        if trimmed.contains("/"),
           let url = URL(string: "https://\(trimmed)"), url.host != nil,
           let parsed = credential(in: url) {
            return Reference(host: url.host?.lowercased(), credential: parsed)
        }

        // A bare token — only when the text is a single segment (a host or
        // path with no credential in it is not one, and neither is prose).
        guard !trimmed.contains("/"),
              !trimmed.contains("."),
              !trimmed.contains(where: \.isWhitespace) else { return nil }
        return Reference(host: nil, credential: Self.credential(fromBareToken: trimmed))
    }

    /// The credential a public path carries: the segment after `s` is a slug,
    /// the one after `share` is a key.
    private static func credential(in url: URL) -> SharedLinkCredential? {
        let segments = url.pathComponents.filter { !$0.isEmpty && $0 != "/" }
        guard let marker = segments.firstIndex(where: { $0 == "s" || $0 == "share" }),
              segments.index(after: marker) < segments.endIndex else { return nil }
        let value = segments[segments.index(after: marker)]
        guard !value.isEmpty else { return nil }
        return segments[marker] == "s" ? .slug(value) : .key(value)
    }

    private static func credential(fromBareToken token: String) -> SharedLinkCredential {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let looksLikeKey = token.count >= 40 && token.allSatisfy(alphabet.contains)
        return looksLikeKey ? .key(token) : .slug(token)
    }
}
