import Foundation
import Security

/// URLSession delegate that accepts a self-signed/invalid TLS certificate for
/// hosts the user has explicitly trusted (P5 selfsigned-cert).
///
/// Flow per serverTrust challenge:
/// 1. Standard evaluation (`SecTrustEvaluateWithError`) — trusted chains pass.
/// 2. On failure, if the host is in `TrustedServerStore`, the chain is evaluated
///    against the certificate pinned for that host (`ServerCertificatePin`). A
///    trusted host with no pin yet (just trusted, or trusted by an earlier
///    build) pins the certificate it presents now. Trust is given to a
///    certificate, never to a host name: anyone can present a self-signed
///    certificate for a name.
/// 3. Anything else → cancel the challenge.
final class TrustEvaluatingURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let trustStore: TrustedServerStore
    private let clientCertificates: ClientCertificateResponder
    private let log: TLSChallengeLog

    init(
        trustStore: TrustedServerStore,
        clientCertificates: ClientCertificateResponder = .live,
        log: TLSChallengeLog = .shared
    ) {
        self.trustStore = trustStore
        self.clientCertificates = clientCertificates
        self.log = log
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // A TLS client certificate request (L-10) comes before the server-trust
        // rule; the trust rule itself is unchanged.
        if let (disposition, credential) = clientCertificates.answer(challenge) {
            completionHandler(disposition, credential)
            return
        }

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Step 1: default evaluation.
        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        // Step 2: explicit user trust — only for the certificate pinned to the host.
        let host = challenge.protectionSpace.host
        guard trustStore.contains(host), Self.passesPin(serverTrust, host: host, store: trustStore) else {
            log.noteTrustRefused(host: host)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    /// Whether the chain of `trust` verifies against the certificate pinned for
    /// `host`. Without a pin, the certificate presented becomes the pin once the
    /// chain verifies against it.
    private static func passesPin(_ trust: SecTrust, host: String, store: TrustedServerStore) -> Bool {
        if let pin = store.pin(for: host) {
            return ServerCertificatePin.evaluate(trust, pinnedTo: pin)
        }
        guard let candidate = ServerCertificatePin.candidate(in: trust),
              ServerCertificatePin.evaluate(trust, pinnedTo: candidate)
        else { return false }
        // Another handshake may have pinned a certificate meanwhile: its pin wins.
        return store.pinIfAbsent(candidate, for: host) == candidate
    }
}
