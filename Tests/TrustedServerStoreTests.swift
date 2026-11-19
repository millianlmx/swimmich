import XCTest
@testable import ImmichSwiftUI

final class TrustedServerStoreTests: XCTestCase {

    private func makeIsolatedStore() -> (TrustedServerStoreImpl, UserDefaults, String) {
        let suite = "trustStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (TrustedServerStoreImpl(defaults: defaults), defaults, suite)
    }

    func test_contains_emptyIsFalse() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(store.contains("photos.example.com"))
    }

    func test_add_thenContains() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.add("photos.example.com")
        XCTAssertTrue(store.contains("photos.example.com"))
        XCTAssertFalse(store.contains("other.example.com"))
    }

    func test_add_persistsAcrossInstances() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.add("192.168.1.10:2283")

        let reloaded = TrustedServerStoreImpl(defaults: defaults)
        XCTAssertTrue(reloaded.contains("192.168.1.10:2283"))
    }

    func test_add_isIdempotent() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.add("a.example.com")
        store.add("a.example.com")
        XCTAssertEqual(defaults.stringArray(forKey: TrustedServerStoreImpl.defaultsKey)?.count, 1)
    }

    // MARK: - Certificate pins

    func test_pin_isNilUntilLearned_thenKept() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.add("nas.local")
        XCTAssertNil(store.pin(for: "nas.local"))

        XCTAssertEqual(store.pinIfAbsent("aa", for: "nas.local"), "aa")
        XCTAssertEqual(store.pin(for: "nas.local"), "aa")
        XCTAssertEqual(store.pinIfAbsent("bb", for: "nas.local"), "aa", "a pin is never replaced by a handshake")
        XCTAssertEqual(TrustedServerStoreImpl(defaults: defaults).pin(for: "nas.local"), "aa")
    }

    func test_pin_isNeverRecordedForAHostTheUserDidNotTrust() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(store.pinIfAbsent("aa", for: "evil.example"))
        XCTAssertNil(store.pin(for: "evil.example"))
        XCTAssertFalse(store.contains("evil.example"))
    }

    func test_add_forgetsThePin_soTheNextHandshakePinsAgain() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.add("nas.local")
        store.pinIfAbsent("aa", for: "nas.local")

        store.add("nas.local")

        XCTAssertTrue(store.contains("nas.local"))
        XCTAssertNil(store.pin(for: "nas.local"))
        XCTAssertEqual(store.pinIfAbsent("bb", for: "nas.local"), "bb")
    }

    func test_removeAll_forgetsHostsAndPins() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.add("nas.local")
        store.pinIfAbsent("aa", for: "nas.local")

        store.removeAll()
        store.add("nas.local")

        XCTAssertNil(store.pin(for: "nas.local"))
    }

    func test_onPinLearned_firesOncePerNewPin() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let count = PinLearnedCounter()
        store.onPinLearned = { count.increment() }
        store.add("nas.local")

        store.pinIfAbsent("aa", for: "nas.local")
        store.pinIfAbsent("bb", for: "nas.local")
        store.pinIfAbsent("cc", for: "evil.example")

        XCTAssertEqual(count.value, 1)
    }
}

private final class PinLearnedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
