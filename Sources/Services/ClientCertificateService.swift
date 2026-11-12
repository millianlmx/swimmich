import Foundation

/// Imports, replaces and removes the client certificate of a server, and makes
/// the change take effect everywhere (L-10).
///
/// After a change that reached the keychain, in this order:
/// 1. every `SessionRenewing` owner builds fresh sessions and invalidates the
///    old ones, so the next TLS handshake is a full one that asks for the
///    identity again (a resumed handshake would not);
/// 2. the challenge log forgets the server — after the renewal, so an answer
///    from a task cancelled by step 1 cannot mark the new situation;
/// 3. the realtime socket reconnects on the new session;
/// 4. the widget timelines reload (a widget that failed for want of a
///    certificate refreshes at once; widgets and the share extension read the
///    identity from the shared keychain group themselves).
///
/// A failure of the import or of the keychain write stops before step 1: the
/// previous state, certificate included, stays in place. The password only
/// lives in the arguments of `importCertificate`; nothing here keeps it, and the
/// app log is told to mask it (`appLog.learnSecret`) before the import runs.
final class ClientCertificateService: ClientCertificateManaging, @unchecked Sendable {
    private let store: any ClientIdentityStoring
    private let log: TLSChallengeLog
    private let sessions: [any SessionRenewing]
    private let reconnectRealtime: @MainActor () -> Void
    private let reloadWidgets: @Sendable () -> Void
    private let appLog: any AppLogSink

    init(
        store: any ClientIdentityStoring,
        log: TLSChallengeLog,
        sessions: [any SessionRenewing],
        reconnectRealtime: @escaping @MainActor () -> Void,
        reloadWidgets: @escaping @Sendable () -> Void,
        appLog: any AppLogSink = NoopAppLogSink()
    ) {
        self.store = store
        self.log = log
        self.sessions = sessions
        self.reconnectRealtime = reconnectRealtime
        self.reloadWidgets = reloadWidgets
        self.appLog = appLog
    }

    func hasCertificate(for serverURL: URL) -> Bool {
        guard let key = ServerKey(url: serverURL) else { return false }
        return store.hasIdentity(for: key)
    }

    func importCertificate(_ data: Data, password: String, for serverURL: URL) async throws {
        guard let key = ServerKey(url: serverURL) else { throw ClientCertificateServiceError.invalidServer }
        // Whether the import succeeds or not, the password must never reach a
        // log line: a failure's text may quote what was typed.
        appLog.learnSecret(password)
        let identity = try PKCS12Importer.identity(from: data, password: password)
        try store.save(identity, for: key)
        await applyChange(for: key)
    }

    func removeCertificate(for serverURL: URL) async throws {
        guard let key = ServerKey(url: serverURL) else { throw ClientCertificateServiceError.invalidServer }
        try store.remove(for: key)
        await applyChange(for: key)
    }

    private func applyChange(for key: ServerKey) async {
        for session in sessions { session.renewSessions() }
        log.forget(key)
        await reconnectRealtime()
        reloadWidgets()
    }
}
