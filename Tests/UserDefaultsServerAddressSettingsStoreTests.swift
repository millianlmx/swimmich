import XCTest
@testable import ImmichSwiftUI

final class UserDefaultsServerAddressSettingsStoreTests: XCTestCase {
    private func makeStore() -> (UserDefaultsServerAddressSettingsStore, UserDefaults, String) {
        let suite = "serverAddressStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (UserDefaultsServerAddressSettingsStore(defaults: defaults), defaults, suite)
    }

    func test_AC_244_roundTripAndIsolationBetweenAccounts() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ServerAddressSettings(localURL: "http://192.168.1.10:2283", externalURL: "https://a.example.org",
                                          autoSwitch: true, lastKnownVersion: "1.119.0")
        store.save(first, for: "https://a|me")

        XCTAssertEqual(store.settings(for: "https://a|me"), first)
        XCTAssertEqual(store.settings(for: "https://b|me"), .empty)
        XCTAssertEqual(UserDefaultsServerAddressSettingsStore(defaults: defaults).settings(for: "https://a|me"), first)

        store.remove(for: "https://a|me")
        XCTAssertEqual(store.settings(for: "https://a|me"), .empty)
    }

    func test_AC_243_emptySettingsRemoveTheEntryAndRemoveAllClears() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.save(ServerAddressSettings(autoSwitch: true), for: "a")
        store.save(ServerAddressSettings(autoSwitch: true), for: "b")
        store.save(.empty, for: "a")
        let stored = try JSONDecoder().decode(
            [String: ServerAddressSettings].self,
            from: XCTUnwrap(defaults.data(forKey: UserDefaultsServerAddressSettingsStore.defaultsKey))
        )
        XCTAssertEqual(Set(stored.keys), ["b"])

        store.removeAll()
        XCTAssertEqual(store.settings(for: "b"), .empty)
    }

    func test_AC_244_unreadableJSONReadsAsEmptyAndIsReplacedOnSave() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: UserDefaultsServerAddressSettingsStore.defaultsKey)
        XCTAssertEqual(store.settings(for: "a"), .empty)

        store.save(ServerAddressSettings(autoSwitch: true), for: "a")
        XCTAssertTrue(store.settings(for: "a").autoSwitch)
    }
}
