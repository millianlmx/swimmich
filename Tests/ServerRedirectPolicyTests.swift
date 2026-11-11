import XCTest
@testable import ImmichSwiftUI

/// Imitates what CFNetwork does on a redirect: the proposed request is the
/// ORIGINAL request, every header included, with only its URL changed. The
/// delegate (task or session) is what must take the secrets out again.
///
/// - `https://a.proxy.test/y` answers 200 (and is recorded);
/// - any other path on `a.proxy.test` starting with `/same` → 302 →
///   `https://a.proxy.test/y` (same host);
/// - any other path on `a.proxy.test` → 302 → `https://b.other.test/x` (another host);
/// - every other host answers 200 and is recorded.
///
/// The recorded requests are what the "server" at each host received: a test
/// reads `requests(toHost:)` to see what survived the redirect.
final class RedirectingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _captured: [URLRequest] = []

    static func reset() {
        lock.lock(); _captured = []; lock.unlock()
    }

    static func requests(toHost host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _captured.filter { $0.url?.host == host }
    }

    /// A session wired to this protocol. `delegate` nil = a bare session.
    static func makeSession(delegate: URLSessionDelegate? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "a.proxy.test", url.path != "/y" {
            let target = URL(string: url.path.hasPrefix("/same") ? "https://a.proxy.test/y" : "https://b.other.test/x")!
            var proposed = request
            proposed.url = target
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
            return
        }
        Self.lock.lock(); Self._captured.append(request); Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// A request to the proxied server carrying everything the app puts on one.
    static func proxiedServerRequest(path: String = "/x") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://a.proxy.test\(path)")!)
        ServerRequestAuthorization.apply(
            token: "tok", custom: [StaticCustomHeaders.xAccess], to: &request
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// What must NOT have reached another host.
    func assertNoSecrets(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(value(forHTTPHeaderField: "X-Access"), file: file, line: line)
        XCTAssertNil(value(forHTTPHeaderField: "Authorization"), file: file, line: line)
        XCTAssertNil(value(forHTTPHeaderField: "x-immich-user-token"), file: file, line: line)
    }

    /// What a same-host redirect must keep.
    func assertSecretsKept(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value(forHTTPHeaderField: "X-Access"), "secret", file: file, line: line)
        XCTAssertEqual(value(forHTTPHeaderField: "Authorization"), "Bearer tok", file: file, line: line)
    }
}

final class ServerRedirectPolicyTests: XCTestCase {

    override func setUp() { RedirectingURLProtocol.reset() }
    override func tearDown() { RedirectingURLProtocol.reset() }

    /// The request CFNetwork proposes: the original, with only the URL changed.
    private func proposed(from original: URLRequest, to target: String) -> URLRequest {
        var request = original
        request.url = URL(string: target)
        return request
    }

    func test_AC_120_crossHostDropsCustomHeadersAndToken() {
        let original = URLRequest.proxiedServerRequest()
        let redirected = ServerRedirectPolicy.redirectedRequest(
            proposed(from: original, to: "https://b.other.test/x"), original: original
        )
        redirected.assertNoSecrets()
    }

    func test_AC_120_sameHostReappliesCustomHeadersAndToken() {
        let original = URLRequest.proxiedServerRequest()
        // A proposed request that lost its headers (the delegate must restore them).
        let redirected = ServerRedirectPolicy.redirectedRequest(
            URLRequest(url: URL(string: "https://a.proxy.test/y")!), original: original
        )
        redirected.assertSecretsKept()
    }

    func test_AC_120_hostComparisonIgnoresCase() {
        let original = URLRequest.proxiedServerRequest()
        let redirected = ServerRedirectPolicy.redirectedRequest(
            URLRequest(url: URL(string: "https://A.Proxy.Test/y")!), original: original
        )
        redirected.assertSecretsKept()
    }

    func test_AC_120_appHeadersSurviveCrossHost() {
        var original = URLRequest.proxiedServerRequest()
        original.setValue("multipart/form-data", forHTTPHeaderField: "Content-Type")
        original.setValue("sess=1", forHTTPHeaderField: "Cookie")
        original.setValue("Y2hlY2tzdW0=", forHTTPHeaderField: "x-immich-checksum")
        original.setValue("42", forHTTPHeaderField: "Content-Length")
        let redirected = ServerRedirectPolicy.redirectedRequest(
            proposed(from: original, to: "https://b.other.test/x"), original: original
        )
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Cookie"), "sess=1")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "x-immich-checksum"), "Y2hlY2tzdW0=")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Content-Length"), "42")
        redirected.assertNoSecrets()
    }

    func test_AC_120_customUserAgentDoesNotCrossHosts() {
        var original = URLRequest.proxiedServerRequest()
        original.setValue("secret-agent", forHTTPHeaderField: "User-Agent")
        original.setValue("x-secret", forHTTPHeaderField: "Accept-Language")

        let cross = ServerRedirectPolicy.redirectedRequest(
            proposed(from: original, to: "https://b.other.test/x"), original: original
        )
        XCTAssertNil(cross.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNil(cross.value(forHTTPHeaderField: "Accept-Language"))
        XCTAssertNil(cross.value(forHTTPHeaderField: "X-Access"))

        let same = ServerRedirectPolicy.redirectedRequest(
            URLRequest(url: URL(string: "https://a.proxy.test/y")!), original: original
        )
        XCTAssertEqual(same.value(forHTTPHeaderField: "User-Agent"), "secret-agent")
        XCTAssertEqual(same.value(forHTTPHeaderField: "Accept-Language"), "x-secret")
        XCTAssertEqual(same.value(forHTTPHeaderField: "X-Access"), "secret")
    }

    /// Invariant of the policy: a name allowed to cross hosts is a name the user
    /// cannot type, so no custom header can ever cross.
    func test_AC_120_preservedNamesAreAllReserved() {
        for name in ServerRedirectPolicy.preservedAcrossHosts {
            let result = CustomHeaderValidation.validate([(name, "v")])
            XCTAssertEqual(result.issues, [0: .reservedName], name)
        }
    }

    func test_noOriginalMeansTheProposedRequestIsUntouched() {
        let proposedRequest = proposed(from: .proxiedServerRequest(), to: "https://b.other.test/x")
        XCTAssertEqual(
            ServerRedirectPolicy.redirectedRequest(proposedRequest, original: nil).allHTTPHeaderFields,
            proposedRequest.allHTTPHeaderFields
        )
    }

    // The witness: without the policy, the imitation of CFNetwork leaks. This is
    // what makes the end-to-end tests below mean something — if the protocol
    // stopped copying headers, they would pass for the wrong reason.
    func test_AC_120_witnessSessionLeaksWithoutThePolicy() async throws {
        let session = RedirectingURLProtocol.makeSession()
        _ = try await session.data(for: .proxiedServerRequest())
        let received = try XCTUnwrap(RedirectingURLProtocol.requests(toHost: "b.other.test").first)
        XCTAssertEqual(received.value(forHTTPHeaderField: "X-Access"), "secret")
    }

    // The gate used by every path without a session delegate.
    func test_AC_120_taskDelegateGateDropsHeadersCrossHost() async throws {
        let session = RedirectingURLProtocol.makeSession()
        _ = try await ServerRedirectTaskDelegate.data(for: .proxiedServerRequest(), on: session)
        let received = try XCTUnwrap(RedirectingURLProtocol.requests(toHost: "b.other.test").first)
        received.assertNoSecrets()
        XCTAssertEqual(received.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func test_AC_120_taskDelegateGateKeepsHeadersSameHost() async throws {
        let session = RedirectingURLProtocol.makeSession()
        _ = try await ServerRedirectTaskDelegate.data(for: .proxiedServerRequest(path: "/same"), on: session)
        let received = try XCTUnwrap(RedirectingURLProtocol.requests(toHost: "a.proxy.test").first)
        received.assertSecretsKept()
    }

    func test_AC_120_taskDelegateUploadGateDropsHeadersCrossHost() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("redirect-\(UUID().uuidString).bin")
        try Data("body".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var request = URLRequest.proxiedServerRequest()
        request.httpMethod = "POST"
        let session = RedirectingURLProtocol.makeSession()
        _ = try await ServerRedirectTaskDelegate.upload(for: request, fromFile: file, on: session)
        let received = try XCTUnwrap(RedirectingURLProtocol.requests(toHost: "b.other.test").first)
        received.assertNoSecrets()
    }

    func test_AC_120_widgetTrustDelegateAppliesTheRule() async throws {
        let session = RedirectingURLProtocol.makeSession(delegate: WidgetTrustDelegate(sessionStore: NoWidgetSession()))
        _ = try await session.data(for: .proxiedServerRequest())
        let received = try XCTUnwrap(RedirectingURLProtocol.requests(toHost: "b.other.test").first)
        received.assertNoSecrets()

        RedirectingURLProtocol.reset()
        _ = try await session.data(for: .proxiedServerRequest(path: "/same"))
        let same = try XCTUnwrap(RedirectingURLProtocol.requests(toHost: "a.proxy.test").first)
        same.assertSecretsKept()
    }
}

/// A widget session store that holds nothing.
struct NoWidgetSession: WidgetSessionStoring {
    func save(_ session: WidgetSession) {}
    func load() -> WidgetSession? { nil }
    func clear() {}
}
