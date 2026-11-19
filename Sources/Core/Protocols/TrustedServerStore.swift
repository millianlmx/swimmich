import Foundation

/// Persistent store of hosts the user explicitly trusts despite an
/// invalid/self-signed TLS certificate (P5 selfsigned-cert).
///
/// Trusting a host is trusting **one certificate**: the first handshake after
/// the user said yes pins the certificate the server presented
/// (`ServerCertificatePin`), and from then on only that certificate is accepted
/// for the host. A host that answers with another one is refused until the user
/// trusts it again (`add`), which forgets the old pin.
protocol TrustedServerStore: AnyObject {
    /// True when `host` (optionally with port) has been explicitly trusted.
    func contains(_ host: String) -> Bool
    /// Persists `host` as trusted and forgets the certificate pinned for it: the
    /// next handshake pins the one the server presents then.
    func add(_ host: String)
    /// The fingerprint pinned for `host`; nil when the host is not trusted or
    /// has not been reached since it was.
    func pin(for host: String) -> String?
    /// Pins `fingerprint` for a trusted host that has no pin yet. Returns the
    /// pin in force afterwards (the older one when there was one), nil when the
    /// host is not trusted.
    @discardableResult
    func pinIfAbsent(_ fingerprint: String, for host: String) -> String?
    /// Forgets every trusted host (voluntary logout wipes local data).
    func removeAll()
}
