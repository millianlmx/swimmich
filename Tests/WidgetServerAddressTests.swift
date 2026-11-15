import XCTest
@testable import ImmichSwiftUI

/// L-26 part 2: the widgets, the favorite intent and the share extension choose
/// between the local and the external address of the server by the app's rule,
/// from the session the app published, and carry the server's headers and
/// client certificate to both addresses.
final class WidgetServerAddressTests: XCTestCase {
    private let external = URL(string: "https://photos.example.org")!
    private let local = URL(string: "http://192.168.1.10:2283")!
    private let version = "1.119.0"

    private struct StubSessionStore: WidgetSessionStoring {
        let session: WidgetSession?
        func save(_ session: WidgetSession) {}
        func load() -> WidgetSession? { session }
        func clear() {}
    }

    /// Records every request, answers the widget routes with a one-photo library.
    private final class RecordingTransport: WidgetDataTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []

        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock(); recorded.append(request); lock.unlock()
            let body: Data
            switch request.url?.path ?? "" {
            case "/api/timeline/buckets": body = Data(#"[{"timeBucket":"2026-09-13T00:00:00.000Z","count":1}]"#.utf8)
            case "/api/timeline/bucket": body = Data(#"{"id":["a1"],"isImage":[true]}"#.utf8)
            default: body = Data()
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    private final class DispositionBox: @unchecked Sendable {
        var value: URLSession.AuthChallengeDisposition?
    }

    private func session(autoSwitch: Bool? = true, headers: [CustomHTTPHeader]? = nil) -> WidgetSession {
        WidgetSession(
            baseURL: external.absoluteString, token: "widget-jwt", customHeaders: headers,
            localURL: local.absoluteString, autoSwitch: autoSwitch, lastKnownVersion: version,
            accountURL: external.absoluteString
        )
    }

    private func probe(local localResult: ServerAddressProbeResult, external externalResult: ServerAddressProbeResult = .immich(version: "1.119.0")) -> ScriptedServerAddressProbe {
        let probe = ScriptedServerAddressProbe()
        probe.answer(local, localResult)
        probe.answer(external, externalResult)
        return probe
    }

    private func refreshWidgetWall(_ session: WidgetSession, probe: ScriptedServerAddressProbe) async -> (RecordingTransport, PhotoWall) {
        let transport = RecordingTransport()
        let provider = WidgetDataProvider(
            sessionStore: StubSessionStore(session: session), transport: { transport },
            endpoints: WidgetEndpointResolver(probe: probe, deadline: .milliseconds(200))
        )
        let wall = await provider.recentPhotos(limit: 1, target: .medium)
        return (transport, wall)
    }

    private func refreshWidget(_ session: WidgetSession, probe: ScriptedServerAddressProbe) async -> RecordingTransport {
        await refreshWidgetWall(session, probe: probe).0
    }

    /// The favorite intent's write, on `session`, and the requests it sent.
    private func toggleFavorite(_ session: WidgetSession, probe: ScriptedServerAddressProbe) async -> [URLRequest] {
        let transport = RecordingTransport()
        await ToggleFavoriteIntent.write(
            assetId: "a1", favorite: true,
            sessionStore: StubSessionStore(session: session), transport: transport,
            reloadTimelines: { _ in }, log: { _ in },
            endpoints: WidgetEndpointResolver(probe: probe, deadline: .milliseconds(200))
        )
        return transport.requests
    }

    private func hosts(_ requests: [URLRequest]) -> Set<String> {
        Set(requests.compactMap { request in request.url.map { "\($0.host ?? ""):\($0.port ?? 443)" } })
    }

    // MARK: - AC-239: widget

    func test_AC_239_widgetUsesExternalWhenLocalUnreachable() async {
        let transport = await refreshWidget(session(), probe: probe(local: .unreachable))

        XCTAssertFalse(transport.requests.isEmpty)
        XCTAssertEqual(hosts(transport.requests), ["photos.example.org:443"])
    }

    func test_AC_239_widgetUsesLocalWhenItAnswersAsThisServer() async {
        let transport = await refreshWidget(session(), probe: probe(local: .immich(version: version)))

        XCTAssertFalse(transport.requests.isEmpty)
        XCTAssertEqual(hosts(transport.requests), ["192.168.1.10:2283"], "timeline and thumbnails all go to the local address")
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer widget-jwt" })
    }

    func test_AC_239_widgetKeepsExternalWhenLocalIsAnotherServer() async {
        let other = await refreshWidget(session(), probe: probe(local: .immich(version: "1.120.0")))
        XCTAssertEqual(hosts(other.requests), ["photos.example.org:443"], "another version is not this server")
    }

    func test_AC_239_externalMuteKnownVersionLetsLocalWin() async {
        let transport = await refreshWidget(session(), probe: probe(local: .immich(version: version), external: .unreachable))

        XCTAssertEqual(hosts(transport.requests), ["192.168.1.10:2283"])
    }

    func test_AC_239_switchOffNeverProbes() async {
        let probe = self.probe(local: .immich(version: version))

        let transport = await refreshWidget(session(autoSwitch: false), probe: probe)

        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertEqual(hosts(transport.requests), ["photos.example.org:443"])
    }

    func test_AC_239_sessionOfAnEarlierBuildDecodesAndStaysExternal() async throws {
        let json = Data(#"{"baseURL":"https://photos.example.org","token":"widget-jwt"}"#.utf8)
        let old = try JSONDecoder().decode(WidgetSession.self, from: json)
        XCTAssertNil(old.localURL)
        XCTAssertNil(old.autoSwitch)
        let probe = ScriptedServerAddressProbe()

        let resolved = await WidgetEndpointResolver(probe: probe).resolve(old)

        XCTAssertEqual(resolved, old)
        XCTAssertTrue(probe.calls.isEmpty)
    }

    // MARK: - AC-239: favorite intent and share extension

    func test_AC_239_favoriteIntentWritesToTheChosenAddress() async throws {
        let transport = RecordingTransport()

        await ToggleFavoriteIntent.write(
            assetId: "a1", favorite: true,
            sessionStore: StubSessionStore(session: session()), transport: transport,
            reloadTimelines: { _ in }, log: { _ in },
            endpoints: WidgetEndpointResolver(probe: probe(local: .immich(version: version)), deadline: .milliseconds(200))
        )

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.10:2283/api/assets/a1")
    }

    func test_AC_239_shareUploadsToTheChosenAddress() async throws {
        defer { CapturingURLProtocol.reset() }
        let resolver = WidgetEndpointResolver(probe: probe(local: .immich(version: version)), deadline: .milliseconds(200))
        let target = await resolver.resolve(session(headers: [StaticCustomHeaders.xAccess]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        CapturingURLProtocol.nextStatus = 201
        CapturingURLProtocol.nextData = Data(#"{"id":"a1","status":"created"}"#.utf8)
        let client = SharedUploadClient(
            baseURL: target.baseURL, token: target.token, deviceId: "device-1",
            customHeaders: target.customHeaders ?? [], session: URLSession(configuration: configuration)
        )
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("l26-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("photo.jpg")
        try Data(repeating: 0x41, count: 512).write(to: file)

        _ = try await client.upload(
            fileURL: file, filename: "photo.jpg", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: nil, deviceAssetId: "share/1"
        )

        let request = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.host, "192.168.1.10")
        XCTAssertEqual(request.url?.port, 2283)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Access"), "secret", "the server's header goes to the local address too")
    }

    // MARK: - AC-241

    func test_AC_241_probesCarryTheServerHeaders() async {
        let probe = self.probe(local: .immich(version: version))

        _ = await WidgetEndpointResolver(probe: probe, deadline: .milliseconds(200))
            .resolve(session(headers: [StaticCustomHeaders.xAccess]))

        XCTAssertEqual(probe.callCount(for: local), 1)
        XCTAssertEqual(probe.callCount(for: external), 1)
        XCTAssertTrue(probe.calls.allSatisfy { $0.headers == [StaticCustomHeaders.xAccess] }, "the probe of each address carries the header")
    }

    func test_AC_241_widgetHeadersOnTheLocalAddress() async {
        let transport = await refreshWidget(session(headers: [StaticCustomHeaders.xAccess]), probe: probe(local: .immich(version: version)))

        XCTAssertFalse(transport.requests.isEmpty)
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Access") == "secret" })
    }

    func test_AC_241_widgetPresentsTheAccountCertificateOnTheLocalAddress() throws {
        let store = InMemoryClientIdentityStore()
        try store.save(try ClientCertificateTestSupport.identityA(), for: ClientCertificateTestSupport.key("https://photos.example.org"))
        let stored = WidgetSession(
            baseURL: external.absoluteString, token: "widget-jwt",
            localURL: "https://nas.local:2283", autoSwitch: true, accountURL: external.absoluteString
        )
        let delegate = WidgetTrustDelegate(
            sessionStore: StubSessionStore(session: stored),
            clientCertificates: ClientCertificateResponder(store: store, log: TLSChallengeLog())
        )

        func answer(host: String, port: Int) -> URLSession.AuthChallengeDisposition? {
            let box = DispositionBox()
            delegate.urlSession(
                .shared, didReceive: ClientCertificateTestSupport.clientCertificateChallenge(host: host, port: port)
            ) { value, _ in box.value = value }
            return box.value
        }

        XCTAssertEqual(answer(host: "nas.local", port: 2283), .useCredential, "the local address presents the account's certificate")
        XCTAssertEqual(answer(host: "photos.example.org", port: 443), .useCredential)
        XCTAssertEqual(answer(host: "other.example", port: 443), .performDefaultHandling, "never to a foreign server")
    }

    // MARK: - L-26 part 2: widgets and extension, requirement by requirement

    func test_AC_239_1_slowLocalFallsBackWithinTheDeadline() async {
        let probe = ScriptedServerAddressProbe()
        probe.script(local, ScriptedServerAddressProbe.Step(result: .immich(version: version), delay: .seconds(3)))
        probe.answer(external, .immich(version: version))
        let resolver = WidgetEndpointResolver(probe: probe)
        let stored = session()

        var resolved = stored
        let elapsed = await ContinuousClock().measure { resolved = await resolver.resolve(stored) }

        XCTAssertEqual(resolved.baseURL, external.absoluteString, "a local address that answers after the deadline is not used")
        XCTAssertLessThan(elapsed, .milliseconds(2500))
        XCTAssertEqual(probe.callCount(for: local), 1)
    }

    func test_AC_239_2_favoriteIntentFallsBackToExternal() async {
        let requests = await toggleFavorite(session(), probe: probe(local: .unreachable))

        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "")" }, ["PUT https://photos.example.org/api/assets/a1"])
    }

    func test_AC_239_5_noLocalAddressNeverProbes() async {
        let stored = WidgetSession(
            baseURL: "https://vpn.example.net", token: "widget-jwt",
            localURL: nil, autoSwitch: true, lastKnownVersion: version, accountURL: external.absoluteString
        )
        let probe = ScriptedServerAddressProbe()

        let transport = await refreshWidget(stored, probe: probe)

        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertEqual(hosts(transport.requests), ["vpn.example.net:443"])
    }

    func test_AC_239_6_localThatIsNotImmichStaysExternal() async {
        let transport = await refreshWidget(session(), probe: probe(local: .notImmich))

        XCTAssertFalse(transport.requests.isEmpty)
        XCTAssertEqual(hosts(transport.requests), ["photos.example.org:443"])
        XCTAssertFalse(transport.requests.contains { $0.url?.host == "192.168.1.10" })
    }

    func test_AC_241_1_headersOnTheExternalFallback() async {
        let headers = [StaticCustomHeaders.xAccess]
        let probe = self.probe(local: .unreachable)

        let transport = await refreshWidget(session(headers: headers), probe: probe)

        XCTAssertFalse(transport.requests.isEmpty)
        XCTAssertEqual(hosts(transport.requests), ["photos.example.org:443"])
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Access") == "secret" })
        XCTAssertEqual(probe.calls.count, 2)
        XCTAssertTrue(probe.calls.allSatisfy { $0.headers == headers })
    }

    /// An address the widget cannot use is a silent fallback, never a message:
    /// the wall, the favorite write and the extension's base all stay on the
    /// external address.
    private func assertSilentFallback(_ localResult: ServerAddressProbeResult, file: StaticString = #filePath, line: UInt = #line) async {
        let (transport, wall) = await refreshWidgetWall(session(), probe: probe(local: localResult))
        XCTAssertEqual(hosts(transport.requests), ["photos.example.org:443"], file: file, line: line)
        XCTAssertEqual(wall.availability, .ready, file: file, line: line)
        XCTAssertNil(wall.failureHint, file: file, line: line)

        let writes = await toggleFavorite(session(), probe: probe(local: localResult))
        XCTAssertEqual(writes.map { $0.url?.absoluteString }, ["https://photos.example.org/api/assets/a1"], file: file, line: line)

        let stored = session()
        let resolved = await WidgetEndpointResolver(probe: probe(local: localResult), deadline: .milliseconds(200)).resolve(stored)
        XCTAssertEqual(resolved, stored, "the extension's base is the external address", file: file, line: line)
    }

    func test_AC_241_2_untrustedLocalFallsBackSilently() async {
        await assertSilentFallback(.untrustedCertificate(host: "192.168.1.10"))
    }

    func test_AC_250_1_deniedLocalNetworkFallsBackSilently() async {
        await assertSilentFallback(.localNetworkDenied)
    }
}
