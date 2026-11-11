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
}
