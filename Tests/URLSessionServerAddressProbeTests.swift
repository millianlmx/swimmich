import Network
import XCTest
@testable import ImmichSwiftUI

/// Answers each probe request from a closure, optionally late, and records what was sent.
private final class ProbeURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body = Data()
        var delay: TimeInterval = 0
        var error: URLError?
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    private static let lock = NSLock()
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    static func reset(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.lock(); _requests = []; lock.unlock()
        self.handler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._requests.append(request); Self.lock.unlock()
        let reply = Self.handler?(request) ?? Reply(status: 500)
        let deliver = { [weak self] in
            guard let self else { return }
            if let error = reply.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

private final class FakeLocalNetworkCheck: LocalNetworkAccessChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    let denied: Bool
    init(denied: Bool) { self.denied = denied }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func isDenied(host: String, port: Int, within: Duration) async -> Bool {
        lock.lock(); _calls += 1; lock.unlock()
        return denied
    }
}

final class URLSessionServerAddressProbeTests: XCTestCase {
    private let base = URL(string: "http://192.168.1.10:2283")!

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func probe(
        check: FakeLocalNetworkCheck = FakeLocalNetworkCheck(denied: false),
        trustRefused: @escaping @Sendable (String) -> Bool = { _ in false },
        deadline: Duration = .seconds(2),
        headers: [CustomHTTPHeader] = []
    ) async -> ServerAddressProbeResult {
        let session = makeSession()
        return await URLSessionServerAddressProbe(session: { session }, trustRefused: trustRefused, localNetworkCheck: check)
            .probe(base, headers: headers, deadline: deadline)
    }

    private static let pong = Data(#"{"res":"pong"}"#.utf8)
    private static let version = Data(#"{"major":1,"minor":119,"patch":0}"#.utf8)

    private static func immich(_ request: URLRequest) -> ProbeURLProtocol.Reply {
        request.url?.path.hasSuffix("/ping") == true
            ? .init(body: pong) : .init(body: version)
    }

    func test_AC_246_pongAndVersionAreImmich() async {
        ProbeURLProtocol.reset(Self.immich)
        let result = await probe()
        XCTAssertEqual(result, .immich(version: "1.119.0"))
        XCTAssertEqual(Set(ProbeURLProtocol.requests.compactMap { $0.url?.path }), ["/api/server/ping", "/api/server/version"])
    }

    func test_AC_246_anotherJSONBodyIsNotImmich() async {
        ProbeURLProtocol.reset { request in
            request.url?.path.hasSuffix("/ping") == true ? .init(body: Data(#"{"status":"ok"}"#.utf8)) : .init(body: Self.version)
        }
        let result = await probe()
        XCTAssertEqual(result, .notImmich)
    }

    func test_AC_246_versionRouteMissingIsNotImmich() async {
        ProbeURLProtocol.reset { request in
            request.url?.path.hasSuffix("/ping") == true ? .init(body: Self.pong) : .init(status: 404)
        }
        let result = await probe()
        XCTAssertEqual(result, .notImmich)
    }

    func test_AC_246_probeNeverCarriesTheTokenAndKeepsCustomHeaders() async {
        ProbeURLProtocol.reset(Self.immich)
        _ = await probe(headers: [CustomHTTPHeader(name: "X-Access", value: "secret")])
        let requests = ProbeURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-immich-user-token"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Access"), "secret")
        }
    }

    func test_AC_236_answerAfterTheDeadlineIsUnreachableWithoutWaiting() async {
        ProbeURLProtocol.reset { _ in .init(body: Self.pong, delay: 1.5) }
        let check = FakeLocalNetworkCheck(denied: true)
        let start = Date()
        let result = await probe(check: check, deadline: .milliseconds(300))
        XCTAssertEqual(result, .unreachable)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(check.calls, 0, "the permission check follows a network failure, never the deadline")
    }

    func test_AC_250_networkFailureAsksTheLocalNetworkCheck() async {
        ProbeURLProtocol.reset { _ in .init(error: URLError(.cannotConnectToHost)) }
        let denied = FakeLocalNetworkCheck(denied: true)
        let deniedResult = await probe(check: denied)
        XCTAssertEqual(deniedResult, .localNetworkDenied)
        XCTAssertEqual(denied.calls, 1)

        let allowed = FakeLocalNetworkCheck(denied: false)
        let allowedResult = await probe(check: allowed)
        XCTAssertEqual(allowedResult, .unreachable)
    }

    func test_AC_250_successNeverAsksTheLocalNetworkCheck() async {
        ProbeURLProtocol.reset(Self.immich)
        let check = FakeLocalNetworkCheck(denied: true)
        let result = await probe(check: check)
        XCTAssertEqual(result, .immich(version: "1.119.0"))
        XCTAssertEqual(check.calls, 0)
    }

    func test_AC_241_untrustedCertificateNamesTheHost() async {
        ProbeURLProtocol.reset { _ in .init(error: URLError(.serverCertificateUntrusted)) }
        let tls = await probe()
        XCTAssertEqual(tls, .untrustedCertificate(host: "192.168.1.10"))

        ProbeURLProtocol.reset { _ in .init(error: URLError(.cancelled)) }
        let refused = await probe(trustRefused: { $0 == "192.168.1.10" })
        XCTAssertEqual(refused, .untrustedCertificate(host: "192.168.1.10"))
        let cancelled = await probe()
        XCTAssertEqual(cancelled, .unreachable)
    }
}

final class ServerAddressProbeClassifierTests: XCTestCase {
    func test_AC_250_deniedOnlyForANetworkFailure() {
        let error = URLError(.notConnectedToInternet)
        XCTAssertEqual(ServerAddressProbeClassifier.classify(error, localNetworkDenied: true, host: "h", trustRefused: false), .localNetworkDenied)
        XCTAssertEqual(ServerAddressProbeClassifier.classify(error, localNetworkDenied: false, host: "h", trustRefused: false), .unreachable)
    }

    func test_AC_241_trustFailureWinsOverDenial() {
        XCTAssertEqual(
            ServerAddressProbeClassifier.classify(URLError(.serverCertificateHasBadDate), localNetworkDenied: true, host: "h", trustRefused: false),
            .untrustedCertificate(host: "h")
        )
        XCTAssertEqual(
            ServerAddressProbeClassifier.classify(URLError(.cancelled), localNetworkDenied: false, host: "h", trustRefused: true),
            .untrustedCertificate(host: "h")
        )
    }
}

final class NWConnectionLocalNetworkCheckTests: XCTestCase {
    func test_AC_250_verdict() {
        let verdict = NWConnectionLocalNetworkCheck.verdict
        XCTAssertEqual(verdict(.waiting(.posix(.ENETDOWN)), .localNetworkDenied), true)
        XCTAssertEqual(verdict(.waiting(.posix(.ENETDOWN)), .notAvailable), false)
        XCTAssertEqual(verdict(.waiting(.posix(.ENETDOWN)), nil), false)
        XCTAssertEqual(verdict(.ready, nil), false)
        XCTAssertEqual(verdict(.failed(.posix(.ECONNREFUSED)), nil), false)
        XCTAssertEqual(verdict(.cancelled, nil), false)
        XCTAssertNil(verdict(.preparing, nil))
        XCTAssertNil(verdict(.setup, nil))
    }
}
