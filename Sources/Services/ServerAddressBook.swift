import Foundation
import ImmichSharedKit

/// The in-memory answer to "is this address one of the active account's?" (L-26).
///
/// A server has one identity in the app (its connection address, `accountURL`)
/// and up to two addresses it is reached at (the external one and the local
/// one). Custom headers, the client certificate and the image cache are kept
/// under the identity: the book maps either address back to it, so a request to
/// `http://192.168.1.10:2283` finds what was saved for `https://photos.example.org`.
///
/// Read from every request thread (thumbnails), hence the lock. `shared` is the
/// process-wide book the app's registry, responder and image cache read.
final class ServerAddressBook: @unchecked Sendable {
    static let shared = ServerAddressBook()

    private let lock = NSLock()
    private var _accountURL: URL?
    private var _addresses: [URL] = []
    private var _activeURL: URL?

    init() {}

    func update(accountURL: URL?, addresses: [URL], activeURL: URL?) {
        lock.lock()
        defer { lock.unlock() }
        _accountURL = accountURL
        _addresses = addresses
        _activeURL = activeURL
    }

    var accountURL: URL? { locked { _accountURL } }
    var activeURL: URL? { locked { _activeURL } }

    func clear() { update(accountURL: nil, addresses: [], activeURL: nil) }

    /// The key of the connection address when `key` is the key of one of the
    /// declared addresses; `key` itself otherwise.
    func canonicalKey(for key: ServerKey) -> ServerKey {
        let (account, addresses) = locked { (_accountURL, _addresses) }
        guard let account, let accountKey = ServerKey(url: account),
              addresses.contains(where: { ServerKey(url: $0) == key })
        else { return key }
        return accountKey
    }

    /// `url` with the origin of a declared address replaced by the connection
    /// address's, path and query kept. Scheme, host (case ignored), effective
    /// port and path prefix must all match: `http://nas/` is not `https://nas/`.
    func canonicalURL(for url: URL) -> URL {
        let (account, addresses) = locked { (_accountURL, _addresses) }
        guard let account, !addresses.isEmpty,
              let target = Self.components(of: url)
        else { return url }
        for address in addresses {
            guard let base = Self.components(of: address),
                  base.scheme == target.scheme, base.host == target.host, base.port == target.port,
                  Self.hasPathPrefix(target.path, base.path)
            else { continue }
            if address.absoluteString == account.absoluteString { return url }
            let rest = String(target.path.dropFirst(base.path.count))
            guard var out = URLComponents(url: account, resolvingAgainstBaseURL: false) else { return url }
            let accountPath = out.path.hasSuffix("/") ? String(out.path.dropLast()) : out.path
            out.path = accountPath + rest
            out.percentEncodedQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
            return out.url ?? url
        }
        return url
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private struct Parts { let scheme: String; let host: String; let port: Int; let path: String }

    private static func components(of url: URL) -> Parts? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        return Parts(scheme: scheme, host: host, port: url.port ?? (scheme == "https" ? 443 : 80), path: path)
    }

    private static func hasPathPrefix(_ path: String, _ prefix: String) -> Bool {
        prefix.isEmpty || path == prefix || path.hasPrefix(prefix + "/")
    }
}
