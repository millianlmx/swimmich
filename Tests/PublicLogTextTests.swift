import XCTest
@testable import ImmichSwiftUI

/// Need B-15, part 4: what the app, its widgets and its share extension confide
/// to `os.Logger` with `privacy: .public` names the shape of an error, never a
/// string the error carries (a URL, a token, a response body).
///
/// A test cannot read another process's system log, so the lines are read where
/// the code hands them over: the injected `publicLog` / `log` of each surface.
final class PublicLogTextTests: XCTestCase {

    // MARK: - Doubles

    private static let host = "photos.example.org"
    private static let token = "session-token-9f3a7c1d"

    /// A transport error the way a real one can look: the failing URL in its
    /// `userInfo`, and a localized text that quotes the host and the token.
    private static func transportError() -> NSError {
        NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey: "https://\(host)/api/assets?key=\(token)",
                NSLocalizedDescriptionKey: "Could not connect to https://\(host)/api/x with Bearer \(token)"
            ]
        )
    }

    private final class LineRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []

        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return items
        }

        func append(_ line: String) {
            lock.lock(); items.append(line); lock.unlock()
        }
    }

    private struct ThrowingTransport: WidgetDataTransport {
        let error: Error
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw error }
    }

    private struct StubSessionStore: WidgetSessionStoring {
        let session: WidgetSession?
        func save(_ session: WidgetSession) {}
        func load() -> WidgetSession? { session }
        func clear() {}
    }

    private final class FailingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: PublicLogTextTests.transportError())
        }
        override func stopLoading() {}
    }

    private enum Free: Error, CustomStringConvertible {
        case quoting(String)
        var description: String { "quoting photos.example.org" }
    }

    private indirect enum Nest: Error {
        case inner(Nest)
        case leaf
    }

    private enum Wrap: Error {
        case around(Error)
    }

    private func assertClean(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains(Self.host), "leaks the host: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains(Self.token), "leaks the token: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("Bearer"), "leaks free text: \(text)", file: file, line: line)
    }

    private let session = WidgetSession(baseURL: "https://photos.example.org", token: PublicLogTextTests.token)

    // MARK: - The pure function

    func test_AC_132_describeKeepsCodeDropsUrlAndToken() {
        let urlError = URLError(
            .cannotConnectToHost,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey: "https://\(Self.host)/api/assets?key=\(Self.token)",
                NSLocalizedDescriptionKey: "Could not connect to \(Self.host) with \(Self.token)"
            ]
        )
        XCTAssertEqual(PublicLogText.describe(urlError), "URLError -1004")
        XCTAssertEqual(PublicLogText.describe(Self.transportError()), "URLError -1004", "the same error, as an NSError")

        XCTAssertEqual(PublicLogText.describe(APIError.network(urlError)), "APIError.network(URLError -1004)")
        XCTAssertEqual(PublicLogText.describe(APIError.serverError(500, Self.token)), "APIError.serverError(500)")
        XCTAssertEqual(PublicLogText.describe(APIError.unauthorized), "APIError.unauthorized")

        let cancelled = CancellationError() as NSError
        XCTAssertEqual(PublicLogText.describe(CancellationError()), "\(cancelled.domain) \(cancelled.code)")

        for error in [urlError as Error, APIError.network(urlError), APIError.serverError(500, Self.token)] {
            assertClean(PublicLogText.describe(error))
        }
    }

    func test_AC_132_describeNeverPrintsTheTextOfASelfPrintingErrorNorTooDeepANest() {
        let free = Free.quoting(Self.token) as NSError
        XCTAssertEqual(PublicLogText.describe(Free.quoting(Self.token)), "\(free.domain) \(free.code)")

        var nest: Nest = .leaf
        for _ in 0..<8 { nest = .inner(nest) }
        let described = PublicLogText.describe(nest)
        XCTAssertTrue(described.contains("…"), "recursion is bounded: \(described)")

        XCTAssertTrue(
            PublicLogText.describe(Wrap.around(URLError(.timedOut))).hasSuffix("around(URLError -1001)")
        )
    }

    // MARK: - Widgets

    func test_AC_132_widgetLoadLinesCarryCodeOnly() async {
        let recorder = LineRecorder()
        let provider = WidgetDataProvider(
            sessionStore: StubSessionStore(session: session),
            transport: { ThrowingTransport(error: Self.transportError()) },
            publicLog: { recorder.append($0) }
        )

        _ = await provider.memories(limit: 3, offset: 0)
        _ = await provider.recentPhotos(limit: 3)

        let lines = recorder.lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.contains { $0.hasPrefix("memories fetch failed:") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("wall fetch failed:") })
        for line in lines {
            XCTAssertTrue(line.contains("-1004"), line)
            assertClean(line)
        }
    }

    func test_AC_132_favoriteWriteLineCarriesCodeOnly() async {
        let recorder = LineRecorder()

        await ToggleFavoriteIntent.write(
            assetId: "a1",
            favorite: true,
            sessionStore: StubSessionStore(session: session),
            transport: ThrowingTransport(error: Self.transportError()),
            reloadTimelines: { _ in },
            log: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.lines.count, 1)
        XCTAssertEqual(recorder.lines.first, "favorite write failed for asset a1: URLError -1004")
    }

    // MARK: - Share extension

    func test_AC_132_shareExtensionLineCarriesCodeOnly() async throws {
        let recorder = LineRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingProtocol.self]
        let client = SharedUploadClient(
            baseURL: "https://\(Self.host)", token: Self.token, deviceId: "device-1",
            session: URLSession(configuration: config), publicLog: { recorder.append($0) }
        )
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("public-log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("photo.jpg")
        try Data(repeating: 0x41, count: 64).write(to: file)

        do {
            _ = try await client.upload(
                fileURL: file, filename: "photo.jpg",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: nil, deviceAssetId: "share/1"
            )
            XCTFail("a transport failure must surface")
        } catch {
            // Expected: the line is what is under test.
        }

        XCTAssertEqual(recorder.lines, ["share upload transport failed: -1004"])
        assertClean(recorder.lines.joined())
    }
}
