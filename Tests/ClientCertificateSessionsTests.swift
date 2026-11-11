import XCTest
@testable import ImmichSwiftUI

/// Answers every request with a scripted `URLError`, or with a 200.
private final class ScriptedFailureURLProtocol: URLProtocol {
    static var failure: URLError.Code?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let code = Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"res":"pong"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The sessions the app builds present the client certificate, and are replaced
/// when it changes.
final class ClientCertificateSessionsTests: XCTestCase {
    private var suites: [String] = []
    private var sessionsToClose: [ServerSessions] = []

    override func tearDown() {
        ScriptedFailureURLProtocol.failure = nil
        for sessions in sessionsToClose {
            for session in [sessions.images, sessions.transfers, sessions.roadTrip, sessions.video, sessions.realtime] {
                session.invalidateAndCancel()
            }
        }
        sessionsToClose = []
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func makeTrustStore() -> TrustedServerStoreImpl {
        let suite = "client-certificate-sessions-\(UUID().uuidString)"
        suites.append(suite)
        return TrustedServerStoreImpl(defaults: UserDefaults(suiteName: suite)!)
    }

    private final class AnswerBox: @unchecked Sendable {
        var value: (URLSession.AuthChallengeDisposition, URLCredential?)?
    }

    private func answer(
        of delegate: ServerSessionDelegate, session: URLSession, for challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let box = AnswerBox()
        delegate.urlSession(session, didReceive: challenge) { disposition, credential in
            box.value = (disposition, credential)
        }
        return box.value ?? (.cancelAuthenticationChallenge, nil)
    }

    // MARK: Delegates

    func test_AC_21_serverSessionsPresentTheIdentityOfTheirServer() throws {
        let store = InMemoryClientIdentityStore()
        try store.save(try ClientCertificateTestSupport.identityA(), for: ClientCertificateTestSupport.key("https://h.test"))
        let log = TLSChallengeLog()
        let sessions = ServerSessions(
            trustStore: makeTrustStore(),
            clientCertificates: ClientCertificateResponder(store: store, log: log),
            imageCache: URLCache(memoryCapacity: 0, diskCapacity: 0)
        )
        sessionsToClose.append(sessions)

        for session in [sessions.images, sessions.transfers, sessions.roadTrip, sessions.video, sessions.realtime] {
            let delegate = try XCTUnwrap(session.delegate as? ServerSessionDelegate)
            let mine = answer(
                of: delegate, session: session,
                for: ClientCertificateTestSupport.clientCertificateChallenge(host: "h.test", port: 443)
            )
            XCTAssertEqual(mine.0, .useCredential)
            XCTAssertNotNil(mine.1?.identity)

            let other = answer(
                of: delegate, session: session,
                for: ClientCertificateTestSupport.clientCertificateChallenge(host: "h.test", port: 8443)
            )
            XCTAssertEqual(other.0, .performDefaultHandling, "another port of the same host is another server")
            XCTAssertNil(other.1)
        }
    }

    // MARK: Renewal

    func test_AC_22_renewSessionsReplacesEverySession() throws {
        let cache = URLCache(memoryCapacity: 0, diskCapacity: 0)
        let sessions = ServerSessions(trustStore: makeTrustStore(), imageCache: cache)
        sessionsToClose.append(sessions)
        let before = [sessions.images, sessions.transfers, sessions.roadTrip, sessions.video, sessions.realtime]

        sessions.renewSessions()

        let after = [sessions.images, sessions.transfers, sessions.roadTrip, sessions.video, sessions.realtime]
        for (old, new) in zip(before, after) {
            XCTAssertTrue(old !== new, "every session is replaced")
            XCTAssertTrue(new.delegate is ServerSessionDelegate)
            XCTAssertFalse((old.delegate as AnyObject?) === (new.delegate as AnyObject?), "with a delegate of its own")
        }
        XCTAssertTrue(sessions.images.configuration.urlCache === cache, "the image disk cache survives the renewal")
        XCTAssertEqual(Set(after.map { ObjectIdentifier($0) }).count, 5, "five distinct sessions")
    }

    func test_AC_22_downloadTransportFollowsRenewal() throws {
        let sessions = ServerSessions(trustStore: makeTrustStore(), imageCache: URLCache(memoryCapacity: 0, diskCapacity: 0))
        sessionsToClose.append(sessions)
        let transport = sessions.makeDownloadTransport()
        let old = transport.session()
        XCTAssertTrue(old === sessions.transfers)

        sessions.renewSessions()

        XCTAssertTrue(transport.session() === sessions.transfers, "a transport built before the renewal reads the new session")
        XCTAssertTrue(transport.session() !== old)
    }

    func test_AC_22_resetConnectionsStillWorksAfterARenewal() async {
        let sessions = ServerSessions(trustStore: makeTrustStore(), imageCache: URLCache(memoryCapacity: 0, diskCapacity: 0))
        sessionsToClose.append(sessions)
        sessions.renewSessions()

        await sessions.resetConnections()   // must not touch an invalidated session

        XCTAssertNotNil(sessions.images.delegate)
    }

    func test_AC_22_renewSessionsReplacesOwnedSession() {
        let owning = ImmichAPIClient(trustStore: makeTrustStore())
        let before = owning.currentSession
        owning.renewSessions()
        XCTAssertTrue(owning.currentSession !== before)
        XCTAssertTrue(owning.currentSession.delegate is TrustEvaluatingURLSessionDelegate)

        let injected = URLSession(configuration: .ephemeral)
        let borrowing = ImmichAPIClient(session: injected)
        borrowing.renewSessions()
        XCTAssertTrue(borrowing.currentSession === injected, "a session handed in is never replaced or invalidated")
    }

    // MARK: API client errors

    private func makeClient(log: TLSChallengeLog) -> ImmichAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedFailureURLProtocol.self]
        let client = ImmichAPIClient(session: URLSession(configuration: configuration), challengeLog: log)
        client.configure(baseURL: URL(string: "https://h.test"), token: nil)
        return client
    }

    private let key = ClientCertificateTestSupport.key("https://h.test")

    func test_AC_22_missingCertificateMapsToDedicatedError() async {
        let log = TLSChallengeLog()
        log.noteClientCertificateMissing(key)
        ScriptedFailureURLProtocol.failure = .secureConnectionFailed

        do {
            _ = try await makeClient(log: log).ping()
            XCTFail("the request must fail")
        } catch {
            XCTAssertEqual(error as? APIError, .clientCertificateRequired)
        }
    }

    func test_AC_22_failureWithoutNoteStaysNetwork() async {
        ScriptedFailureURLProtocol.failure = .secureConnectionFailed

        do {
            _ = try await makeClient(log: TLSChallengeLog()).ping()
            XCTFail("the request must fail")
        } catch {
            guard case .network(let urlError)? = error as? APIError else {
                return XCTFail("expected a network error, got \(error)")
            }
            XCTAssertEqual(urlError.code, .secureConnectionFailed)
        }
    }

    func test_AC_22_timeoutWithMissingNoteStaysNetwork() async {
        let log = TLSChallengeLog()
        log.noteClientCertificateMissing(key)
        ScriptedFailureURLProtocol.failure = .timedOut

        do {
            _ = try await makeClient(log: log).ping()
            XCTFail("the request must fail")
        } catch {
            guard case .network(let urlError)? = error as? APIError else {
                return XCTFail("expected a network error, got \(error)")
            }
            XCTAssertEqual(urlError.code, .timedOut)
        }
    }

    /// A server that answers has not refused a missing certificate: its later
    /// cut connections stay ordinary network errors.
    func test_AC_22_responseMarksServerAnswered() async throws {
        let log = TLSChallengeLog()
        log.noteClientCertificateMissing(key)
        let client = makeClient(log: log)

        ScriptedFailureURLProtocol.failure = nil
        _ = try await client.ping()
        ScriptedFailureURLProtocol.failure = .networkConnectionLost

        do {
            _ = try await client.ping()
            XCTFail("the request must fail")
        } catch {
            guard case .network(let urlError)? = error as? APIError else {
                return XCTFail("expected a network error, got \(error)")
            }
            XCTAssertEqual(urlError.code, .networkConnectionLost)
        }
    }

    func test_AC_22_userFacingMessageNamesTheMissingCertificate() {
        let message = APIError.clientCertificateRequired.userFacingMessage
        XCTAssertEqual(message, UserFacingError.clientCertificateRequiredMessage)
        XCTAssertNotEqual(message, UserFacingError.offlineMessage)
        XCTAssertEqual(UserFacingError.from(APIError.clientCertificateRequired)?.family, .other)
    }
}
