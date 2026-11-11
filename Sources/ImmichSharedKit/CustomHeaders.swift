import Foundation
import Security
import os

// Custom HTTP headers (L-09): name/value pairs the user declares for one Immich
// server — a proxy password, an `X-Access` a Traefik or nginx in front demands.
// They live in the kit because the app, the widgets and the share extension all
// send them, and the widget processes cannot read the app's memory.

extension Notification.Name {
    /// Posted by the app's registry after a list was saved. `userInfo["serverKey"]`
    /// carries `ServerKey.rawValue`. The name and the value of a header never
    /// travel in it.
    public static let immichCustomHeadersChanged = Notification.Name("immichCustomHeadersChanged")
}

// MARK: - ServerKey

/// What identifies "the same server" for its headers: the lowercased host and the
/// effective port. The path, the query, a trailing slash and the scheme's case do
/// not count, so `https://Photos.Example.org/` and
/// `https://photos.example.org:443/api` are one server — and `localhost:8421`
/// and `127.0.0.1:8421` are two.
public struct ServerKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// `http`/`ws` default to port 80, `https`/`wss` to 443 (the realtime socket
    /// and the video loader name the same server as the API); any other scheme
    /// is not a server.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        let secure = scheme == "https" || scheme == "wss"
        let port = url.port ?? (secure ? 443 : 80)
        rawValue = Self.rawValue(host: host, port: port)
    }

    /// The server a TLS challenge comes from. A protection space without a port
    /// (0) takes the default of its protocol.
    public init(protectionSpace: URLProtectionSpace) {
        let port = protectionSpace.port > 0
            ? protectionSpace.port
            : (protectionSpace.protocol == NSURLProtectionSpaceHTTPS ? 443 : 80)
        rawValue = Self.rawValue(host: protectionSpace.host.lowercased(), port: port)
    }

    private static func rawValue(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// `host:port`: the keychain account of this server's client certificate
    /// mapping, and what the certificate screen shows.
    public var account: String { rawValue }

    public var description: String { rawValue }

    /// The text the editor shows: the host alone for a default port (80 or 443),
    /// `host:port` otherwise. The origin scheme is not kept, so both default
    /// ports read the same.
    public var displayName: String {
        for suffix in [":443", ":80"] where rawValue.hasSuffix(suffix) {
            return String(rawValue.dropLast(suffix.count))
        }
        return rawValue
    }
}

// MARK: - Header and validation

public struct CustomHTTPHeader: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum CustomHeaderIssue: Equatable, Sendable {
    case invalidName, reservedName, duplicateName, invalidValue
}

public enum CustomHeaderValidation {
    /// Names the app (or the system) sets itself, compared without case.
    /// `authorization` is deliberately absent: a proxy with Basic auth needs it
    /// (the app then carries its own token in `x-immich-user-token`).
    /// `user-agent`, `accept-language` and `accept-encoding` stay allowed, like in
    /// the official client; `ServerRedirectPolicy` keeps them from crossing hosts.
    public static let reservedNames: Set<String> = [
        "accept", "content-type", "content-length", "cookie", "host",
        "x-immich-checksum", "x-immich-user-token", "connection",
        "proxy-authenticate", "proxy-authorization", "www-authenticate",
    ]

    private static let tokenSymbols = Set("!#$%&'*+-.^_`|~")

    /// An RFC 9110 `token`: one or more of ``!#$%&'*+-.^_`|~``, digits and ASCII letters.
    static func isToken(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            let c = Character(scalar)
            return c.isLetter || c.isNumber || tokenSymbols.contains(c)
        }
    }

    static func isReserved(_ name: String) -> Bool {
        reservedNames.contains(name.lowercased())
    }

    private static func hasControlScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (scalar.value <= 0x1F && scalar.value != 0x09) || scalar.value == 0x7F
        }
    }

    /// Validates the rows in order. `issues` is keyed by the INPUT index. A row
    /// with an empty name or value (after trimming) is ignored without a message;
    /// a row in error never enters `headers`.
    public static func validate(
        _ rows: [(name: String, value: String)]
    ) -> (headers: [CustomHTTPHeader], issues: [Int: CustomHeaderIssue]) {
        var headers: [CustomHTTPHeader] = []
        var issues: [Int: CustomHeaderIssue] = [:]
        var seen: Set<String> = []
        for (index, row) in rows.enumerated() {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || value.isEmpty { continue }
            if !isToken(name) {
                issues[index] = .invalidName
            } else if isReserved(name) {
                issues[index] = .reservedName
            } else if seen.contains(name.lowercased()) {
                issues[index] = .duplicateName
            } else if hasControlScalar(value) {
                issues[index] = .invalidValue
            } else {
                seen.insert(name.lowercased())
                headers.append(CustomHTTPHeader(name: name, value: value))
            }
        }
        return (headers, issues)
    }
}

// MARK: - The one rule that puts headers on a request

/// How a request to the server is dressed: the custom headers, then the session
/// token. Every request path of the app, the widgets and the extension goes
/// through here, so the two cannot drift.
public enum ServerRequestAuthorization {
    public static let userTokenHeader = "x-immich-user-token"

    /// Custom headers first (a stored element that is not a valid, unreserved
    /// name is skipped), then the token. With a custom `Authorization` (a proxy
    /// with Basic auth) the token moves to `x-immich-user-token`, which the
    /// server reads before `Authorization`; otherwise it is the usual `Bearer`.
    /// Without custom headers: exactly `Authorization: Bearer <token>`, or nothing.
    public static func fields(
        token: String?, custom: [CustomHTTPHeader]
    ) -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        var customAuthorization = false
        for header in custom where CustomHeaderValidation.isToken(header.name)
            && !CustomHeaderValidation.isReserved(header.name) {
            result.append((name: header.name, value: header.value))
            if header.name.lowercased() == "authorization" { customAuthorization = true }
        }
        if let token, !token.isEmpty {
            if customAuthorization {
                result.append((name: userTokenHeader, value: token))
            } else {
                result.append((name: "Authorization", value: "Bearer \(token)"))
            }
        }
        return result
    }

    public static func apply(token: String?, custom: [CustomHTTPHeader], to request: inout URLRequest) {
        for field in fields(token: token, custom: custom) {
            request.setValue(field.value, forHTTPHeaderField: field.name)
        }
    }

    public static func dictionary(token: String?, custom: [CustomHTTPHeader]) -> [String: String] {
        var result: [String: String] = [:]
        for field in fields(token: token, custom: custom) { result[field.name] = field.value }
        return result
    }
}

// MARK: - Sources of the list

/// Who can say which headers a URL gets.
public protocol CustomHeadersProviding: Sendable {
    func headers(for url: URL?) -> [CustomHTTPHeader]
}

/// The default of every initializer: no custom header, so existing tests never
/// read the keychain.
public struct NoCustomHeaders: CustomHeadersProviding {
    public init() {}
    public func headers(for url: URL?) -> [CustomHTTPHeader] { [] }
}

/// What the editor needs from the registry.
public protocol CustomHeadersEditing: AnyObject {
    func headers(for key: ServerKey) -> [CustomHTTPHeader]
    func save(_ headers: [CustomHTTPHeader], for key: ServerKey) throws
}

// MARK: - Keychain

public protocol CustomHeadersStoring: Sendable {
    func loadAll() throws -> [ServerKey: [CustomHTTPHeader]]
    func save(_ headers: [CustomHTTPHeader], for key: ServerKey) throws
    func remove(for key: ServerKey)
}

public enum CustomHeadersStoreError: Error, Equatable {
    case keychain(OSStatus)
    case encoding
}

/// One keychain item per server (`kSecAttrAccount` = `ServerKey.rawValue`), its
/// data the JSON of the list. Like `WidgetSessionStore`, no `kSecAttrAccessGroup`
/// is passed: the item lands in the first group of the entitlements, which the
/// app, the widgets and the extension share. `afterFirstUnlock` because Lock
/// Screen widgets refresh while the device is locked.
///
/// Neither a name nor a value is ever logged: only the `OSStatus`.
public struct KeychainCustomHeadersStore: CustomHeadersStoring {
    private let service: String
    private let logger = Logger(subsystem: "app.immich.swiftui", category: "custom-headers")

    public init(service: String = "app.immich.swiftui.headers") {
        self.service = service
    }

    public func loadAll() throws -> [ServerKey: [CustomHTTPHeader]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else {
            logger.error("custom headers read failed: \(status, privacy: .public)")
            throw CustomHeadersStoreError.keychain(status)
        }
        var all: [ServerKey: [CustomHTTPHeader]] = [:]
        for item in (result as? [[String: Any]]) ?? [] {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let headers = try? JSONDecoder().decode([CustomHTTPHeader].self, from: data),
                  let url = URL(string: "https://" + account),
                  let key = ServerKey(url: url), key.rawValue == account
            else { continue }
            all[key] = headers
        }
        return all
    }

    public func save(_ headers: [CustomHTTPHeader], for key: ServerKey) throws {
        if headers.isEmpty {
            remove(for: key)
            return
        }
        guard let data = try? JSONEncoder().encode(headers) else { throw CustomHeadersStoreError.encoding }
        remove(for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("custom headers save failed: \(status, privacy: .public)")
            throw CustomHeadersStoreError.keychain(status)
        }
    }

    public func remove(for key: ServerKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
