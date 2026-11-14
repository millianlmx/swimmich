import XCTest
@testable import ImmichSwiftUI

/// Widgets and the share extension present the client certificate, and keep no
/// session from one use to the next.
final class WidgetClientCertificateTests: XCTestCase {
    private struct StubSessionStore: WidgetSessionStoring {
        let session: WidgetSession?
        func save(_ session: WidgetSession) {}
        func load() -> WidgetSession? { session }
        func clear() {}
    }

    private final class AnswerBox: @unchecked Sendable {
        var value: (URLSession.AuthChallengeDisposition, URLCredential?)?
    }

    private func answer(
        of session: URLSession, for challenge: URLAuthenticationChallenge
    ) throws -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let delegate = try XCTUnwrap(session.delegate as? WidgetTrustDelegate)
        let box = AnswerBox()
        delegate.urlSession(session, didReceive: challenge) { disposition, credential in
            box.value = (disposition, credential)
        }
        return try XCTUnwrap(box.value)
    }

    private func makeResponder() throws -> ClientCertificateResponder {
        let store = InMemoryClientIdentityStore()
        try store.save(try ClientCertificateTestSupport.identityA(), for: ClientCertificateTestSupport.key("https://h.test"))
        return ClientCertificateResponder(store: store, log: TLSChallengeLog())
    }

    func test_AC_21_4_widgetTrustDelegatePresentsIdentity() throws {
        let responder = try makeResponder()
        let delegate = WidgetTrustDelegate(
            sessionStore: StubSessionStore(session: nil), clientCertificates: responder
        )
        let box = AnswerBox()

        delegate.urlSession(
            .shared, didReceive: ClientCertificateTestSupport.clientCertificateChallenge(host: "h.test", port: 443)
        ) { disposition, credential in box.value = (disposition, credential) }

        let result = try XCTUnwrap(box.value)
        XCTAssertEqual(result.0, .useCredential)
        XCTAssertNotNil(result.1?.identity)
    }

    func test_AC_21_4_widgetSessionsCarryTheDelegate() throws {
        let responder = try makeResponder()
        let transport = URLSessionWidgetTransport(
            sessionStore: StubSessionStore(session: nil), clientCertificates: responder
        )
        defer { transport.finish() }

        let result = try answer(
            of: transport.session,
            for: ClientCertificateTestSupport.clientCertificateChallenge(host: "h.test", port: 443)
        )
        XCTAssertEqual(result.0, .useCredential)
        XCTAssertNotNil(result.1?.identity)
    }

    func test_AC_21_4_shareUploadSessionPresentsIdentity() throws {
        let responder = try makeResponder()
        let session = URLSessionWidgetTransport.interactive(
            sessionStore: StubSessionStore(session: nil), clientCertificates: responder
        )
        defer { session.invalidateAndCancel() }

        let mine = try answer(of: session, for: ClientCertificateTestSupport.clientCertificateChallenge(host: "h.test", port: 443))
        XCTAssertEqual(mine.0, .useCredential)
        XCTAssertNotNil(mine.1?.identity)

        let other = try answer(of: session, for: ClientCertificateTestSupport.clientCertificateChallenge(host: "h.test", port: 8443))
        XCTAssertEqual(other.0, .performDefaultHandling)
        XCTAssertNil(other.1, "the certificate of h.test:443 goes to that server only")
    }

    // MARK: A transport per refresh

    private final class CountingTransport: WidgetDataTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var finishes = 0
        private let hangs: Bool

        init(hangs: Bool = false) {
            self.hangs = hangs
        }

        var finishCount: Int { lock.lock(); defer { lock.unlock() }; return finishes }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if hangs {
                try await Task.sleep(for: .seconds(30))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("[]".utf8), response)
        }

        func finish() { lock.lock(); finishes += 1; lock.unlock() }
    }

    private final class TransportFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [CountingTransport] = []
        private let hangs: Bool

        init(hangs: Bool = false) {
            self.hangs = hangs
        }

        var transports: [CountingTransport] { lock.lock(); defer { lock.unlock() }; return made }

        func make() -> CountingTransport {
            let transport = CountingTransport(hangs: hangs)
            lock.lock(); made.append(transport); lock.unlock()
            return transport
        }
    }

    private let session = StubSessionStore(session: WidgetSession(baseURL: "https://photos.example.com", token: "jwt"))

    func test_AC_22_eachRefreshUsesFreshTransport() async {
        let factory = TransportFactory()
        let provider = WidgetDataProvider(sessionStore: session, transport: { factory.make() })

        _ = await provider.recentPhotos(limit: 3, target: .medium)
        _ = await provider.favoritePhotos(limit: 3, target: .medium)
        _ = await provider.memories(limit: 1, offset: 0, target: .medium)

        XCTAssertEqual(factory.transports.count, 3, "one transport per refresh, none kept between refreshes")
        XCTAssertEqual(factory.transports.map(\.finishCount), [1, 1, 1])
    }

    func test_AC_22_aDeadlineStillFinishesTheTransport() async {
        let factory = TransportFactory(hangs: true)
        let provider = WidgetDataProvider(sessionStore: session, transport: { factory.make() }, deadline: .milliseconds(60))

        let wall = await provider.recentPhotos(limit: 3, target: .medium)
        let feed = await provider.memories(limit: 1, offset: 0, target: .medium)

        XCTAssertEqual(wall.availability, .unreachable)
        XCTAssertEqual(feed.availability, .unreachable)
        XCTAssertEqual(factory.transports.map(\.finishCount), [1, 1])
    }

    func test_AC_22_anInjectedSessionIsNotInvalidatedByFinish() async throws {
        let injected = URLSession(configuration: .ephemeral)
        let transport = URLSessionWidgetTransport(session: injected)
        transport.finish()
        // Still usable: creating a task on an invalidated session would crash.
        let task = injected.dataTask(with: URLRequest(url: URL(string: "https://photos.example.com")!))
        task.cancel()
        injected.invalidateAndCancel()
    }
}
