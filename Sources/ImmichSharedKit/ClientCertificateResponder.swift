import Foundation

/// Answers `NSURLAuthenticationMethodClientCertificate` challenges with the
/// identity attached to the challenging server (host + effective port), and
/// with nothing for any other server (L-10).
///
/// The identity is read from the keychain at every challenge and never kept. A
/// resumed TLS handshake raises no challenge at all: that is why a certificate
/// change replaces the app's sessions (`SessionRenewing`) instead of relying on
/// this lookup alone.
public struct ClientCertificateResponder: Sendable {
    private let store: any ClientIdentityStoring
    private let log: TLSChallengeLog
    private let canonicalKey: @Sendable (ServerKey) -> ServerKey

    /// `canonicalKey` maps an alias of the server (its local address) to the key
    /// the identity was saved under (L-26); the log keeps the key of the request.
    public init(
        store: any ClientIdentityStoring, log: TLSChallengeLog,
        canonicalKey: @escaping @Sendable (ServerKey) -> ServerKey = { $0 }
    ) {
        self.store = store
        self.log = log
        self.canonicalKey = canonicalKey
    }

    public static let live = ClientCertificateResponder(store: KeychainClientIdentityStore(), log: .shared)

    /// Nil for any other kind of challenge: the caller keeps its own handling.
    public func answer(
        _ challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            return nil
        }
        let key = ServerKey(protectionSpace: challenge.protectionSpace)
        guard let identity = store.identity(for: canonicalKey(key)) else {
            log.noteClientCertificateMissing(key)
            return (.performDefaultHandling, nil)
        }
        log.noteClientCertificatePresented(key)
        return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .none))
    }
}
