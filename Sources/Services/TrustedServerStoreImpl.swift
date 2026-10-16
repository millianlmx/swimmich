import Foundation

/// UserDefaults-backed `TrustedServerStore` — hosts stored as a string set.
final class TrustedServerStoreImpl: TrustedServerStore, @unchecked Sendable {
    static let defaultsKey = "trustedServers"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func contains(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.load(from: defaults).contains(host)
    }

    func add(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        var hosts = Self.load(from: defaults)
        hosts.insert(host)
        defaults.set(Array(hosts), forKey: Self.defaultsKey)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }
}
