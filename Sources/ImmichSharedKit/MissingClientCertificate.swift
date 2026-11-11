import Foundation

/// Decides whether a transport failure means "this server wants a client
/// certificate and none is installed for it" (L-10).
///
/// Closed list of codes: -1206 always; -1200, -1205 and -1005 only when a
/// challenge was recently answered without an identity AND the server has not
/// answered without one since (a server that asks for a certificate without
/// requiring it notes "missing" on every handshake). Everything else — timeout,
/// refused connection, DNS, cancellation, offline — is a plain network error.
public enum MissingClientCertificate {
    public static func matches(_ error: URLError, url: URL?, log: TLSChallengeLog) -> Bool {
        switch error.code {
        case .clientCertificateRequired:
            return true
        case .secureConnectionFailed, .clientCertificateRejected, .networkConnectionLost:
            guard let url, let key = ServerKey(url: url) else { return false }
            return log.clientCertificateWasMissing(for: key)
        default:
            return false
        }
    }
}
