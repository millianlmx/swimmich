import Foundation

/// Errors of `ClientCertificateManaging` besides `ClientIdentityImportError`
/// and `ClientIdentityStoreError`.
enum ClientCertificateServiceError: Error, Equatable {
    /// The server URL has no host (no `ServerKey`).
    case invalidServer
}

/// The client certificate of a server (TLS mutual authentication, L-10): one
/// per server (host + effective port), kept in the keychain, presented only to
/// that server.
protocol ClientCertificateManaging: AnyObject, Sendable {
    func hasCertificate(for serverURL: URL) -> Bool
    /// Reads the PKCS#12, keeps its identity for the server and makes every
    /// session present it. Any failure leaves the previous state untouched.
    func importCertificate(_ data: Data, password: String, for serverURL: URL) async throws
    func removeCertificate(for serverURL: URL) async throws
}
