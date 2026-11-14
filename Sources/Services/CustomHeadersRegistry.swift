import Foundation
import os

/// The app's in-memory copy of every server's custom headers.
///
/// Requests read it hundreds of times a second (thumbnails), so the keychain is
/// read ONCE, at the first access, never per request. A modification writes the
/// keychain first and updates memory only when that succeeded.
///
/// If the first read fails (the device was locked since boot, so the keychain
/// refuses), the registry behaves as empty for that call and tries again at the
/// next access.
final class CustomHeadersRegistry: CustomHeadersProviding, CustomHeadersEditing, @unchecked Sendable {
    static let shared = CustomHeadersRegistry(store: KeychainCustomHeadersStore())

    private let store: any CustomHeadersStoring
    private let lock = NSLock()
    private var lists: [ServerKey: [CustomHTTPHeader]] = [:]
    private var loaded = false
    private let notificationCenter: NotificationCenter
    /// Maps a declared local or external address back to the account's own key (L-26).
    private let addressBook: ServerAddressBook

    init(
        store: any CustomHeadersStoring, notificationCenter: NotificationCenter = .default,
        addressBook: ServerAddressBook = .shared
    ) {
        self.store = store
        self.notificationCenter = notificationCenter
        self.addressBook = addressBook
    }

    func headers(for url: URL?) -> [CustomHTTPHeader] {
        guard let url, let key = ServerKey(url: url) else { return [] }
        return headers(for: addressBook.canonicalKey(for: key))
    }

    func headers(for key: ServerKey) -> [CustomHTTPHeader] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return lists[key] ?? []
    }
    func save(_ headers: [CustomHTTPHeader], for key: ServerKey) throws {
        try withLock {
            // A save after a failed first read reloads first, so the other
            // servers' lists are not lost from memory.
            loadIfNeeded()
            try store.save(headers, for: key)
            lists[key] = headers.isEmpty ? nil : headers
        }
        // Outside the lock: an observer may read the registry synchronously.
        notificationCenter.post(
            name: .immichCustomHeadersChanged, object: nil,
            userInfo: ["serverKey": key.rawValue]
        )
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Caller holds the lock.
    private func loadIfNeeded() {
        guard !loaded else { return }
        if let all = try? store.loadAll() {
            lists = all
            loaded = true
        }
    }
}
