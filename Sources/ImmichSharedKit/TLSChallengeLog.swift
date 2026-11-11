import Foundation

/// What the TLS delegates of this process saw (L-10): which server asked for a
/// client certificate that nobody could present, and which host's server trust
/// was refused. `URLSession` reports both as generic failures, so the delegates
/// leave a note here and the API client / server step read it back to tell
/// "certificate missing" or "untrusted server" from "unreachable".
///
/// Per process: the app, the widgets and the share extension each have their
/// own. A server that went from "certificate optional" to "required" while the
/// process lived keeps its "answered without a certificate" mark until the next
/// import, removal or launch; its failures then stay generic network errors.
public final class TLSChallengeLog: @unchecked Sendable {
    public static let shared = TLSChallengeLog()

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var missing: [ServerKey: Date] = [:]
    private var answeredWithoutCertificate: Set<ServerKey> = []
    private var trustRefused: [String: Date] = [:]

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// A client-certificate challenge was answered with no identity.
    public func noteClientCertificateMissing(_ key: ServerKey) {
        lock.lock(); defer { lock.unlock() }
        missing[key] = now()
    }

    /// A client-certificate challenge was answered with an identity.
    public func noteClientCertificatePresented(_ key: ServerKey) {
        lock.lock(); defer { lock.unlock() }
        missing[key] = nil
    }

    /// The certificate of `key` changed (import, removal): forget everything
    /// known about it.
    public func forget(_ key: ServerKey) {
        lock.lock(); defer { lock.unlock() }
        missing[key] = nil
        answeredWithoutCertificate.remove(key)
    }

    /// An HTTP response arrived from `key`. If a "missing" note younger than 30 s
    /// exists, the server answered without a certificate, so it does not require
    /// one: mark it, and never read its later cut connections as a missing
    /// certificate.
    public func noteServerAnswered(_ key: ServerKey) {
        lock.lock(); defer { lock.unlock() }
        if let date = missing[key], now().timeIntervalSince(date) < 30 {
            answeredWithoutCertificate.insert(key)
        }
    }

    public func clientCertificateWasMissing(for key: ServerKey, within: TimeInterval = 30) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !answeredWithoutCertificate.contains(key), let date = missing[key] else { return false }
        return now().timeIntervalSince(date) <= within
    }

    public func noteTrustRefused(host: String) {
        lock.lock(); defer { lock.unlock() }
        trustRefused[host.lowercased()] = now()
    }

    public func trustWasRefused(host: String, within: TimeInterval = 30) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let date = trustRefused[host.lowercased()] else { return false }
        return now().timeIntervalSince(date) <= within
    }
}
