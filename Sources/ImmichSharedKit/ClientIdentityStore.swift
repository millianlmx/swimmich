import CryptoKit
import Foundation
import Security
import os

/// A keychain failure while keeping or removing a client identity.
public struct ClientIdentityStoreError: Error, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}

/// Where the client certificate of each server lives (L-10).
public protocol ClientIdentityStoring: Sendable {
    func identity(for key: ServerKey) -> SecIdentity?
    func hasIdentity(for key: ServerKey) -> Bool
    func save(_ identity: SecIdentity, for key: ServerKey) throws
    func remove(for key: ServerKey) throws
    func removeAll() throws
}

/// Keychain-backed store, shared by the app, the widgets and the share
/// extension through the same default access group `WidgetSessionStore` uses
/// (no `kSecAttrAccessGroup` is passed on purpose).
///
/// Layout: the identity is added once (`kSecValueRef`), and one generic-password
/// item per server (`service`, account `host:port`) maps the server to the
/// SHA-256 of the certificate's DER. A certificate shared by two servers is one
/// identity and two mappings. Both items are `afterFirstUnlockThisDeviceOnly`,
/// so a widget refreshing on a locked device can still read them.
public struct KeychainClientIdentityStore: ClientIdentityStoring {
    private let service: String
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "app.immich.swiftui", category: "client-identity")

    public init(service: String = "app.immich.swiftui.client-identity") {
        self.service = service
    }

    // MARK: Reading

    public func hasIdentity(for key: ServerKey) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let stored = fingerprint(for: key) else { return false }
        return storedIdentity(for: stored) != nil
    }

    public func identity(for key: ServerKey) -> SecIdentity? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let stored = fingerprint(for: key) else { return nil }
        return storedIdentity(for: stored)
    }

    // MARK: Writing

    public func save(_ identity: SecIdentity, for key: ServerKey) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let newPrint = Self.fingerprint(of: identity) else {
            throw ClientIdentityStoreError(status: errSecDecode)
        }
        let previousPrint = fingerprint(for: key)

        // 1. The identity itself; already there is fine.
        let addIdentity: [String: Any] = [
            kSecValueRef as String: identity,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(addIdentity as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            Self.logger.error("client identity add failed: \(addStatus, privacy: .public)")
            throw ClientIdentityStoreError(status: addStatus)
        }

        // 2. The mapping, updated in place so a failure leaves the old one.
        let mappingStatus = writeMapping(newPrint, for: key)
        guard mappingStatus == errSecSuccess else {
            Self.logger.error("client identity mapping failed: \(mappingStatus, privacy: .public)")
            if addStatus == errSecSuccess, !references(newPrint) {
                deleteIdentity(fingerprint: newPrint)
            }
            throw ClientIdentityStoreError(status: mappingStatus)
        }

        // 3. The identity this server used to have, if nobody else uses it.
        if let previousPrint, previousPrint != newPrint, !references(previousPrint) {
            deleteIdentity(fingerprint: previousPrint)
        }
    }

    public func remove(for key: ServerKey) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let previousPrint = fingerprint(for: key) else { return }
        let status = SecItemDelete(mappingQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Self.logger.error("client identity mapping delete failed: \(status, privacy: .public)")
            throw ClientIdentityStoreError(status: status)
        }
        if !references(previousPrint) {
            deleteIdentity(fingerprint: previousPrint)
        }
    }

    public func removeAll() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let prints = Set(allMappings().map(\.fingerprint))
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClientIdentityStoreError(status: status)
        }
        for stored in prints { deleteIdentity(fingerprint: stored) }
    }

    // MARK: Mapping items

    private func mappingQuery(for key: ServerKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
    }

    private func fingerprint(for key: ServerKey) -> String? {
        var query = mappingQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeMapping(_ fingerprint: String, for key: ServerKey) -> OSStatus {
        let data = Data(fingerprint.utf8)
        let update = SecItemUpdate(
            mappingQuery(for: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return errSecSuccess }
        guard update == errSecItemNotFound else { return update }
        var item = mappingQuery(for: key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }

    private func allMappings() -> [(account: String, fingerprint: String)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let stored = String(data: data, encoding: .utf8)
            else { return nil }
            return (account, stored)
        }
    }

    /// Whether any server still maps to `fingerprint`.
    private func references(_ fingerprint: String) -> Bool {
        allMappings().contains { $0.fingerprint == fingerprint }
    }

    // MARK: Identity items

    private func allIdentities() -> [SecIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        if let array = result as? [AnyObject] {
            return array.compactMap { object in
                CFGetTypeID(object) == SecIdentityGetTypeID() ? (object as! SecIdentity) : nil // swiftlint:disable:this force_cast
            }
        }
        if let object = result, CFGetTypeID(object) == SecIdentityGetTypeID() {
            return [object as! SecIdentity] // swiftlint:disable:this force_cast
        }
        return []
    }

    private func storedIdentity(for fingerprint: String) -> SecIdentity? {
        allIdentities().first { Self.fingerprint(of: $0) == fingerprint }
    }

    private func deleteIdentity(fingerprint: String) {
        guard let identity = storedIdentity(for: fingerprint) else { return }
        let status = SecItemDelete([
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
        ] as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.error("client identity delete failed: \(status, privacy: .public)")
        }
    }

    /// SHA-256 of the certificate's DER, lowercase hex.
    static func fingerprint(of identity: SecIdentity) -> String? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
