import XCTest
import Security
@testable import ImmichSwiftUI

/// The keychain-backed identity store, against the real keychain of the test
/// host (a service of its own per test; everything it added is removed in
/// `tearDown`).
final class KeychainClientIdentityStoreTests: XCTestCase {
    private var service = ""
    private var store: KeychainClientIdentityStore!

    private let h1 = ClientCertificateTestSupport.key("https://h1.test")
    private let h2 = ClientCertificateTestSupport.key("https://h2.test")

    override func setUp() {
        super.setUp()
        service = "app.immich.swiftui.client-identity.tests.\(UUID().uuidString)"
        store = KeychainClientIdentityStore(service: service)
    }

    override func tearDown() {
        try? store.removeAll()
        super.tearDown()
    }

    /// Common names of every identity currently in the keychain.
    private func storedSubjects() -> [String] {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let array = result as? [AnyObject] else { return [] }
        return array.compactMap { object in
            guard CFGetTypeID(object) == SecIdentityGetTypeID() else { return nil }
            return ClientCertificateTestSupport.subject(of: object as! SecIdentity) // swiftlint:disable:this force_cast
        }
    }

    func test_AC_21_saveThenReadBackPerServer() throws {
        try store.save(try ClientCertificateTestSupport.identityA(), for: h1)

        XCTAssertTrue(store.hasIdentity(for: h1))
        XCTAssertEqual(store.identity(for: h1).flatMap(ClientCertificateTestSupport.subject(of:)), "client-a")
        XCTAssertFalse(store.hasIdentity(for: h2), "a certificate belongs to one server")
        XCTAssertNil(store.identity(for: h2))
    }

    func test_AC_22_removeForgetsTheServerAndItsIdentity() throws {
        try store.save(try ClientCertificateTestSupport.identityA(), for: h1)
        try store.remove(for: h1)

        XCTAssertFalse(store.hasIdentity(for: h1))
        XCTAssertFalse(storedSubjects().contains("client-a"), "an identity nobody references is deleted")
        XCTAssertNoThrow(try store.remove(for: h1), "removing what is not there is not an error")
    }

    func test_AC_22_sameCertificateOnTwoServersSurvivesTheRemovalOfOne() throws {
        let identity = try ClientCertificateTestSupport.identityA()
        try store.save(identity, for: h1)
        try store.save(identity, for: h2)

        try store.remove(for: h1)
        XCTAssertFalse(store.hasIdentity(for: h1))
        XCTAssertTrue(store.hasIdentity(for: h2))

        try store.remove(for: h2)
        XCTAssertFalse(store.hasIdentity(for: h2))
        XCTAssertFalse(storedSubjects().contains("client-a"))
    }

    func test_AC_37_2_replaceRemovesUnreferencedIdentity() throws {
        try store.save(try ClientCertificateTestSupport.identityA(), for: h1)
        try store.save(try ClientCertificateTestSupport.identityB(), for: h1)

        XCTAssertEqual(store.identity(for: h1).flatMap(ClientCertificateTestSupport.subject(of:)), "client-b")
        XCTAssertFalse(storedSubjects().contains("client-a"), "A is no longer referenced by any server")
        XCTAssertTrue(storedSubjects().contains("client-b"))
    }

    func test_AC_37_2_replacementKeepsAnIdentityAnotherServerStillUses() throws {
        let a = try ClientCertificateTestSupport.identityA()
        try store.save(a, for: h1)
        try store.save(a, for: h2)
        try store.save(try ClientCertificateTestSupport.identityB(), for: h1)

        XCTAssertEqual(store.identity(for: h2).flatMap(ClientCertificateTestSupport.subject(of:)), "client-a")
        XCTAssertEqual(store.identity(for: h1).flatMap(ClientCertificateTestSupport.subject(of:)), "client-b")
    }

    func test_AC_22_removeAllEmptiesEveryServer() throws {
        try store.save(try ClientCertificateTestSupport.identityA(), for: h1)
        try store.save(try ClientCertificateTestSupport.identityB(), for: h2)

        try store.removeAll()

        XCTAssertFalse(store.hasIdentity(for: h1))
        XCTAssertFalse(store.hasIdentity(for: h2))
    }

    /// Widgets refresh while the device is locked: both items must be readable
    /// after the first unlock, and never leave the device.
    func test_AC_21_4_itemsAreAfterFirstUnlockThisDeviceOnly() throws {
        try store.save(try ClientCertificateTestSupport.identityA(), for: h1)

        var mapping: AnyObject?
        XCTAssertEqual(SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: h1.account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &mapping), errSecSuccess)
        let mappingAttributes = try XCTUnwrap(mapping as? [String: Any])
        XCTAssertEqual(
            mappingAttributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )

        var identities: AnyObject?
        XCTAssertEqual(SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &identities), errSecSuccess)
        let attributes = try XCTUnwrap(identities as? [[String: Any]])
        XCTAssertTrue(attributes.contains {
            ($0[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        })
    }
}
