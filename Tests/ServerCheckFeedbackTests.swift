import XCTest
@testable import ImmichSwiftUI

/// Each validation of the server address ends with exactly one outcome, which
/// the server step turns into a haptic (L-28, B-32.6).
final class ServerCheckFeedbackTests: XCTestCase {

    @MainActor
    private func makeAuth(_ mock: MockImmichClient, trustStore: TrustedServerStore? = nil) -> (AuthViewModel, UserDefaults, String) {
        let suite = "ServerCheckFeedbackTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let auth: AuthViewModel
        if let trustStore {
            auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults, trustStore: trustStore)
        } else {
            auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        }
        auth.serverURLString = "https://photos.example.com"
        return (auth, defaults, suite)
    }

    private struct Counters: Equatable {
        let checks: Int
        let successes: Int
        let failures: Int
    }

    @MainActor
    private func counters(_ auth: AuthViewModel) -> Counters {
        Counters(checks: auth.serverCheckCount, successes: auth.serverCheckSuccessCount, failures: auth.serverCheckFailureCount)
    }

    // AC-340: a server that answers → success; anything else → failure; one counter per call.
    @MainActor
    func test_AC_340_eachCheckEndsWithOneOutcome() async {
        let mock = MockImmichClient()
        let (auth, defaults, suite) = makeAuth(mock)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(counters(auth), Counters(checks: 0, successes: 0, failures: 0))

        await auth.connectServer()
        XCTAssertEqual(counters(auth), Counters(checks: 1, successes: 1, failures: 0), "pong")

        let failures: [Error] = [
            URLError(.cannotConnectToHost),
            URLError(.serverCertificateUntrusted),
            APIError.clientCertificateRequired,
        ]
        var expected = Counters(checks: 1, successes: 1, failures: 0)
        for failure in failures {
            mock.pingError = failure
            await auth.connectServer()
            expected = Counters(checks: expected.checks + 1, successes: expected.successes, failures: expected.failures + 1)
            XCTAssertEqual(counters(auth), expected, "\(failure)")
        }

        // Something other than "pong".
        mock.pingError = nil
        mock.pingResponse = ServerPingResponse(res: "nope")
        await auth.connectServer()
        XCTAssertEqual(counters(auth), Counters(checks: expected.checks + 1, successes: 1, failures: expected.failures + 1))
    }

    // AC-340: an unusable address is a failed check too, and does not reach the server.
    @MainActor
    func test_AC_340_invalidAddressIsAFailure() async {
        let mock = MockImmichClient()
        let (auth, defaults, suite) = makeAuth(mock)
        defer { defaults.removePersistentDomain(forName: suite) }
        auth.serverURLString = "   "

        await auth.connectServer()

        XCTAssertEqual(counters(auth), Counters(checks: 1, successes: 0, failures: 1))
        XCTAssertEqual(mock.requestCount, 0)
    }

    // AC-340: trusting the host runs a check of its own, with its own outcome.
    @MainActor
    func test_AC_340_trustingTheHostCountsItsOwnCheck() async {
        let trustSuite = "ServerCheckFeedbackTrust-\(UUID().uuidString)"
        let trustDefaults = UserDefaults(suiteName: trustSuite)!
        defer { trustDefaults.removePersistentDomain(forName: trustSuite) }
        let mock = MockImmichClient()
        mock.pingError = URLError(.serverCertificateUntrusted)
        let (auth, defaults, suite) = makeAuth(mock, trustStore: TrustedServerStoreImpl(defaults: trustDefaults))
        defer { defaults.removePersistentDomain(forName: suite) }
        await auth.connectServer()
        XCTAssertEqual(counters(auth), Counters(checks: 1, successes: 0, failures: 1))
        XCTAssertEqual(auth.pendingUntrustedHost, "photos.example.com")

        mock.pingError = nil
        await auth.trustPendingServer()

        XCTAssertEqual(counters(auth), Counters(checks: 2, successes: 1, failures: 1))
    }
}
