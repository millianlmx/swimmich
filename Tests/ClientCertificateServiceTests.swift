import XCTest
import Security
@testable import ImmichSwiftUI

/// What a certificate change sets in motion, and in which order.
final class ClientCertificateServiceTests: XCTestCase {
    private let server = URL(string: "https://photos.example.com")!
    private var key: ServerKey { ServerKey(url: server)! }

    private struct Rig {
        let service: ClientCertificateService
        let store: InMemoryClientIdentityStore
        let log: TLSChallengeLog
        let journal: TestJournal
    }

    private func makeRig() -> Rig {
        let store = InMemoryClientIdentityStore()
        let log = TLSChallengeLog()
        let journal = TestJournal()
        let service = ClientCertificateService(
            store: store,
            log: log,
            sessions: [FakeSessionRenewer(name: "client", journal: journal), FakeSessionRenewer(name: "sessions", journal: journal)],
            reconnectRealtime: { journal.append("realtime") },
            reloadWidgets: { journal.append("widgets") }
        )
        return Rig(service: service, store: store, log: log, journal: journal)
    }

    func test_AC_21_importKeepsTheIdentityThenRenewsEverything() async throws {
        let rig = makeRig()
        rig.log.noteClientCertificateMissing(key)

        try await rig.service.importCertificate(
            ClientCertificateFixtures.a, password: ClientCertificateFixtures.passwordA, for: server
        )

        XCTAssertTrue(rig.service.hasCertificate(for: server))
        XCTAssertTrue(rig.store.hasIdentity(for: key))
        XCTAssertEqual(rig.journal.entries, ["renew:client", "renew:sessions", "realtime", "widgets"])
        XCTAssertFalse(rig.log.clientCertificateWasMissing(for: key), "the log forgets the server after the renewal")
    }

    func test_AC_37_2_wrongPasswordTouchesNothing() async throws {
        let rig = makeRig()
        try rig.store.save(try ClientCertificateTestSupport.identityA(), for: key)

        do {
            try await rig.service.importCertificate(ClientCertificateFixtures.b, password: "not-bravo", for: server)
            XCTFail("a wrong password must refuse the import")
        } catch {
            XCTAssertEqual(error as? ClientIdentityImportError, .wrongPassword)
        }

        XCTAssertEqual(
            rig.store.identity(for: key).flatMap(ClientCertificateTestSupport.subject(of:)), "client-a",
            "A stays installed"
        )
        XCTAssertEqual(rig.journal.entries, [], "no session renewed, no reconnection, no widget reload")
    }

    func test_AC_37_2_correctPasswordReplacesTheCertificate() async throws {
        let rig = makeRig()
        try rig.store.save(try ClientCertificateTestSupport.identityA(), for: key)

        try await rig.service.importCertificate(
            ClientCertificateFixtures.b, password: ClientCertificateFixtures.passwordB, for: server
        )

        XCTAssertEqual(rig.store.identity(for: key).flatMap(ClientCertificateTestSupport.subject(of:)), "client-b")
        XCTAssertEqual(rig.journal.entries.count, 4)
    }

    func test_AC_37_2_keychainFailureStopsBeforeTheRenewal() async {
        let rig = makeRig()
        rig.store.failsOnSave = true

        do {
            try await rig.service.importCertificate(
                ClientCertificateFixtures.a, password: ClientCertificateFixtures.passwordA, for: server
            )
            XCTFail("a failing keychain must fail the import")
        } catch {
            XCTAssertEqual(error as? ClientIdentityStoreError, ClientIdentityStoreError(status: errSecIO))
        }

        XCTAssertFalse(rig.service.hasCertificate(for: server))
        XCTAssertEqual(rig.journal.entries, [])
    }

    func test_AC_37_2_fileWithoutKeyIsRefused() async {
        let rig = makeRig()
        do {
            try await rig.service.importCertificate(
                ClientCertificateFixtures.noKey, password: ClientCertificateFixtures.passwordA, for: server
            )
            XCTFail("a PKCS#12 without a private key is unusable")
        } catch {
            XCTAssertEqual(error as? ClientIdentityImportError, .unusableFile)
        }
        XCTAssertEqual(rig.journal.entries, [])
        XCTAssertFalse(rig.service.hasCertificate(for: server))
    }

    func test_AC_22_2_removeRenewsSessions() async throws {
        let rig = makeRig()
        try rig.store.save(try ClientCertificateTestSupport.identityA(), for: key)
        rig.log.noteClientCertificateMissing(key)

        try await rig.service.removeCertificate(for: server)

        XCTAssertFalse(rig.service.hasCertificate(for: server))
        XCTAssertEqual(rig.journal.entries, ["renew:client", "renew:sessions", "realtime", "widgets"])
        XCTAssertFalse(rig.log.clientCertificateWasMissing(for: key))
    }

    func test_AC_22_6_changeReconnectsRealtime() async throws {
        let rig = makeRig()

        try await rig.service.importCertificate(
            ClientCertificateFixtures.a, password: ClientCertificateFixtures.passwordA, for: server
        )
        try await rig.service.importCertificate(
            ClientCertificateFixtures.b, password: ClientCertificateFixtures.passwordB, for: server
        )
        try await rig.service.removeCertificate(for: server)

        XCTAssertEqual(rig.journal.entries.filter { $0 == "realtime" }.count, 3, "replace, then remove, reconnect each time")
    }

    func test_importingTheSameIdentityAgainSucceedsAndRenews() async throws {
        let rig = makeRig()
        for _ in 0..<2 {
            try await rig.service.importCertificate(
                ClientCertificateFixtures.a, password: ClientCertificateFixtures.passwordA, for: server
            )
        }
        XCTAssertEqual(rig.journal.entries.filter { $0 == "widgets" }.count, 2)
    }

    func test_aServerWithoutAHostIsRejected() async {
        let rig = makeRig()
        let nonServer = URL(fileURLWithPath: "/tmp/x")
        XCTAssertFalse(rig.service.hasCertificate(for: nonServer))
        do {
            try await rig.service.removeCertificate(for: nonServer)
            XCTFail("no server, no removal")
        } catch {
            XCTAssertEqual(error as? ClientCertificateServiceError, .invalidServer)
        }
    }
}
