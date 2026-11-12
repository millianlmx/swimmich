import XCTest
@testable import ImmichSwiftUI

/// The wire of this file's tests: a status and a body per host and path
/// (default 200, `[]`), the ordered list of every request that reached it, and
/// the option to hold one answer until the test lets it go. Private to the L-20
/// tests, so `CapturingURLProtocol` (one global "last request") stays as it is.
final class RouteWire: URLProtocol {
    struct Recorded: Equatable {
        let method: String
        let host: String
        let path: String
        let authorization: String?
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [Recorded] = []
    nonisolated(unsafe) private static var _responses: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var _holds: Set<String> = []
    nonisolated(unsafe) private static var _pending: [String: [RouteWire]] = [:]

    static var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return _requests }

    static func reset() {
        lock.lock()
        _requests = []; _responses = [:]; _holds = []; _pending = [:]
        lock.unlock()
    }

    private static func key(_ host: String?, _ path: String?) -> String { "\(host ?? "") \(path ?? "")" }

    static func answer(host: String, path: String, status: Int = 200, body: Data) {
        lock.lock(); _responses[key(host, path)] = (status, body); lock.unlock()
    }

    static func answer(host: String, path: String, status: Int = 200, json: Any) {
        // swiftlint:disable:next force_try
        answer(host: host, path: path, status: status, body: try! JSONSerialization.data(withJSONObject: json))
    }

    static func hold(host: String, path: String) {
        lock.lock(); _holds.insert(key(host, path)); lock.unlock()
    }

    /// Lets every held answer of this host and path go (and stops holding).
    static func release(host: String, path: String) {
        let k = key(host, path)
        lock.lock()
        _holds.remove(k)
        let pending = _pending.removeValue(forKey: k) ?? []
        lock.unlock()
        pending.forEach { $0.respond() }
    }

    static func waitForHeld(host: String, path: String, count: Int, timeout: TimeInterval = 5) async -> Bool {
        let k = key(host, path)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let held = _pending[k]?.count ?? 0; lock.unlock()
            if held >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host, path = request.url?.path
        let k = Self.key(host, path)
        Self.lock.lock()
        Self._requests.append(Recorded(
            method: request.httpMethod ?? "GET", host: host ?? "", path: path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: Self.captureBody(from: request)
        ))
        let held = Self._holds.contains(k)
        if held { Self._pending[k, default: []].append(self) }
        Self.lock.unlock()
        if !held { respond() }
    }

    override func stopLoading() {}

    private func respond() {
        let k = Self.key(request.url?.host, request.url?.path)
        Self.lock.lock()
        let reply = Self._responses[k] ?? (200, Data("[]".utf8))
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func captureBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A gate a test opens by hand.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}

/// L-20: the client picks the replacement route of a deprecated one from the
/// server's version, and only then (AC-35, AC-36, AC-174 … AC-180).
final class ServerRouteCompatTests: XCTestCase {
    private let hostA = "a.example"
    private let hostB = "b.example"

    override func setUp() { RouteWire.reset() }
    override func tearDown() { RouteWire.reset() }

    // MARK: - Fixtures

    private func makeClient(host: String, token: String? = "tok-a") -> ImmichAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouteWire.self]
        let client = ImmichAPIClient(session: URLSession(configuration: config))
        client.configure(baseURL: URL(string: "https://\(host)")!, token: token)
        return client
    }

    /// The version a host announces; nil = a server whose version cannot be read.
    private func announce(_ version: String?, on host: String) {
        guard let version else {
            RouteWire.answer(host: host, path: "/api/server/version", status: 500, json: ["message": "down"])
            return
        }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        RouteWire.answer(host: host, path: "/api/server/version",
                         json: ["major": parts[0], "minor": parts[1], "patch": parts[2]])
    }

    /// Valid bodies for the routes of both families, so a call that reaches the
    /// wrong one still decodes and only its path gives it away.
    private func seedBodies(on host: String) {
        RouteWire.answer(host: host, path: "/api/public/config", json: ["oauth": ["buttonText": "SSO"]])
        RouteWire.answer(host: host, path: "/api/config",
                         json: ["oauth": ["buttonText": "SSO"], "server": ["externalDomain": "https://public.example"]])
        RouteWire.answer(host: host, path: "/api/server/config", json: Self.contract("2.0.0")["serverConfig"] as Any)
        RouteWire.answer(host: host, path: "/api/jobs", json: [String: Any]())
        RouteWire.answer(host: host, path: "/api/queues", json: [Any]())
    }

    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) { return url }
            url.deleteLastPathComponent()
        }
        return url
    }

    /// `UITests/stubs/route_payloads.json`: the bodies the stub shell serves.
    private static func contract(_ version: String) -> [String: Any] {
        let url = repoRoot.appendingPathComponent("UITests/stubs/route_payloads.json")
        guard let data = try? Data(contentsOf: url),
              let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]],
              let section = all[version]
        else { return [:] }
        return section
    }

    private func routes(after mark: Int) -> [String] {
        RouteWire.requests.dropFirst(mark).map { "\($0.method) \($0.path)" }
    }

    private func jsonBody(_ recorded: RouteWire.Recorded) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
    }

    private func assertBody(_ recorded: RouteWire.Recorded, _ expected: [String: Any], _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        let body = (try? JSONSerialization.jsonObject(with: recorded.body)) as? NSDictionary
        XCTAssertEqual(body, expected as NSDictionary, message, file: file, line: line)
    }

    /// Runs `call` and checks that it sent exactly one request, to `expected`.
    private func expectRoute(_ label: String, _ expected: String, probes: Bool = false,
                             _ call: () async throws -> Void) async throws {
        let mark = RouteWire.requests.count
        try await call()
        // `probes`: no version is known yet, so the call reads it first.
        XCTAssertEqual(routes(after: mark), (probes ? ["GET /api/server/version"] : []) + [expected], label)
    }

    private func readyClient(host: String, version: String?, token: String? = "tok-a") async throws -> ImmichAPIClient {
        announce(version, on: host)
        seedBodies(on: host)
        let client = makeClient(host: host, token: token)
        if version != nil { _ = try await client.serverVersion() }
        return client
    }

    // MARK: - AC-35

    func test_AC_35_mockDefaultsKeepExistingFlows() async throws {
        let mock = MockImmichClient()
        let expected = ServerConfig(oauthButtonText: "", externalDomain: "", isInitialized: true)
        let publicConfig = try await mock.publicConfig()
        let sessionConfig = try await mock.sessionConfig()
        XCTAssertEqual(publicConfig, expected)
        XCTAssertEqual(sessionConfig, expected)
    }

    /// The bodies the stub shell serves (`route_payloads.json`) decode with the real client.
    func test_AC_35_stubPayloadsDecode() async throws {
        let modern = Self.contract("3.4.0"), classic = Self.contract("2.0.0")
        XCTAssertFalse(modern.isEmpty, "route_payloads.json not found from \(#filePath)")
        XCTAssertFalse(classic.isEmpty)

        announce("3.4.0", on: hostA)
        RouteWire.answer(host: hostA, path: "/api/public/config", json: modern["publicConfig"] as Any)
        RouteWire.answer(host: hostA, path: "/api/config", json: modern["userConfig"] as Any)
        RouteWire.answer(host: hostA, path: "/api/queues", json: modern["queues"] as Any)
        let a = makeClient(host: hostA)
        let publicConfig = try await a.publicConfig()
        XCTAssertEqual(publicConfig, ServerConfig(oauthButtonText: "Continue with Immich SSO", externalDomain: nil, isInitialized: nil))
        let sessionConfig = try await a.sessionConfig()
        XCTAssertEqual(sessionConfig, ServerConfig(oauthButtonText: "Continue with Immich SSO", externalDomain: "", isInitialized: nil))
        let fromQueues = try await a.getJobsStatus()

        announce("2.0.0", on: hostB)
        RouteWire.answer(host: hostB, path: "/api/server/config", json: classic["serverConfig"] as Any)
        RouteWire.answer(host: hostB, path: "/api/jobs", json: classic["jobs"] as Any)
        let b = makeClient(host: hostB)
        let legacy = try await b.publicConfig()
        XCTAssertEqual(legacy, ServerConfig(oauthButtonText: "Continue with Immich SSO", externalDomain: "", isInitialized: true))
        let fromJobs = try await b.getJobsStatus()

        XCTAssertEqual(fromQueues.keys.sorted(), ["thumbnailGeneration"])
        XCTAssertEqual(fromQueues, fromJobs, "both route families give the Admin screen the same queues")
    }

    // MARK: - AC-36

    func test_AC_36_routesPerThreshold() async throws {
        let table: [(text: String, v: (Int, Int, Int))] = [
            ("2.0.0", (2, 0, 0)), ("2.3.9", (2, 3, 9)), ("2.4.0", (2, 4, 0)), ("3.1.0", (3, 1, 0)),
            ("3.2.0", (3, 2, 0)), ("3.2.1", (3, 2, 1)), ("3.4.0", (3, 4, 0)),
        ]
        for (text, v) in table {
            let host = "v\(text.replacingOccurrences(of: ".", with: "-")).example"
            let client = try await readyClient(host: host, version: text)
            let queues = v >= (2, 4, 0), config = v >= (3, 2, 0), merge = v >= (3, 2, 1)

            try await expectRoute("merge \(text)", merge ? "POST /api/people/merge" : "POST /api/people/c/merge") {
                _ = try await client.mergePeople(ids: ["a", "b"], into: "c")
            }
            try await expectRoute("publicConfig \(text)", config ? "GET /api/public/config" : "GET /api/server/config") {
                _ = try await client.publicConfig()
            }
            try await expectRoute("sessionConfig \(text)", config ? "GET /api/config" : "GET /api/server/config") {
                _ = try await client.sessionConfig()
            }
            try await expectRoute("jobs \(text)", queues ? "GET /api/queues" : "GET /api/jobs") {
                _ = try await client.getJobsStatus()
            }
            let commands: [(command: String, replacement: String)] = [
                ("pause", "PUT /api/queues/q"), ("resume", "PUT /api/queues/q"),
                ("empty", "DELETE /api/queues/q/jobs"),
                ("start", "PUT /api/jobs/q"), ("clear-failed", "PUT /api/jobs/q"),
            ]
            for (command, replacement) in commands {
                try await expectRoute("\(command) \(text)", queues ? replacement : "PUT /api/jobs/q") {
                    try await client.sendJobCommand(name: "q", command: command, force: nil)
                }
            }
        }
    }

    // MARK: - AC-174

    func test_AC_174_mergeTargetFirstFrom321() async throws {
        let client = try await readyClient(host: hostA, version: "3.2.1")
        let mark = RouteWire.requests.count
        _ = try await client.mergePeople(ids: ["A", "B"], into: "C")
        // C is also among the sources: it still leads, once, and the order of the others is kept.
        _ = try await client.mergePeople(ids: ["A", "C", "B"], into: "C")

        let sent = RouteWire.requests.dropFirst(mark)
        XCTAssertEqual(sent.map(\.path), ["/api/people/merge", "/api/people/merge"])
        XCTAssertEqual(try sent.map { try jsonBody($0)["ids"] as? [String] }, [["C", "A", "B"], ["C", "A", "B"]])
    }

    func test_AC_174_mergeLegacyBelow321() async throws {
        let client = try await readyClient(host: hostA, version: "3.2.0")
        let mark = RouteWire.requests.count
        _ = try await client.mergePeople(ids: ["A", "B"], into: "C")

        let sent = try XCTUnwrap(RouteWire.requests.dropFirst(mark).first)
        XCTAssertEqual(sent.path, "/api/people/C/merge")
        XCTAssertEqual(try jsonBody(sent)["ids"] as? [String], ["A", "B"])
    }

    // MARK: - AC-175

    func test_AC_175_publicConfigFrom320() async throws {
        let client = try await readyClient(host: hostA, version: "3.2.0")
        let config = try await client.publicConfig()
        XCTAssertEqual(config, ServerConfig(oauthButtonText: "SSO", externalDomain: nil, isInitialized: nil))
    }

    func test_AC_175_sessionConfigFrom320() async throws {
        let client = try await readyClient(host: hostA, version: "3.4.0")
        let config = try await client.sessionConfig()
        XCTAssertEqual(config, ServerConfig(oauthButtonText: "SSO", externalDomain: "https://public.example", isInitialized: nil))

        // The authenticated route needs a session: without a token nothing is sent.
        let anonymous = try await readyClient(host: hostB, version: "3.4.0", token: nil)
        let mark = RouteWire.requests.count
        do {
            _ = try await anonymous.sessionConfig()
            XCTFail("sessionConfig without a token must not succeed from v3.2.0")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        XCTAssertTrue(routes(after: mark).isEmpty)
    }

    func test_AC_175_legacyConfigBelow320() async throws {
        let client = try await readyClient(host: hostA, version: "3.1.0")
        let publicConfig = try await client.publicConfig()
        let sessionConfig = try await client.sessionConfig()
        let expected = ServerConfig(
            oauthButtonText: "Continue with Immich SSO", externalDomain: "", isInitialized: true
        )
        XCTAssertEqual(publicConfig, expected)
        XCTAssertEqual(sessionConfig, expected)
    }

    // MARK: - AC-176 (client)

    func test_AC_176_versionProbedAfterReconfigure() async throws {
        let client = try await readyClient(host: hostA, version: "3.4.0")
        announce("2.0.0", on: hostB)
        seedBodies(on: hostB)

        // Same address, another token: the version is still known, no probe.
        client.configure(baseURL: URL(string: "https://\(hostA)")!, token: "tok-other")
        try await expectRoute("same address", "POST /api/people/merge") {
            _ = try await client.mergePeople(ids: ["a"], into: "c")
        }

        // A new address: the cache is empty, the first routed call probes it.
        client.configure(baseURL: URL(string: "https://\(hostB)")!, token: "tok-b")
        let mark = RouteWire.requests.count
        _ = try await client.mergePeople(ids: ["a"], into: "c")
        let sent = RouteWire.requests.dropFirst(mark)
        XCTAssertEqual(sent.map { "\($0.method) \($0.host) \($0.path)" },
                       ["GET \(hostB) /api/server/version", "POST \(hostB) /api/people/c/merge"])
    }

    // MARK: - AC-177

    func test_AC_177_queuesDecodeToSameJobs() async throws {
        let statistics: [String: Any] = ["active": 2, "completed": 5, "delayed": 1, "failed": 3, "paused": 0, "waiting": 4]
        let idle: [String: Any] = ["active": 0, "completed": 1, "delayed": 0, "failed": 0, "paused": 0, "waiting": 0]
        let modern = try await readyClient(host: hostA, version: "3.4.0")
        let queuesJSON: [[String: Any]] = [
            ["name": "thumbnailGeneration", "isPaused": true, "statistics": statistics],
            ["name": "sidecar", "isPaused": false, "statistics": idle],
        ]
        RouteWire.answer(host: hostA, path: "/api/queues", json: queuesJSON)
        let classic = try await readyClient(host: hostB, version: "2.0.0")
        let jobsJSON: [String: Any] = [
            "thumbnailGeneration": ["queueStatus": ["isActive": true, "isPaused": true], "jobCounts": statistics],
            "sidecar": ["queueStatus": ["isActive": false, "isPaused": false], "jobCounts": idle],
        ]
        RouteWire.answer(host: hostB, path: "/api/jobs", json: jobsJSON)

        let fromQueues = try await modern.getJobsStatus()
        let fromJobs = try await classic.getJobsStatus()

        XCTAssertEqual(fromQueues, fromJobs)
        XCTAssertEqual(fromQueues.keys.sorted(), ["sidecar", "thumbnailGeneration"])
        XCTAssertEqual(fromQueues["thumbnailGeneration"]?.queueStatus, QueueStatusLegacyDto(isActive: true, isPaused: true))
        XCTAssertEqual(fromQueues["sidecar"]?.queueStatus, QueueStatusLegacyDto(isActive: false, isPaused: false))
        XCTAssertEqual(fromQueues["thumbnailGeneration"]?.jobCounts.failed, 3)
    }

    func test_AC_177_commandRoutesFrom240() async throws {
        let client = try await readyClient(host: hostA, version: "2.4.0")
        let mark = RouteWire.requests.count
        for command in ["pause", "resume", "empty", "start", "clear-failed"] {
            try await client.sendJobCommand(name: "q", command: command, force: command == "start" ? true : nil)
        }

        let sent = Array(RouteWire.requests.dropFirst(mark))
        XCTAssertEqual(sent.map { "\($0.method) \($0.path)" }, [
            "PUT /api/queues/q", "PUT /api/queues/q", "DELETE /api/queues/q/jobs",
            "PUT /api/jobs/q", "PUT /api/jobs/q",
        ])
        assertBody(sent[0], ["isPaused": true])
        assertBody(sent[1], ["isPaused": false])
        assertBody(sent[2], [:], "no `failed`: the same effect as the legacy empty")
        assertBody(sent[3], ["command": "start", "force": true])
        assertBody(sent[4], ["command": "clear-failed"])
    }

    func test_AC_177_backgroundTaskPauseStaysLegacy() async throws {
        let client = try await readyClient(host: hostA, version: "3.4.0")
        let mark = RouteWire.requests.count
        try await client.sendJobCommand(name: "backgroundTask", command: "pause", force: nil)
        try await client.sendJobCommand(name: "backgroundTask", command: "resume", force: nil)

        let sent = Array(RouteWire.requests.dropFirst(mark))
        XCTAssertEqual(sent.map { "\($0.method) \($0.path)" },
                       ["PUT /api/jobs/backgroundTask", "PUT /api/queues/backgroundTask"],
                       "the replacement refuses (400) to pause backgroundTask, the legacy route does not")
        assertBody(sent[0], ["command": "pause"])
    }

    @MainActor
    func test_AC_177_adminRunJobRefreshes() async throws {
        let mock = MockImmichClient()
        let vm = AdminViewModel(client: mock)
        let queue = QueueResponseLegacyDto(
            queueStatus: QueueStatusLegacyDto(isActive: false, isPaused: true),
            jobCounts: QueueStatisticsDto(active: 0, completed: 1, failed: 0, delayed: 0, waiting: 0, paused: 0)
        )
        mock.jobsStatusResponse = ["thumbnailGeneration": queue]
        XCTAssertTrue(vm.jobs.isEmpty)

        await vm.runJob(name: "thumbnailGeneration", command: "pause")

        XCTAssertEqual(mock.lastJobCommandName, "thumbnailGeneration")
        XCTAssertEqual(mock.lastJobCommand, "pause")
        XCTAssertEqual(vm.jobs, ["thumbnailGeneration": queue], "the list is read again after the command")
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - AC-178

    func test_AC_178_unreadableVersionUsesLegacy() async throws {
        // A server whose version route answers 500, then one whose body is not a version.
        for broken in [true, false] {
            let host = broken ? "broken.example" : "garbage.example"
            seedBodies(on: host)
            if broken { announce(nil, on: host) } // 500; the other keeps the default `[]`
            let client = makeClient(host: host)

            try await expectRoute("merge", "POST /api/people/c/merge", probes: true) { _ = try await client.mergePeople(ids: ["a"], into: "c") }
            try await expectRoute("publicConfig", "GET /api/server/config", probes: true) { _ = try await client.publicConfig() }
            try await expectRoute("sessionConfig", "GET /api/server/config", probes: true) { _ = try await client.sessionConfig() }
            try await expectRoute("jobs", "GET /api/jobs", probes: true) { _ = try await client.getJobsStatus() }
            try await expectRoute("pause", "PUT /api/jobs/q", probes: true) { try await client.sendJobCommand(name: "q", command: "pause", force: nil) }
            try await expectRoute("empty", "PUT /api/jobs/q", probes: true) { try await client.sendJobCommand(name: "q", command: "empty", force: nil) }
        }
    }

    func test_AC_178_failedProbeRetriedNextCall() async throws {
        announce(nil, on: hostA)
        seedBodies(on: hostA)
        let client = makeClient(host: hostA)

        let mark = RouteWire.requests.count
        _ = try await client.mergePeople(ids: ["a"], into: "c")
        XCTAssertEqual(routes(after: mark), ["GET /api/server/version", "POST /api/people/c/merge"])

        // The server answers now: no negative cache, the next call probes again.
        announce("3.4.0", on: hostA)
        let second = RouteWire.requests.count
        _ = try await client.mergePeople(ids: ["a"], into: "c")
        XCTAssertEqual(routes(after: second), ["GET /api/server/version", "POST /api/people/merge"])
    }

    // MARK: - AC-179

    func test_AC_179_readOnlyRefusesWithoutRequest() async throws {
        let client = try await readyClient(host: hostA, version: "3.4.0")
        let guarded = ReadOnlyGuardClient(inner: client, isEnabled: { true })
        let mark = RouteWire.requests.count

        do {
            _ = try await guarded.mergePeople(ids: ["a"], into: "c")
            XCTFail("merge must be refused in read-only mode")
        } catch {
            XCTAssertEqual(error as? APIError, .readOnlyMode)
        }
        do {
            try await guarded.sendJobCommand(name: "q", command: "pause", force: nil)
            XCTFail("a job command must be refused in read-only mode")
        } catch {
            XCTAssertEqual(error as? APIError, .readOnlyMode)
        }
        XCTAssertTrue(routes(after: mark).isEmpty, "no probe and no write")

        _ = try await guarded.getJobsStatus()
        XCTAssertEqual(routes(after: mark), ["GET /api/queues"], "reads still pass")
    }

    // MARK: - AC-180 (client)

    func test_AC_180_baseURLChangeDropsVersion() async throws {
        let client = try await readyClient(host: hostA, version: "3.4.0")
        announce(nil, on: hostB)
        seedBodies(on: hostB)

        client.configure(baseURL: URL(string: "https://\(hostB)")!, token: "tok-b")
        let mark = RouteWire.requests.count
        _ = try await client.mergePeople(ids: ["a"], into: "c")

        let sent = RouteWire.requests.dropFirst(mark)
        XCTAssertEqual(sent.map { "\($0.method) \($0.host) \($0.path)" },
                       ["GET \(hostB) /api/server/version", "POST \(hostB) /api/people/c/merge"],
                       "A's version never decides a route sent to B")
    }

    /// The invariant is proven on the wire: a call started for A goes to A, with A's token,
    /// whatever `configure` does while its version probe is in flight.
    func test_AC_180_probeInFlightDuringSwitchStaysOnA() async throws {
        announce("3.4.0", on: hostA)
        seedBodies(on: hostA)
        announce("2.0.0", on: hostB)
        seedBodies(on: hostB)
        RouteWire.hold(host: hostA, path: "/api/server/version")
        let client = makeClient(host: hostA, token: "tok-a")

        let merge = Task { try await client.mergePeople(ids: ["a", "b"], into: "c") }
        let jobs = Task { try await client.getJobsStatus() }
        let held = await RouteWire.waitForHeld(host: hostA, path: "/api/server/version", count: 2)
        XCTAssertTrue(held, "both calls are waiting for A's version")

        client.configure(baseURL: URL(string: "https://\(hostB)")!, token: "tok-b")
        RouteWire.release(host: hostA, path: "/api/server/version")
        _ = try await merge.value
        _ = try await jobs.value

        let sent = RouteWire.requests
        XCTAssertTrue(sent.filter { $0.host == hostB }.isEmpty, "nothing reached B: \(sent)")
        XCTAssertTrue(sent.contains { $0.host == hostA && $0.method == "POST" && $0.path == "/api/people/merge"
            && $0.authorization == "Bearer tok-a" }, "merge goes to A on A's version, with A's token")
        XCTAssertTrue(sent.contains { $0.host == hostA && $0.method == "GET" && $0.path == "/api/queues"
            && $0.authorization == "Bearer tok-a" })

        // B (2.0.0) is probed on its own, and only legacy routes reach it.
        let mark = sent.count
        _ = try await client.mergePeople(ids: ["a"], into: "c")
        let toB = RouteWire.requests.dropFirst(mark)
        XCTAssertEqual(toB.map { "\($0.method) \($0.host) \($0.path)" },
                       ["GET \(hostB) /api/server/version", "POST \(hostB) /api/people/c/merge"])
        XCTAssertEqual(toB.last?.authorization, "Bearer tok-b")
    }
}

// MARK: - AuthViewModel

@MainActor
final class ServerRouteCompatAuthTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "ServerRouteCompatAuthTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func makeAuth(
        mock: MockImmichClient, defaults: UserDefaults, keychain: MockKeychainStore = MockKeychainStore()
    ) -> AuthViewModel {
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        return auth
    }

    private let modern = ServerConfig(oauthButtonText: "Continue with Immich SSO", externalDomain: nil, isInitialized: nil)

    func test_AC_175_connectReadsPublicConfig() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.publicConfigResponse = modern
        let auth = makeAuth(mock: mock, defaults: defaults)

        await auth.connectServer()

        XCTAssertEqual(mock.publicConfigCalls, 1)
        XCTAssertEqual(mock.sessionConfigCalls, 0, "no session yet")
        XCTAssertEqual(auth.serverConfig, modern)
        XCTAssertTrue(auth.canOAuthLogin, "the SSO button follows the label of the public config")
    }

    func test_AC_175_loginReadsSessionConfigWhenDomainUnknown() async {
        for oauth in [false, true] {
            let (defaults, suite) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let mock = MockImmichClient()
            mock.publicConfigResponse = modern
            mock.sessionConfigResponse = ServerConfig(
                oauthButtonText: "Continue with Immich SSO", externalDomain: "https://photos.public.example", isInitialized: nil
            )
            let auth = makeAuth(mock: mock, defaults: defaults)
            await auth.connectServer()
            XCTAssertNil(auth.serverConfig?.externalDomain)

            if oauth {
                auth.oauthSessionHandler = { _ in URL(string: "app.immich:///oauth-callback?code=abc") }
                await auth.startOAuthFlow()
            } else {
                await auth.login(email: "a@example.com", password: "pw")
            }

            XCTAssertTrue(auth.isAuthenticated, "oauth: \(oauth)")
            XCTAssertEqual(mock.sessionConfigCalls, 1, "oauth: \(oauth)")
            XCTAssertEqual(auth.serverConfig?.externalDomain, "https://photos.public.example", "oauth: \(oauth)")
        }
    }

    func test_AC_175_loginSkipsSessionConfigWhenDomainKnown() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.publicConfigResponse = ServerConfig(oauthButtonText: "SSO", externalDomain: "", isInitialized: true)
        let auth = makeAuth(mock: mock, defaults: defaults)
        await auth.connectServer()

        await auth.login(email: "a@example.com", password: "pw")

        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertEqual(mock.sessionConfigCalls, 0, "a server before v3.2.0 already gave the domain")
    }

    func test_AC_175_failedSessionConfigKeepsPublicConfig() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.publicConfigResponse = modern
        let auth = makeAuth(mock: mock, defaults: defaults)
        await auth.connectServer()
        mock.sessionConfigGate = { throw APIError.network(URLError(.timedOut)) }

        await auth.login(email: "a@example.com", password: "pw")

        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertEqual(mock.sessionConfigCalls, 1)
        XCTAssertEqual(auth.serverConfig, modern, "the SSO label survives a failed read")
    }

    func test_AC_176_restoreReleasesHomeBeforeConfig() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        defaults.set("https://photos.example.com", forKey: AuthViewModel.serverURLDefaultsKey)
        keychain.saveToken("saved-jwt")
        let mock = MockImmichClient()
        mock.sessionConfigResponse = ServerConfig(
            oauthButtonText: "", externalDomain: "https://photos.public.example", isInitialized: nil
        )
        let latch = Latch()
        mock.sessionConfigGate = { await latch.wait() }
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults,
                                 realtime: RealtimeService(transport: MockRealtimeTransport()))

        let restoring = Task { await auth.restoreSession() }
        for _ in 0..<500 where mock.sessionConfigCalls == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertEqual(mock.sessionConfigCalls, 1, "the configuration is being read")
        XCTAssertFalse(auth.isRestoringSession, "home does not wait for the configuration")
        XCTAssertNil(auth.serverConfig)

        latch.open()
        await restoring.value
        XCTAssertEqual(auth.serverConfig?.externalDomain, "https://photos.public.example")
    }

    private func twoAccounts(defaults: UserDefaults, keychain: MockKeychainStore) -> SavedAccount {
        let alice = SavedAccount(url: "https://a.example.com", email: "alice@example.com", name: "Alice", userId: "u1", isAdmin: false)
        let bob = SavedAccount(url: "https://b.example.com", email: "bob@example.com", name: "Bob", userId: "u2", isAdmin: true)
        keychain.saveToken("alice-jwt", for: alice.id)
        keychain.saveToken("bob-jwt", for: bob.id)
        defaults.set(try! JSONEncoder.immich.encode([alice, bob]), forKey: AuthViewModel.serverListDefaultsKey)
        return bob
    }

    func test_AC_180_switchRereadsSessionConfig() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let bob = twoAccounts(defaults: defaults, keychain: keychain)
        let mock = MockImmichClient()
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://a.example.com"
        auth.accessToken = "alice-jwt"
        auth.serverConfig = ServerConfig(oauthButtonText: "A", externalDomain: "https://a.public", isInitialized: nil)
        mock.sessionConfigResponse = ServerConfig(oauthButtonText: "B", externalDomain: "https://b.public", isInitialized: nil)

        await auth.switchToAccount(bob)

        XCTAssertEqual(mock.sessionConfigCalls, 1)
        XCTAssertEqual(auth.serverConfig?.externalDomain, "https://b.public")

        // A read that fails leaves nothing — never the configuration of the previous account.
        let (defaults2, suite2) = makeDefaults()
        defer { defaults2.removePersistentDomain(forName: suite2) }
        let keychain2 = MockKeychainStore()
        let bob2 = twoAccounts(defaults: defaults2, keychain: keychain2)
        let failing = MockImmichClient()
        failing.sessionConfigGate = { throw APIError.network(URLError(.notConnectedToInternet)) }
        let auth2 = AuthViewModel(client: failing, keychain: keychain2, defaults: defaults2)
        auth2.serverURLString = "https://a.example.com"
        auth2.accessToken = "alice-jwt"
        auth2.serverConfig = ServerConfig(oauthButtonText: "A", externalDomain: "https://a.public", isInitialized: nil)

        await auth2.switchToAccount(bob2)

        XCTAssertNil(auth2.serverConfig, "the previous account's configuration is gone")
        XCTAssertTrue(auth2.isAuthenticated)
    }

    func test_AC_180_supersededSwitchConfigDropped() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let bob = twoAccounts(defaults: defaults, keychain: keychain)
        let mock = MockImmichClient()
        mock.sessionConfigResponse = ServerConfig(oauthButtonText: "B", externalDomain: "https://b.public", isInitialized: nil)
        let latch = Latch()
        mock.sessionConfigGate = { await latch.wait() }
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://a.example.com"
        auth.accessToken = "alice-jwt"

        let switching = Task { await auth.switchToAccount(bob) }
        for _ in 0..<500 where mock.sessionConfigCalls == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        // Another switch took over while B's configuration was in flight.
        auth.accessToken = "carol-jwt"
        latch.open()
        await switching.value

        XCTAssertNil(auth.serverConfig, "B's late answer does not land on another session")
    }
}
