import Foundation

/// Persistent store of hosts the user explicitly trusts despite an
/// invalid/self-signed TLS certificate (P5 selfsigned-cert).
protocol TrustedServerStore: AnyObject {
    /// True when `host` (optionally with port) has been explicitly trusted.
    func contains(_ host: String) -> Bool
    /// Persists `host` as trusted.
    func add(_ host: String)
    /// Forgets every trusted host (voluntary logout wipes local data).
    func removeAll()
}
