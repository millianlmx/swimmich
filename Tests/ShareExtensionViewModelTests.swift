import XCTest
@testable import ImmichSwiftUI

/// The double the ViewModel is tested against. The view model is the only
/// thing in the extension that knows a transport exists, so a double of
/// `ShareUploading` is the whole seam — no network, no keychain, no extension
/// process. Kit symbols are reached through `@testable import ImmichSwiftUI`
/// alone: adding the framework's own module name here would make every shared
/// symbol ambiguous, since the kit is compiled twice.
final class RecordingUploader: ShareUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var _uploadedFilenames: [String] = []
    private var _attachedIds: [String] = []
    private var _attachedAlbumId: String?
    private var _calls = 0
    private var _failing: Set<String> = []
    private var _onUpload: (@MainActor (Int) -> Void)?

    /// Called on the main actor the moment an upload starts, with the zero-based
    /// call ordinal — this is how a test observes the state the row was in while
    /// its upload was in flight.
    var onUpload: (@MainActor (Int) -> Void)? {
        get { locked { _onUpload } }
        set { locked { _onUpload = newValue } }
    }

    var uploadedFilenames: [String] { locked { _uploadedFilenames } }
    var attachedIds: [String] { locked { _attachedIds } }
    var attachedAlbumId: String? { locked { _attachedAlbumId } }

    func fail(_ filename: String) {
        locked { _failing.insert(filename) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func upload(
        fileURL: URL,
        filename: String,
        createdAt: Date,
        modifiedAt: Date,
        duration: Int?,
        deviceAssetId: String
    ) async throws -> SharedUploadResult {
        let ordinal = locked { () -> Int in
            _uploadedFilenames.append(filename)
            _calls += 1
            return _calls - 1
        }
        if let onUpload { await onUpload(ordinal) }
        if locked({ _failing.contains(filename) }) {
            throw ShareUploadError.server(500, "nope")
        }
        return SharedUploadResult(id: "id-\(filename)", status: "created")
    }

    func albums() async throws -> [ShareAlbum] {
        [ShareAlbum(id: "alb1", albumName: "Trips")]
    }

    func addAssets(_ ids: [String], toAlbum albumId: String) async throws {
        locked {
            _attachedIds.append(contentsOf: ids)
            _attachedAlbumId = albumId
        }
    }
}

@MainActor
final class ShareExtensionViewModelTests: XCTestCase {

    private func makeItem(_ filename: String, selected: Bool = true) -> ShareItem {
        ShareItem(
            id: UUID(),
            filename: filename,
            fileURL: URL(fileURLWithPath: "/tmp/\(filename)"),
            isVideo: false,
            byteCount: 2048,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: nil,
            isSelected: selected,
            status: .enqueued
        )
    }

    private func makeViewModel(_ uploader: RecordingUploader, items: [ShareItem] = []) -> ShareExtensionViewModel {
        let model = ShareExtensionViewModel(
            uploader: uploader,
            stage: URL(fileURLWithPath: "/tmp"),
            serverLabel: "Millian · photos.local"
        )
        model.setItems(items)
        return model
    }

    func test_uploadAll_movesEachItemThroughRunningToComplete() async {
        let uploader = RecordingUploader()
        let model = makeViewModel(uploader, items: [makeItem("a.jpg"), makeItem("b.jpg")])
        var observedAtUploadStart: [ShareItemStatus] = []
        uploader.onUpload = { [weak model] ordinal in
            guard let model else { return }
            observedAtUploadStart.append(model.items[ordinal].status)
        }

        await model.uploadAll()

        // The rows were already "running" while their upload was in flight —
        // a queued item that never leaves `enqueued` is a sheet that looks hung.
        XCTAssertEqual(observedAtUploadStart.count, 2)
        for status in observedAtUploadStart {
            guard case .running = status else {
                XCTFail("expected a running state while the upload was in flight, got \(status)")
                return
            }
        }
        XCTAssertEqual(
            model.items.map(\.status),
            [.complete(assetId: "id-a.jpg"), .complete(assetId: "id-b.jpg")]
        )
        XCTAssertEqual(uploader.uploadedFilenames, ["a.jpg", "b.jpg"])
        XCTAssertFalse(model.isUploading)
        XCTAssertTrue(model.isFinished)
    }

    func test_uploadAll_skipsDeselectedItems() async {
        let uploader = RecordingUploader()
        let model = makeViewModel(uploader, items: [makeItem("a.jpg"), makeItem("b.jpg", selected: false)])

        await model.uploadAll()

        XCTAssertEqual(uploader.uploadedFilenames, ["a.jpg"])
        XCTAssertEqual(model.items[1].status, .enqueued)
    }

    func test_uploadAll_doesNotAttachAnythingWithoutAnAlbum() async {
        let uploader = RecordingUploader()
        let model = makeViewModel(uploader, items: [makeItem("a.jpg")])

        await model.uploadAll()

        XCTAssertNil(uploader.attachedAlbumId)
        XCTAssertTrue(uploader.attachedIds.isEmpty)
    }

    func test_uploadAll_attachesOnlyUploadedIdsToTheChosenAlbum() async {
        let uploader = RecordingUploader()
        uploader.fail("b.jpg")
        let model = makeViewModel(uploader, items: [makeItem("a.jpg"), makeItem("b.jpg")])
        model.selectedAlbumId = "alb1"

        await model.uploadAll()

        XCTAssertEqual(uploader.attachedIds, ["id-a.jpg"])
        XCTAssertEqual(uploader.attachedAlbumId, "alb1")
    }

    func test_uploadAll_keepsAFailedItemSelectedSoItCanBeRetried() async {
        let uploader = RecordingUploader()
        uploader.fail("a.jpg")
        let model = makeViewModel(uploader, items: [makeItem("a.jpg")])

        await model.uploadAll()

        XCTAssertEqual(model.items[0].status, .failed("nope"))
        XCTAssertTrue(model.items[0].isSelected)
        XCTAssertTrue(model.canUpload, "a failed item is still sendable")
        XCTAssertFalse(model.isFinished)
        XCTAssertNotNil(model.errorMessage)
    }

    func test_toggle_isIgnoredWhileAnUploadIsRunning() async {
        let uploader = RecordingUploader()
        let item = makeItem("a.jpg")
        let model = makeViewModel(uploader, items: [item])
        uploader.onUpload = { [weak model] _ in
            model?.toggle(item.id)
        }

        await model.uploadAll()

        XCTAssertTrue(model.items[0].isSelected)
    }

    /// B-21: the header, the send button and the failure message are plural
    /// entries of the catalog, so they follow the count in every language.
    func test_AC_32_4_headerButtonAndFailureFollowTheCount() async {
        for count in [1, 2] {
            let items = (0..<count).map { makeItem("a\($0).jpg") }
            let uploader = RecordingUploader()
            let model = makeViewModel(uploader, items: items)

            XCTAssertEqual(model.headerTitle, localizedString("Upload %lld items", count))
            XCTAssertEqual(model.primaryActionTitle, localizedString("Upload %lld items", count))

            for item in items { uploader.fail(item.filename) }
            await model.uploadAll()

            XCTAssertEqual(model.errorMessage, localizedString("%lld items could not be uploaded.", count))
        }
        // The two counts do not collapse into one text.
        XCTAssertNotEqual(
            localizedString("Upload %lld items", 1), localizedString("Upload %lld items", 2)
        )
    }
}
