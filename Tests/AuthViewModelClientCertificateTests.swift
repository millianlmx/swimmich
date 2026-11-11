import XCTest
@testable import ImmichSwiftUI

/// The server step's reading of a failed check: unreachable, untrusted, or
/// "this server wants a client certificate".
@MainActor
final class AuthViewModelClientCertificateTests: XCTestCase {
    private struct Rig {
        let auth: AuthViewModel
        let mock: MockImmichClient
        let store: InMemoryClientIdentityStore
        let log: TLSChallengeLog
        let defaults: UserDefaults
        let suite: String
    }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func makeRig(url: String = "https://h.test") -> Rig {
        let suite = "AuthViewModelClientCertificateTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let mock = MockImmichClient()
        let store = InMemoryClientIdentityStore()
        let log = TLSChallengeLog()
        let auth = AuthViewModel(
            client: mock, keychain: MockKeychainStore(), defaults: defaults,
            challengeLog: log, identities: store
        )
        auth.serverURLString = url
        return Rig(auth: auth, mock: mock, store: store, log: log, defaults: defaults, suite: suite)
    }

    func test_AC_22_3_missingCertificateStatus() async {
        let rig = makeRig()
        rig.mock.pingError = APIError.clientCertificateRequired

        await rig.auth.connectServer()

        XCTAssertEqual(rig.auth.serverStatus, .clientCertificateRequired)
        XCTAssertEqual(rig.auth.errorMessage, UserFacingError.clientCertificateRequiredMessage)
        XCTAssertNil(rig.auth.pendingUntrustedHost)
    }

    func test_AC_22_3_aCutConnectionAfterAMissingNoteIsNamedToo() async {
        let rig = makeRig()
        rig.log.noteClientCertificateMissing(ClientCertificateTestSupport.key("https://h.test"))
        rig.mock.pingError = APIError.network(URLError(.secureConnectionFailed))

        await rig.auth.connectServer()

        XCTAssertEqual(rig.auth.serverStatus, .clientCertificateRequired)
    }

    func test_AC_22_3_plainNetworkFailureStaysUnreachable() async {
        let rig = makeRig()
        rig.log.noteClientCertificateMissing(ClientCertificateTestSupport.key("https://h.test"))
        rig.mock.pingError = APIError.network(URLError(.cannotConnectToHost))

        await rig.auth.connectServer()

        XCTAssertEqual(rig.auth.serverStatus, .unreachable)
        XCTAssertNil(rig.auth.pendingUntrustedHost)
    }

    func test_AC_21_2_wrappedTrustRefusalShowsAlert() async {
        let rig = makeRig()
        rig.log.noteTrustRefused(host: "h.test")
        rig.mock.pingError = APIError.network(URLError(.cancelled))

        await rig.auth.connectServer()

        XCTAssertEqual(rig.auth.serverStatus, .unreachable)
        XCTAssertEqual(rig.auth.pendingUntrustedHost, "h.test")
    }

    func test_AC_21_2_wrappedCertificateErrorShowsAlert() async {
        let rig = makeRig()
        rig.mock.pingError = APIError.network(URLError(.serverCertificateUntrusted))

        await rig.auth.connectServer()

        XCTAssertEqual(rig.auth.pendingUntrustedHost, "h.test")
    }

    func test_AC_21_2_aCancellationWithoutARefusalStaysUnreachable() async {
        let rig = makeRig()
        rig.mock.pingError = APIError.network(URLError(.cancelled))

        await rig.auth.connectServer()

        XCTAssertEqual(rig.auth.serverStatus, .unreachable)
        XCTAssertNil(rig.auth.pendingUntrustedHost)
    }

    func test_AC_21_2_aRefusalPrecedesTheMissingCertificate() async {
        let rig = makeRig()
        let key = ClientCertificateTestSupport.key("https://h.test")
        rig.log.noteClientCertificateMissing(key)
        rig.log.noteTrustRefused(host: "h.test")
        rig.mock.pingError = APIError.network(URLError(.cancelled))

        await rig.auth.connectServer()

        XCTAssertEqual(rig.auth.pendingUntrustedHost, "h.test", "the certificate is only asked for once the server is trusted")
        XCTAssertEqual(rig.auth.serverStatus, .unreachable)
    }

    func test_AC_21_1_certificateChangeRechecks() async throws {
        let rig = makeRig()
        XCTAssertFalse(rig.auth.serverHasClientCertificate)
        rig.mock.pingError = APIError.clientCertificateRequired
        await rig.auth.connectServer()
        XCTAssertEqual(rig.auth.serverStatus, .clientCertificateRequired)

        // The user imports the certificate; the server now answers.
        try rig.store.save(try ClientCertificateTestSupport.identityA(), for: ClientCertificateTestSupport.key("https://h.test"))
        rig.mock.pingError = nil
        await rig.auth.clientCertificateDidChange()

        XCTAssertTrue(rig.auth.serverHasClientCertificate)
        if case .reachable = rig.auth.serverStatus {} else {
            XCTFail("expected .reachable, got \(rig.auth.serverStatus)")
        }
    }

    func test_AC_21_1_installedStateFollowsTheTypedAddress() throws {
        let rig = makeRig(url: "https://h.test")
        try rig.store.save(try ClientCertificateTestSupport.identityA(), for: ClientCertificateTestSupport.key("https://h.test"))

        rig.auth.serverURLString = "https://h.test"
        XCTAssertTrue(rig.auth.serverHasClientCertificate)
        rig.auth.serverURLString = "H.test:443"
        XCTAssertTrue(rig.auth.serverHasClientCertificate, "the same server written another way")
        rig.auth.serverURLString = "https://h.test:8443"
        XCTAssertFalse(rig.auth.serverHasClientCertificate, "another port is another server")
        rig.auth.serverURLString = ""
        XCTAssertFalse(rig.auth.serverHasClientCertificate)
    }

    func test_AC_22_2_logoutKeepsTheCertificate() async throws {
        let rig = makeRig()
        let key = ClientCertificateTestSupport.key("https://h.test")
        try rig.store.save(try ClientCertificateTestSupport.identityA(), for: key)

        await rig.auth.logout()

        XCTAssertTrue(rig.store.hasIdentity(for: key), "only « Remove » deletes a certificate")
    }
}
