import XCTest
@testable import ImmichSwiftUI

/// Which server gets the client certificate, and what the challenge log learns.
final class ClientCertificateResponderTests: XCTestCase {
    private func makeResponder(
        attachedTo url: String
    ) throws -> (ClientCertificateResponder, TLSChallengeLog) {
        let store = InMemoryClientIdentityStore()
        try store.save(try ClientCertificateTestSupport.identityA(), for: ClientCertificateTestSupport.key(url))
        let log = TLSChallengeLog()
        return (ClientCertificateResponder(store: store, log: log), log)
    }

    func test_AC_22_5_matchesByEffectivePort() throws {
        let (responder, log) = try makeResponder(attachedTo: "https://h")

        for host in ["h", "H"] {
            let answer = try XCTUnwrap(responder.answer(
                ClientCertificateTestSupport.clientCertificateChallenge(host: host, port: 443)
            ))
            XCTAssertEqual(answer.0, .useCredential, host)
            XCTAssertNotNil(answer.1?.identity, host)
            XCTAssertEqual(answer.1?.persistence, URLCredential.Persistence.none)
        }
        XCTAssertFalse(log.clientCertificateWasMissing(for: ClientCertificateTestSupport.key("https://h")))

        let plain = try XCTUnwrap(responder.answer(
            ClientCertificateTestSupport.clientCertificateChallenge(host: "h", port: 80, protocolName: NSURLProtectionSpaceHTTP)
        ))
        XCTAssertEqual(plain.0, .performDefaultHandling, "http://h is another server (port 80)")
        XCTAssertNil(plain.1)
    }

    func test_AC_22_4_otherHostGetsNothing() throws {
        let (responder, log) = try makeResponder(attachedTo: "https://h")

        for (host, port) in [("h", 8443), ("other.test", 443)] {
            let answer = try XCTUnwrap(responder.answer(
                ClientCertificateTestSupport.clientCertificateChallenge(host: host, port: port)
            ))
            XCTAssertEqual(answer.0, .performDefaultHandling, "\(host):\(port)")
            XCTAssertNil(answer.1, "\(host):\(port) must not be offered the certificate of h:443")
            XCTAssertTrue(
                log.clientCertificateWasMissing(for: ClientCertificateTestSupport.key("https://\(host):\(port)")),
                "the refusal is noted so the failure can be named"
            )
        }
    }

    func test_AC_21_presentingClearsTheMissingNote() throws {
        let (responder, log) = try makeResponder(attachedTo: "https://h")
        let key = ClientCertificateTestSupport.key("https://h")
        log.noteClientCertificateMissing(key)

        _ = responder.answer(ClientCertificateTestSupport.clientCertificateChallenge(host: "h", port: 443))

        XCTAssertFalse(log.clientCertificateWasMissing(for: key))
    }

    func test_otherAuthenticationMethodsAreLeftToTheCaller() throws {
        let (responder, _) = try makeResponder(attachedTo: "https://h")
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPBasic] {
            XCTAssertNil(responder.answer(ClientCertificateTestSupport.challenge(method: method, host: "h", port: 443)), method)
        }
    }

    func test_AC_241_aliasPresentsAccountIdentity() throws {
        let account = URL(string: "https://photos.example.org")!
        let local = URL(string: "http://192.168.1.10:2283")!
        let store = InMemoryClientIdentityStore()
        try store.save(try ClientCertificateTestSupport.identityA(), for: ClientCertificateTestSupport.key(account.absoluteString))
        let book = ServerAddressBook()
        book.update(accountURL: account, addresses: [account, local], activeURL: local)
        let log = TLSChallengeLog()
        let responder = ClientCertificateResponder(store: store, log: log, canonicalKey: { book.canonicalKey(for: $0) })
        let localKey = ClientCertificateTestSupport.key(local.absoluteString)
        let accountKey = ClientCertificateTestSupport.key(account.absoluteString)
        log.noteClientCertificateMissing(localKey)
        log.noteClientCertificateMissing(accountKey)

        let answer = try XCTUnwrap(responder.answer(
            ClientCertificateTestSupport.clientCertificateChallenge(host: "192.168.1.10", port: 2283, protocolName: NSURLProtectionSpaceHTTP)
        ))
        XCTAssertEqual(answer.0, .useCredential)
        XCTAssertNotNil(answer.1?.identity, "the local address presents the identity saved for the account")
        XCTAssertFalse(log.clientCertificateWasMissing(for: localKey), "the log keeps the key of the contacted host")
        XCTAssertTrue(log.clientCertificateWasMissing(for: accountKey), "the account key is not the one touched")

        let foreign = try XCTUnwrap(responder.answer(
            ClientCertificateTestSupport.clientCertificateChallenge(host: "192.168.1.99", port: 2283, protocolName: NSURLProtectionSpaceHTTP)
        ))
        XCTAssertEqual(foreign.0, .performDefaultHandling)
        XCTAssertNil(foreign.1)
        XCTAssertTrue(log.clientCertificateWasMissing(for: ClientCertificateTestSupport.key("http://192.168.1.99:2283")))
    }

    /// Without a `canonicalKey` (the initialiser `.live` uses) the lookup key is the contacted host's own.
    func test_AC_241_defaultResponderHasNoAlias() throws {
        let (responder, log) = try makeResponder(attachedTo: "https://photos.example.org")

        let local = try XCTUnwrap(responder.answer(
            ClientCertificateTestSupport.clientCertificateChallenge(host: "192.168.1.10", port: 2283, protocolName: NSURLProtectionSpaceHTTP)
        ))
        XCTAssertEqual(local.0, .performDefaultHandling)
        XCTAssertNil(local.1)
        XCTAssertTrue(log.clientCertificateWasMissing(for: ClientCertificateTestSupport.key("http://192.168.1.10:2283")))

        let account = try XCTUnwrap(responder.answer(
            ClientCertificateTestSupport.clientCertificateChallenge(host: "photos.example.org", port: 443)
        ))
        XCTAssertEqual(account.0, .useCredential)
    }
}
