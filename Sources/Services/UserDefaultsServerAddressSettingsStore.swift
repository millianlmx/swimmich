import Foundation
import ImmichSharedKit

/// UserDefaults-backed `ServerAddressSettingsStoring`: one JSON dictionary of
/// settings indexed by account id. Addresses and the switch are not secrets.
final class UserDefaultsServerAddressSettingsStore: ServerAddressSettingsStoring, @unchecked Sendable {
    static let defaultsKey = "serverAddressSettings"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func settings(for accountID: String) -> ServerAddressSettings {
        lock.lock()
        defer { lock.unlock() }
        return load()[accountID] ?? .empty
    }

    func save(_ settings: ServerAddressSettings, for accountID: String) {
        update { all in
            if settings == .empty { all.removeValue(forKey: accountID) } else { all[accountID] = settings }
        }
    }

    func remove(for accountID: String) {
        update { _ = $0.removeValue(forKey: accountID) }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func update(_ change: (inout [String: ServerAddressSettings]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        change(&all)
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// An unreadable value reads as no setting at all.
    private func load() -> [String: ServerAddressSettings] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let all = try? JSONDecoder().decode([String: ServerAddressSettings].self, from: data)
        else { return [:] }
        return all
    }
}
