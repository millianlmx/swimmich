import XCTest
@testable import ImmichSwiftUI

/// When a transport failure is named "client certificate required" — and when
/// it must stay a plain network error.
final class MissingClientCertificateTests: XCTestCase {
    private let clock = TestClock()
    private var log: TLSChallengeLog!
    private let url = URL(string: "https://h.test/api/server/ping")!
    private var key: ServerKey { ServerKey(url: url)! }

    override func setUp() {
        super.setUp()
        let clock = self.clock
        log = TLSChallengeLog(now: { clock.now })
    }

    private func matches(_ code: URLError.Code, url: URL? = nil) -> Bool {
        MissingClientCertificate.matches(URLError(code), url: url ?? self.url, log: log)
    }

    func test_AC_22_3_tlsFailureAfterMissingNoteMatches() {
        log.noteClientCertificateMissing(key)
        for code in [URLError.Code.secureConnectionFailed, .clientCertificateRejected, .networkConnectionLost] {
            XCTAssertTrue(matches(code), "\(code.rawValue)")
        }
    }

    func test_AC_22_3_withoutANoteTheTlsCodesStayNetworkErrors() {
        for code in [URLError.Code.secureConnectionFailed, .clientCertificateRejected, .networkConnectionLost] {
            XCTAssertFalse(matches(code), "\(code.rawValue)")
        }
    }

    func test_AC_22_3_networkFailuresNeverMatch() {
        log.noteClientCertificateMissing(key)
        let codes: [URLError.Code] = [
            .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .cancelled, .notConnectedToInternet,
        ]
        for code in codes {
            XCTAssertFalse(matches(code), "\(code.rawValue)")
        }
    }

    func test_AC_22_3_clientCertificateRequiredCodeAlwaysMatches() {
        XCTAssertTrue(matches(.clientCertificateRequired), "-1206 needs no note")
    }

    func test_AC_22_3_aNoteOlderThanThirtySecondsDoesNotCount() {
        log.noteClientCertificateMissing(key)
        clock.advance(by: 31)
        XCTAssertFalse(matches(.secureConnectionFailed))
    }

    func test_AC_22_3_noteIsPerServer() {
        log.noteClientCertificateMissing(key)
        XCTAssertFalse(matches(.secureConnectionFailed, url: URL(string: "https://h.test:8443/x")!))
        XCTAssertFalse(matches(.secureConnectionFailed, url: URL(string: "https://other.test/x")!))
        XCTAssertFalse(MissingClientCertificate.matches(URLError(.secureConnectionFailed), url: nil, log: log))
    }

    /// A server that asks for a certificate without requiring one notes "missing"
    /// at every handshake: once it has answered, its cut connections are network
    /// errors, until the certificate changes.
    func test_AC_22_3_serverThatAnsweredWithoutCertificateNeverMatches() {
        log.noteClientCertificateMissing(key)
        log.noteServerAnswered(key)
        XCTAssertFalse(matches(.networkConnectionLost))

        log.noteClientCertificateMissing(key)
        XCTAssertFalse(matches(.networkConnectionLost), "the mark stays until `forget`")

        log.forget(key)
        log.noteClientCertificateMissing(key)
        XCTAssertTrue(matches(.networkConnectionLost))
    }

    func test_AC_22_3_anAnswerWithoutAPriorNoteMarksNothing() {
        log.noteServerAnswered(key)
        log.noteClientCertificateMissing(key)
        XCTAssertTrue(matches(.secureConnectionFailed))
    }

    func test_AC_21_2_trustRefusalIsRememberedForThirtySeconds() {
        log.noteTrustRefused(host: "NAS.Test")
        XCTAssertTrue(log.trustWasRefused(host: "nas.test"))
        XCTAssertFalse(log.trustWasRefused(host: "other.test"))
        clock.advance(by: 31)
        XCTAssertFalse(log.trustWasRefused(host: "nas.test"))
    }
}
