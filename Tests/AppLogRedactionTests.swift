import XCTest
@testable import ImmichSwiftUI

/// A transport that answers each request from a closure: a status with a body,
/// or a failure whose text the test chooses (`didFailWithError`). It is what
/// lets a test make a request fail with an error that quotes the URL and the
/// secrets, as a real transport error may.
private final class RedactionURLProtocol: URLProtocol {
    enum Outcome {
        case status(Int, Data)
        case fail(NSError)
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Outcome)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch handler(request) {
        case .status(let code, let data):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct FixedHeaders: CustomHeadersProviding {
    let list: [CustomHTTPHeader]
    func headers(for url: URL?) -> [CustomHTTPHeader] { list }
}

private func redactionFailure(_ text: String) -> NSError {
    NSError(domain: "AppLogRedactionTests", code: 7, userInfo: [NSLocalizedDescriptionKey: text])
}

/// Need B-15: what the app log keeps, shows, copies and exports carries neither
/// a server's address nor a secret — and still carries what a diagnosis reads.
///
/// The store under test is the production `AppLogStore`; the client is the
/// production `ImmichAPIClient` over a session whose transport is
/// `RedactionURLProtocol`, so a line is produced the way the app produces it.
@MainActor
final class AppLogRedactionTests: XCTestCase {

    private let marker = AppLogRedactor.marker

    override func tearDown() {
        RedactionURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Doubles

    private func makeClient(
        _ store: AppLogStore,
        headers: [CustomHTTPHeader] = []
    ) -> ImmichAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedactionURLProtocol.self]
        return ImmichAPIClient(
            session: URLSession(configuration: config), log: store, customHeaders: FixedHeaders(list: headers)
        )
    }

    private func export(_ store: AppLogStore) -> String {
        let vm = AppLogViewModel(store: store)
        vm.refresh()
        return vm.exportText()
    }

    private func makeRedactor(learning servers: [String] = [], secrets: [String] = []) -> AppLogRedactor {
        var redactor = AppLogRedactor()
        for server in servers { redactor.learnServer(URL(string: server)!) }
        for secret in secrets { redactor.learnSecret(secret) }
        return redactor
    }

    /// Every text of every line, as the screen, the detail blocks and the
    /// clipboard read them.
    private func texts(of store: AppLogStore, includingStack: Bool = true) -> [String] {
        store.snapshot().flatMap {
            [$0.path, $0.message, $0.details, includingStack ? $0.stack : nil].compactMap { $0 }
        }
    }

    // MARK: - The redactor

    func test_redactor_textWithNothingToMaskIsReturnedAsIs() {
        let redactor = makeRedactor(learning: ["https://photos.example.org:2283/immich"])
        XCTAssertEqual(redactor.redact(""), "")
        XCTAssertEqual(redactor.redact("GET /api/assets/1 → 404"), "GET /api/assets/1 → 404")
    }

    func test_redactor_urlKeepsOnlyItsApiTail() {
        let redactor = makeRedactor(secrets: ["KEY123"])
        XCTAssertEqual(
            redactor.redact("failed https://photos.example.org:2283/immich/api/assets?key=KEY123 now"),
            "failed \(marker)/api/assets now"
        )
        XCTAssertEqual(redactor.redact("see https://photos.example.org/docs/page#top."), "see \(marker).")
        XCTAssertEqual(redactor.redact("file:///tmp/a.jpg stays"), "file:///tmp/a.jpg stays")
        XCTAssertEqual(redactor.redact("http://[::1]:2283/api/x"), "\(marker)/api/x")
    }

    func test_redactor_bearerTokenAndBareQueryDisappear() {
        let redactor = makeRedactor()
        XCTAssertEqual(redactor.redact("Authorization: Bearer abc.def-123"), "Authorization: \(marker)")
        XCTAssertEqual(redactor.redact("GET /api/view/folder?path=/mnt/private failed"), "GET /api/view/folder failed")
    }

    func test_redactor_aSecretInAnUrlAndBareIsMaskedBothTimes() {
        let redactor = makeRedactor(secrets: ["KEY123"])
        XCTAssertEqual(
            redactor.redact("GET https://h.example/api/x?key=KEY123 failed with KEY123"),
            "GET \(marker)/api/x failed with \(marker)"
        )
    }

    func test_redactor_hostIsMaskedAsAWholeDnsWordOnly() {
        let redactor = makeRedactor(learning: ["https://photos.example.org", "http://192.168.1.20:2283"])
        XCTAssertEqual(redactor.redact("myphotos.example.org"), "myphotos.example.org")
        XCTAssertEqual(redactor.redact("photos.example.org.evil"), "photos.example.org.evil")
        XCTAssertEqual(redactor.redact("www.photos.example.org"), "www.\(marker)")
        XCTAssertEqual(redactor.redact("Could not connect to photos.example.org."), "Could not connect to \(marker).")
        XCTAssertEqual(redactor.redact("PHOTOS.Example.ORG"), marker)
        XCTAssertEqual(redactor.redact("photos.example.org:2283 refused"), "\(marker) refused")
        XCTAssertEqual(redactor.redact("192.168.1.200"), "192.168.1.200")
        XCTAssertEqual(redactor.redact("to 192.168.1.20"), "to \(marker)")
    }

    func test_redactor_aSingleLabelHostNeverTouchesAnApiPath() {
        var redactor = makeRedactor(learning: ["http://server:2283"])
        let entry = AppLogEntry(
            level: .info, method: "GET", path: "/api/server/ping", status: 200, category: "HTTP",
            message: "GET /api/server/ping → 200"
        )
        let kept = redactor.redact(entry)
        XCTAssertEqual(kept.path, "/api/server/ping")
        XCTAssertEqual(kept.message, "GET /api/server/ping → 200")
        XCTAssertEqual(redactor.redact("the server “server”"), "the \(marker) “\(marker)”")

        redactor = makeRedactor(learning: ["http://pi:2283"])
        XCTAssertEqual(redactor.redact("GET /api/assets → 200"), "GET /api/assets → 200")
    }

    func test_redactor_portIsMaskedOnlyStandingAlone() {
        let redactor = makeRedactor(learning: ["https://photos.example.org:2283"])
        let uuid = "/api/assets/1a2283b4-0000-4000-8000-000000000000"
        XCTAssertEqual(redactor.redact(uuid), uuid)
        XCTAssertEqual(redactor.redact("port 2283"), "port \(marker)")

        let short = makeRedactor(learning: ["https://photos.example.org:404"])
        XCTAssertEqual(short.redact("GET /api/x → 404 in 12 ms"), "GET /api/x → 404 in 12 ms")
    }

    func test_redactor_basePathLeavesTheApiPath() {
        let redactor = makeRedactor(learning: ["https://photos.example.org/immich/"])
        XCTAssertEqual(redactor.basePaths, ["/immich"])
        XCTAssertEqual(redactor.redact("/immich/api/server/ping"), "/api/server/ping")
        XCTAssertEqual(redactor.redact("GET /immich/api/server/ping → 200"), "GET /api/server/ping → 200")
        XCTAssertEqual(redactor.redact("moved to /immich"), "moved to \(marker)")
        XCTAssertEqual(redactor.redact("/immich-other"), "/immich-other")
    }

    func test_redactor_aTransportErrorTextThatNamesNothingIsUntouched() {
        let redactor = makeRedactor(learning: ["https://photos.example.org:2283/immich"], secrets: ["tok-12345"])
        let text = URLError(.cannotConnectToHost).localizedDescription
        XCTAssertEqual(redactor.redact(text), text)
    }

    func test_redactor_isIdempotent() {
        let redactor = makeRedactor(
            learning: ["https://photos.example.org:2283/immich", "http://server:2283"], secrets: ["KEY123", "tok-12345"]
        )
        let text = """
        Error Domain=NSURLErrorDomain Code=-1004 UserInfo={NSErrorFailingURLStringKey=https://photos.example.org:2283/immich/api/assets?key=KEY123, \
        NSLocalizedDescription=Could not connect to photos.example.org. Bearer tok-12345 the server /immich/api/x}
        """
        let once = redactor.redact(text)
        XCTAssertEqual(redactor.redact(once), once)
        XCTAssertFalse(once.contains("photos.example.org"))
    }

    func test_redactor_learnRequestKeepsOnlyCredentials() {
        var redactor = AppLogRedactor()
        var request = URLRequest(url: URL(string: "https://photos.example.org/api/x?key=KEY123&slug=SLUG99&visibility=timeline&apiKey=KK9999")!)
        request.setValue("Bearer tok-abcd", forHTTPHeaderField: "Authorization")
        request.setValue("immich_shared_link_token=cookieVal1; other=zzzz1", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("secret-proxy", forHTTPHeaderField: "X-Access")
        request.setValue("abcdefgh", forHTTPHeaderField: "x-immich-checksum")

        XCTAssertTrue(redactor.learnRequest(request, customHeaderNames: ["X-Access", "x-immich-checksum"]))

        for learnt in ["Bearer tok-abcd", "tok-abcd", "cookieVal1", "zzzz1", "secret-proxy", "KEY123", "SLUG99", "KK9999"] {
            XCTAssertTrue(redactor.secrets.contains(learnt), "\(learnt) must be learnt")
        }
        for ignored in ["application/json", "abcdefgh", "timeline"] {
            XCTAssertFalse(redactor.secrets.contains(ignored), "\(ignored) is not a credential")
        }
        XCTAssertFalse(redactor.learnRequest(request, customHeaderNames: ["X-Access"]), "nothing new the second time")
    }

    func test_redactor_aSecretUnderFourCharactersIsNotLearnt() {
        var redactor = AppLogRedactor()
        XCTAssertFalse(redactor.learnSecret("abc"))
        XCTAssertTrue(redactor.learnSecret("abcd"))
        XCTAssertEqual(redactor.redact("abc abcd"), "abc \(marker)")
    }

    func test_redactor_vocabularyDoesNotGrowWithTheTraffic() {
        var redactor = AppLogRedactor()
        var request = URLRequest(url: URL(string: "https://photos.example.org/api/assets")!)
        request.setValue("Bearer tok-abcd", forHTTPHeaderField: "Authorization")
        XCTAssertTrue(redactor.learnRequest(request, customHeaderNames: []))
        let before = redactor

        for n in 0..<1000 {
            var upload = request
            upload.setValue("checksum-\(n)-xxxx", forHTTPHeaderField: "x-immich-checksum")
            upload.setValue("\(10_000 + n)", forHTTPHeaderField: "Content-Length")
            XCTAssertFalse(redactor.learnRequest(upload, customHeaderNames: ["x-immich-checksum"]))
        }

        XCTAssertEqual(redactor, before)
        XCTAssertEqual(redactor.redact("sum checksum-7-xxxx"), "sum checksum-7-xxxx")
    }

    func test_redactor_entryKeepsEveryDiagnosticField() {
        let redactor = makeRedactor(learning: ["https://photos.example.org/immich"])
        let entry = AppLogEntry(
            date: Date(timeIntervalSince1970: 1_700_000_000), level: .severe, method: "PUT",
            path: "/immich/api/assets/abc", status: 500, durationMS: 42, category: "Upload",
            message: "PUT /immich/api/assets/abc → 500", details: nil, stack: "frame photos.example.org"
        )
        let kept = redactor.redact(entry)
        XCTAssertEqual(kept.id, entry.id)
        XCTAssertEqual(kept.date, entry.date)
        XCTAssertEqual(kept.level, .severe)
        XCTAssertEqual(kept.method, "PUT")
        XCTAssertEqual(kept.status, 500)
        XCTAssertEqual(kept.durationMS, 42)
        XCTAssertEqual(kept.category, "Upload")
        XCTAssertEqual(kept.path, "/api/assets/abc")
        XCTAssertEqual(kept.message, "PUT /api/assets/abc → 500")
        XCTAssertNil(kept.details)
        XCTAssertEqual(kept.stack, "frame \(marker)")
    }

    // MARK: - The store

    func test_store_linesKeptBeforeALearningAreMaskedAgain() {
        let store = AppLogStore()
        store.record(AppLogEntry(level: .info, method: "GET", path: "/api/x", category: "HTTP", message: "late.example.io answered"))
        XCTAssertTrue(texts(of: store).contains { $0.contains("late.example.io") }, "unknown yet: kept as is")

        store.learnServer(URL(string: "https://late.example.io")!)

        XCTAssertEqual(store.snapshot().first?.message, "\(marker) answered")
    }

    func test_store_clearKeepsWhatItLearnt() {
        let store = AppLogStore()
        store.learnServer(URL(string: "https://old.example.net")!)
        store.record(AppLogEntry(level: .info, method: "GET", path: "/api/x", category: "HTTP", message: "old.example.net"))
        store.clear()
        store.record(AppLogEntry(level: .info, method: "GET", path: "/api/x", category: "HTTP", message: "again old.example.net"))

        XCTAssertEqual(store.snapshot().map(\.message), ["again \(marker)"])
    }

    /// 100 tokens learnt while 100 lines that cite all of them are recorded: no
    /// line may keep one, whatever the interleaving. Repeated to expose the
    /// window between masking a line and storing it.
    func test_store_concurrentLearningAndRecordingLeavesNoToken() async {
        let tokens = (0..<100).map { "tok-\($0)-suffix-fixed" }
        let text = tokens.joined(separator: " ")
        for round in 0..<20 {
            let store = AppLogStore()
            await withTaskGroup(of: Void.self) { group in
                for n in 0..<100 {
                    group.addTask {
                        var request = URLRequest(url: URL(string: "https://h.example/api/x")!)
                        request.setValue("Bearer \(tokens[n])", forHTTPHeaderField: "Authorization")
                        store.learnRequest(request, customHeaderNames: [])
                    }
                    group.addTask {
                        store.record(AppLogEntry(level: .info, method: "GET", path: "/api/x", category: "HTTP", message: text))
                    }
                }
            }
            let lines = store.snapshot()
            XCTAssertEqual(lines.count, 100, "round \(round)")
            for line in lines {
                for token in tokens where line.message.contains(token) {
                    XCTFail("round \(round): \(token) survived in a stored line")
                    return
                }
            }
        }
    }

    // MARK: - Through the client

    func test_AC_23_sharedLogHasNoAddressTokenApiKeyNorPassword() async throws {
        let store = AppLogStore()
        let client = makeClient(store)
        let token = "session-token-9f3a7c1d"
        let password = "hunter2-correct-horse"
        let apiSecret = "api-key-secret-77aa31"
        RedactionURLProtocol.handler = { request in
            switch request.url?.path ?? "" {
            case "/api/api-keys":
                return .status(201, Data(#"{"secret":"\#(apiSecret)","apiKey":{"id":"k1","name":"cli"}}"#.utf8))
            case "/api/assets/boom":
                return .fail(redactionFailure("""
                Could not connect to https://photos.example.org/api/assets/boom?key=zz — \
                Bearer \(token), api key \(apiSecret), password \(password), host photos.example.org
                """))
            default:
                return .status(200, Data(#"{"res":"pong"}"#.utf8))
            }
        }
        client.configure(baseURL: URL(string: "https://photos.example.org")!, token: token)

        _ = try await client.ping()
        _ = try? await client.login(email: "me@example.org", password: password)
        _ = try await client.createAPIKey(name: "cli", permissions: ["all"])
        _ = try? await client.getAsset(id: "boom")

        let shared = export(store)
        XCTAssertTrue(shared.contains("/api/assets/boom"), "the failing line is there")
        XCTAssertTrue(shared.contains(marker), "something was masked")
        for forbidden in ["photos.example.org", token, apiSecret, password] {
            XCTAssertFalse(shared.contains(forbidden), "the shared log leaks \(forbidden)")
        }
    }

    func test_AC_127_thrownHttpUploadAndEditorLinesHideAddressPortBasePathAndQuery() async throws {
        let store = AppLogStore()
        let client = makeClient(store)
        client.configure(baseURL: URL(string: "https://photos.example.org:2283/immich")!, token: "tok-aaaa-1111")
        RedactionURLProtocol.handler = { _ in
            .fail(redactionFailure("The request https://photos.example.org:2283/immich/api/assets?key=K failed at photos.example.org:2283"))
        }

        _ = try? await client.getAsset(id: "abc")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("redaction-\(UUID().uuidString).jpg")
        try Data(repeating: 0x41, count: 256).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try? await client.uploadAsset(
            fileURL: file, fileCreatedAt: "2026-01-01T00:00:00.000Z", fileModifiedAt: "2026-01-01T00:00:00.000Z",
            filename: "a.jpg", duration: nil, isFavorite: false, visibility: .timeline, livePhotoVideoId: nil,
            checksum: "0123456789abcdef", deviceAssetId: "dev-1", deviceId: "device"
        )

        // The editor's draft failure: `String(describing:)` of an error that
        // carries the failing URL in its `userInfo`.
        let editorError = NSError(
            domain: NSCocoaErrorDomain, code: 4,
            userInfo: ["NSErrorFailingURLStringKey": "https://photos.example.org:2283/immich/api/assets?key=K"]
        )
        store.record(AppLogEntry(
            level: .warning, method: "FILE", path: "EditStates", category: "Editor",
            message: "Could not save the draft", details: String(describing: editorError)
        ))

        let lines = store.snapshot()
        XCTAssertEqual(Set(lines.map(\.category)), ["HTTP", "Upload", "Editor"])
        for line in lines where line.category != "Editor" {
            XCTAssertEqual(line.level, .severe)
            XCTAssertTrue(line.path.hasPrefix("/api/"), "the base path is gone from \(line.path)")
        }
        let shared = export(store)
        for forbidden in ["photos.example.org", "2283", "/immich", "?"] {
            XCTAssertFalse(shared.contains(forbidden), "the shared log leaks \(forbidden): \(shared)")
        }
        for text in texts(of: store, includingStack: false) {
            XCTAssertFalse(text.contains("photos.example.org") || text.contains("/immich") || text.contains("?"), text)
        }
    }

    func test_AC_128_everyAddressEverContactedStaysHidden() async throws {
        let store = AppLogStore()
        let client = makeClient(store)
        RedactionURLProtocol.handler = { request in
            .fail(redactionFailure("Could not connect to \(request.url?.host ?? "?")."))
        }

        for address in [
            "https://photos.example.org", "http://192.168.1.20:2283", "https://old.example.net",
            "https://typo.example.com"
        ] {
            client.configure(baseURL: URL(string: address)!, token: nil)
            _ = try? await client.ping()
        }
        // The account of `old.example.net` is gone; the process still knows it.
        store.record(AppLogEntry(
            level: .warning, method: "GET", path: "/api/x", category: "HTTP",
            message: "late line about old.example.net and typo.example.com"
        ))
        // A line kept before an address is learnt is masked once it is.
        store.record(AppLogEntry(level: .info, method: "GET", path: "/api/x", category: "HTTP", message: "kept for late.example.io"))
        store.learnServer(URL(string: "https://late.example.io")!)

        let shared = export(store)
        for host in ["photos.example.org", "192.168.1.20", "old.example.net", "typo.example.com", "late.example.io"] {
            XCTAssertFalse(shared.contains(host), "the shared log leaks \(host)")
        }
        XCTAssertGreaterThanOrEqual(store.count(), 6)
    }

    func test_AC_129_actionSecretsNeverReachExportScreenNorCopiedBlocks() async throws {
        let store = AppLogStore()
        let proxy = "secret-proxy"
        let linkKey = "KEY123"
        let linkPassword = "link-pass-77"
        let apiSecret = "api-secret-5f2d"
        let oldPassword = "old-pass-1234"
        let newPassword = "new-pass-5678"
        let pin = "483920"
        let p12 = "p12-secret"
        let token = "session-token-aa11"
        let secrets = [proxy, linkKey, linkPassword, apiSecret, oldPassword, newPassword, pin, p12, token]
        let server = URL(string: "https://photos.example.org")!

        RedactionURLProtocol.handler = { request in
            switch request.url?.path ?? "" {
            case "/api/api-keys":
                return .status(201, Data(#"{"secret":"\#(apiSecret)","apiKey":{"id":"k1","name":"cli"}}"#.utf8))
            case "/api/shared-links/me":
                return .fail(redactionFailure(
                    "Request to https://photos.example.org/api/shared-links/me?key=KEY123 failed: "
                        + secrets.joined(separator: " ")
                ))
            default:
                return .status(200, Data("{}".utf8))
            }
        }
        let client = makeClient(store, headers: [CustomHTTPHeader(name: "X-Access", value: proxy)])
        client.configure(baseURL: server, token: token)
        let certificates = ClientCertificateService(
            store: InMemoryClientIdentityStore(), log: TLSChallengeLog(), sessions: [],
            reconnectRealtime: {}, reloadWidgets: {}, appLog: store
        )

        _ = try? await client.login(email: "me@example.org", password: oldPassword)
        try? await certificates.importCertificate(Data("not a pkcs12".utf8), password: p12, for: server)
        _ = try? await client.loginToSharedLink(.key(linkKey), password: linkPassword)
        _ = try await client.createAPIKey(name: "cli", permissions: ["all"])
        _ = try? await client.changePassword(currentPassword: oldPassword, newPassword: newPassword, invalidateSessions: false)
        try? await client.unlockAuthSession(pinCode: pin)
        _ = try? await client.getSharedLinkMine(.key(linkKey))

        let vm = AppLogViewModel(store: store)
        vm.refresh()
        let failing = try XCTUnwrap(vm.entries.first { $0.path == "/api/shared-links/me" && $0.level == .severe })
        XCTAssertTrue(failing.details?.contains(marker) == true, "the failure's text was masked, not dropped")

        let shown = vm.filteredEntries.flatMap { [$0.path, $0.message, $0.details, $0.stack].compactMap { $0 } }
        let copied = [failing.message, failing.details, failing.stack].compactMap { $0 }
        XCTAssertEqual(copied.count, 3)
        for secret in secrets + ["photos.example.org"] {
            XCTAssertFalse(vm.exportText().contains(secret), "the export leaks \(secret)")
            for text in shown + copied {
                XCTAssertFalse(text.contains(secret), "a line or a copied block leaks \(secret): \(text)")
            }
        }
    }

    func test_AC_130_failedEntryBlocksAreStoredRedacted() async throws {
        let store = AppLogStore()
        let client = makeClient(store)
        let token = "session-token-c0ffee99"
        client.configure(baseURL: URL(string: "https://photos.example.org")!, token: token)
        RedactionURLProtocol.handler = { _ in
            .fail(redactionFailure("GET https://photos.example.org/api/x failed with Bearer \(token) and bare \(token)"))
        }

        _ = try? await client.getAsset(id: "abc")

        let entry = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(entry.level, .severe)
        let message = entry.message
        let details = try XCTUnwrap(entry.details)
        let stack = try XCTUnwrap(entry.stack)
        XCTAssertTrue(message.contains("GET /api/assets/abc →"))
        XCTAssertTrue(details.contains(marker))
        XCTAssertFalse(stack.isEmpty)
        for block in [entry.path, message, details, stack] {
            XCTAssertFalse(block.contains("photos.example.org"), block)
            XCTAssertFalse(block.contains(token), block)
        }
    }

    func test_AC_131_exportKeepsDiagnosticColumns() async throws {
        let store = AppLogStore()
        let client = makeClient(store)
        client.configure(baseURL: URL(string: "https://photos.example.org")!, token: "tok-aaaa-9999")
        RedactionURLProtocol.handler = { request in
            .status(request.url?.path.hasSuffix("def") == true ? 404 : 200, Data("{}".utf8))
        }

        _ = try? await client.getAsset(id: "abc")
        _ = try? await client.getAsset(id: "def")

        let lines = export(store).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let pattern = #"^\d{2}:\d{2}:\d{2}\.\d{3} \| (info|warning) \| HTTP \| GET /api/assets/(abc|def) \| (200|404) \| \d+ ms \| GET /api/assets/(abc|def) → (200|404)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        for line in lines {
            XCTAssertEqual(
                regex.numberOfMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length)), 1, line
            )
        }
        XCTAssertTrue(lines[0].contains("| warning |") && lines[0].contains("/api/assets/def") && lines[0].contains("| 404 |"), "newest first")
        XCTAssertTrue(lines[1].contains("| info |") && lines[1].contains("/api/assets/abc") && lines[1].contains("| 200 |"))
    }
}
