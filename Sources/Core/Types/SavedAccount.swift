import CryptoKit
import Foundation

/// A persisted account (server URL + user identity) for the multi-server /
/// multi-account switcher (P5 multi-server).
///
/// The account `id` keys the per-account bearer token in the Keychain and
/// includes the email so several accounts on the SAME server coexist
/// (e.g. a shared family instance).
struct SavedAccount: Codable, Identifiable, Hashable, Equatable {
    let url: String
    let email: String?
    let name: String?
    let userId: String?
    let isAdmin: Bool

    var id: String { Self.makeID(url: url, email: email, userId: userId) }

    /// Stable identity used both as `Identifiable.id` and as the Keychain key.
    static func makeID(url: String, email: String?, userId: String?) -> String {
        "\(url)|\(email ?? userId ?? "")"
    }

    /// Name under which per-account data lives on disk (map cache, offline
    /// copies): lowercase hex SHA-256 of the UTF-8 `id`. `id` holds `/`, `:`
    /// and `|`, so it can't be a path component itself; the digest is stable
    /// across launches and distinct per account.
    static func storageKey(forID id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
