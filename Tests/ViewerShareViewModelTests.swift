import XCTest
@testable import ImmichSwiftUI

/// Viewer share (B-31): the file a share hands to the iOS sheet is the photo in
/// the quality that was asked for, named like the original, streamed to disk;
/// a failure or a cancellation shares nothing and leaves no file behind.
@MainActor
final class ViewerShareViewModelTests: XCTestCase {

    /// Holds a transfer in flight until a test lets it go.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    next.resume()
                } else {
                    continuation = next
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    /// Reports half of the body, then waits: the model's fraction is observable.
    private final class HalfwayTransport: FileDownloadTransport, @unchecked Sendable {
        let gate = Gate()

        func download(
            _ request: URLRequest, onProgress: @escaping @Sendable (Int64, Int64) -> Void
        ) async throws -> DownloadedFile {
            onProgress(50, 100)
            await gate.wait()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("halfway-\(UUID().uuidString)")
            try Data("body".utf8).write(to: url)
            return DownloadedFile(url: url, statusCode: 200, contentType: "image/jpeg")
        }
    }

    /// What the iOS share sheet was handed.
    private final class Presenter {
        private(set) var items: [[Any]] = []
        private(set) var completions: [(() -> Void)?] = []

        func present(_ items: [Any], _ completion: (() -> Void)?) {
            self.items.append(items)
            completions.append(completion)
        }

        var urls: [URL] { items.flatMap { $0.compactMap { $0 as? URL } } }
    }

    private let baseURL = URL(string: "https://example.com")!
    private var transport: MockFileDownloadTransport!
    private var client: MockImmichClient!
    private var presenter: Presenter!

    override func setUp() {
        super.setUp()
        transport = MockFileDownloadTransport()
        client = MockImmichClient()
        presenter = Presenter()
        client.getAssetResponse["p1"] = detail(id: "p1", name: "IMG_0001.HEIC", mime: "image/heic")
        client.getAssetResponse["v1"] = detail(id: "v1", name: "IMG_0002.MOV", mime: "video/quicktime")
    }

    private func detail(id: String, name: String, mime: String) -> AssetResponseDto {
        var dto = AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T00:00:00.000Z", ownerId: "owner", originalPath: "/x",
            originalFileName: name, fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z", updatedAt: "2024-07-01T00:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "abc", isEdited: false
        )
        dto.originalMimeType = mime
        return dto
    }

    private func asset(_ id: String, isVideo: Bool = false) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 0.75, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: !isVideo, thumbhash: "thumb",
            createdAt: "2024-07-01T10:00:00.000Z", fileCreatedAt: "2024-07-01T10:00:00.000Z",
            localOffsetHours: 0, duration: isVideo ? 12 : nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func makeViewModel(transport: any FileDownloadTransport? = nil) -> ViewerShareViewModel {
        ViewerShareViewModel(
            client: client, baseURL: baseURL, token: "tok",
            transport: transport ?? self.transport,
            customHeaders: NoCustomHeaders(),
            presentShare: { [presenter] items, done in presenter!.present(items, done) }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "condition not reached in 5 s")
    }

    private func shareDirectories() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(names.filter { $0.hasPrefix("immich-share-") })
    }

    // MARK: - Quality

    func test_AC_271_originalStreamsOriginalAndNamesFileLikeIt() async throws {
        let vm = makeViewModel()

        vm.share(asset("p1"), quality: .original)
        await vm.waitForCompletion()

        XCTAssertEqual(transport.downloadCount, 1, "one request, no preview alongside")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/assets/p1/original")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let file = try XCTUnwrap(presenter.urls.first)
        XCTAssertEqual(file.lastPathComponent, "IMG_0001.HEIC")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(vm.phase, .idle)

        // The iOS sheet closing removes the whole temporary folder.
        try XCTUnwrap(presenter.completions.first ?? nil)()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    func test_AC_271_previewAsksForPreviewThumbnail() async throws {
        transport.contentType = "image/jpeg"
        let vm = makeViewModel()

        vm.share(asset("p1"), quality: .preview)
        await vm.waitForCompletion()

        let url = try XCTUnwrap(transport.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/assets/p1/thumbnail")
        let size = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "size" }?.value
        XCTAssertEqual(size, "preview")
        XCTAssertEqual(presenter.urls.first?.lastPathComponent, "IMG_0001.jpg", "the extension follows the bytes sent")
        try XCTUnwrap(presenter.completions.first ?? nil)()
    }

    func test_AC_271_videoIsAlwaysOriginal() async throws {
        transport.contentType = "video/quicktime"
        let vm = makeViewModel()

        vm.share(asset("v1", isVideo: true), quality: .preview)
        await vm.waitForCompletion()

        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/assets/v1/original")
        XCTAssertEqual(presenter.urls.first?.lastPathComponent, "IMG_0002.MOV")
        try XCTUnwrap(presenter.completions.first ?? nil)()
    }

    func test_AC_272_choicesForPhotoAndVideo() {
        XCTAssertEqual(ViewerShareViewModel.choices(for: asset("p1")), [.original, .preview])
        XCTAssertEqual(ViewerShareViewModel.choices(for: asset("v1", isVideo: true)), [.original])
    }

    // MARK: - Failure

    func test_AC_279_serverErrorShowsMessageAndNoSheet() async throws {
        transport.statusCode = 500
        let vm = makeViewModel()

        vm.share(asset("p1"), quality: .original)
        await vm.waitForCompletion()

        guard case .failed(let message) = vm.phase else { return XCTFail("expected .failed, got \(vm.phase)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(presenter.items.isEmpty, "no iOS sheet on a failure")
        let received = try XCTUnwrap(transport.lastFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: received.path), "the error body is deleted")

        vm.dismissError()
        XCTAssertEqual(vm.phase, .idle)
    }

    func test_AC_279_transportErrorShowsMessage() async {
        transport.error = URLError(.timedOut)
        let vm = makeViewModel()

        vm.share(asset("p1"), quality: .preview)
        await vm.waitForCompletion()

        guard case .failed = vm.phase else { return XCTFail("expected .failed, got \(vm.phase)") }
        XCTAssertTrue(presenter.items.isEmpty)
    }

    // MARK: - Progress and cancellation

    func test_AC_280_progressIsReported() async throws {
        let halfway = HalfwayTransport()
        let vm = makeViewModel(transport: halfway)

        vm.share(asset("p1"), quality: .original)
        try await waitUntil { vm.phase == .downloading(fraction: 0.5) }

        halfway.gate.open()
        await vm.waitForCompletion()
        XCTAssertEqual(vm.phase, .idle)
        try XCTUnwrap(presenter.completions.first ?? nil)()
    }

    /// The transport ignores the cancellation (it waits on a gate that does not
    /// throw) and then hands a finished file back, as a real one can when the
    /// cancel lands at the end. The same path serves the viewer's closing.
    func test_AC_280_cancelSharesNothing() async throws {
        let gate = Gate()
        transport.gate = { await gate.wait() }
        let before = shareDirectories()
        let vm = makeViewModel()

        vm.share(asset("p1"), quality: .original)
        try await waitUntil { self.transport.downloadCount == 1 }
        vm.cancel()
        gate.open()
        await vm.waitForCompletion()

        XCTAssertEqual(vm.phase, .idle, "a cancellation is not a failure")
        XCTAssertTrue(presenter.items.isEmpty, "nothing is presented")
        let received = try XCTUnwrap(transport.lastFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: received.path))
        XCTAssertEqual(shareDirectories(), before, "no share folder left behind")
    }

    func test_AC_280_secondShareWhileDownloadingIsIgnored() async throws {
        let gate = Gate()
        transport.gate = { await gate.wait() }
        let vm = makeViewModel()

        vm.share(asset("p1"), quality: .original)
        try await waitUntil { self.transport.downloadCount == 1 }
        vm.share(asset("p1"), quality: .preview)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transport.downloadCount, 1)

        gate.open()
        await vm.waitForCompletion()
        XCTAssertEqual(presenter.items.count, 1)
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/assets/p1/original")
        try XCTUnwrap(presenter.completions.first ?? nil)()
    }
}
