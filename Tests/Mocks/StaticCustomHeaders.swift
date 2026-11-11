import Foundation
@testable import ImmichSwiftUI

/// A `CustomHeadersProviding` with fixed lists per server, so a test never
/// reads the keychain. Resolves by `ServerKey`, like the real registry.
struct StaticCustomHeaders: CustomHeadersProviding {
    var byServer: [ServerKey: [CustomHTTPHeader]]

    init(_ byServer: [ServerKey: [CustomHTTPHeader]] = [:]) {
        self.byServer = byServer
    }

    /// One list for the server `url` points at.
    init(_ headers: [CustomHTTPHeader], for url: String) {
        let key = URL(string: url).flatMap(ServerKey.init(url:))
        self.byServer = key.map { [$0: headers] } ?? [:]
    }

    func headers(for url: URL?) -> [CustomHTTPHeader] {
        guard let url, let key = ServerKey(url: url) else { return [] }
        return byServer[key] ?? []
    }

    static let xAccess = CustomHTTPHeader(name: "X-Access", value: "secret")
    static let basic = CustomHTTPHeader(name: "Authorization", value: "Basic dXNlcjpwYXNz")
}

/// A keychain double. `failLoads` / `failSaves` count down the failures to
/// inject; `loadCount` lets a test prove the registry reads once.
final class InMemoryCustomHeadersStore: CustomHeadersStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [ServerKey: [CustomHTTPHeader]]
    private var _loadCount = 0
    private var _failLoads: Int
    var failSaves = false

    struct Refused: Error {}

    init(_ lists: [ServerKey: [CustomHTTPHeader]] = [:], failLoads: Int = 0) {
        self.lists = lists
        self._failLoads = failLoads
    }

    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return _loadCount }
    var stored: [ServerKey: [CustomHTTPHeader]] { lock.lock(); defer { lock.unlock() }; return lists }

    func loadAll() throws -> [ServerKey: [CustomHTTPHeader]] {
        lock.lock(); defer { lock.unlock() }
        _loadCount += 1
        if _failLoads > 0 { _failLoads -= 1; throw Refused() }
        return lists
    }

    func save(_ headers: [CustomHTTPHeader], for key: ServerKey) throws {
        lock.lock(); defer { lock.unlock() }
        if failSaves { throw Refused() }
        lists[key] = headers.isEmpty ? nil : headers
    }

    func remove(for key: ServerKey) {
        lock.lock(); defer { lock.unlock() }
        lists[key] = nil
    }
}

extension ServerKey {
    /// Test convenience: the key of an address that is known to be valid.
    static func of(_ address: String) -> ServerKey {
        ServerKey(url: URL(string: address)!)!
    }
}
