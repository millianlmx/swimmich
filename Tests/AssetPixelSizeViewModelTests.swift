import XCTest
@testable import ImmichSwiftUI

/// L-06: a viewer page reads its photo's pixel size once, never blocks the image.
@MainActor
final class AssetPixelSizeViewModelTests: XCTestCase {

    private let viewport = CGSize(width: 393, height: 852)

    private func dto(id: String = "a1", exif: ExifResponseDto?, isEdited: Bool? = false) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T10:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T10:00:00.000Z", ownerId: "owner", originalPath: "/a.jpg",
            originalFileName: "a.jpg", fileCreatedAt: "2024-07-01T10:00:00.000Z",
            fileModifiedAt: "2024-07-01T10:00:00.000Z", updatedAt: "2024-07-01T10:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "abc", isEdited: isEdited, exifInfo: exif
        )
    }

    private func exif(_ w: Int?, _ h: Int?) -> ExifResponseDto {
        ExifResponseDto(exifImageWidth: w, exifImageHeight: h, orientation: "1")
    }

    /// A timeline grid item: no dimensions.
    private func gridItem(id: String = "a1") -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.3, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: "2024-07-01T10:00:00.000Z", fileCreatedAt: "2024-07-01T10:00:00.000Z",
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func maxScale(_ px: PixelSize?) -> CGFloat {
        ZoomGeometry.maxScale(pixelSize: px, viewport: viewport, displayScale: 3)
    }

    // MARK: - AC-109

    func test_AC_109_missingOrFailedReadKeepsNil() async {
        let noDims = MockImmichClient()
        noDims.getAssetResponse["a1"] = dto(exif: exif(nil, nil))
        let vm1 = AssetPixelSizeViewModel(asset: gridItem(), client: noDims)
        await vm1.load()
        XCTAssertNil(vm1.pixelSize)
        XCTAssertEqual(noDims.getAssetCalls, ["a1"])

        let failing = MockImmichClient()
        failing.globalError = URLError(.notConnectedToInternet)
        let vm2 = AssetPixelSizeViewModel(asset: gridItem(), client: failing)
        await vm2.load()
        XCTAssertNil(vm2.pixelSize)
        await vm2.load()
        XCTAssertEqual(failing.getAssetCalls.count, 1, "a failed read is not retried")

        // A shared-link visitor has no client: an edited item stays unknown.
        let edited = AssetReactItem(from: dto(exif: exif(8000, 6000), isEdited: true))
        let vm3 = AssetPixelSizeViewModel(asset: edited, client: nil)
        await vm3.load()
        XCTAssertNil(vm3.pixelSize)
        XCTAssertEqual(maxScale(vm3.pixelSize), 4)
    }

    // MARK: - AC-111

    func test_AC_111_sameSizeOnEverySurface() async {
        let record = dto(exif: exif(8000, 6000))
        let mock = MockImmichClient()
        mock.getAssetResponse["a1"] = record

        // Viewer page: grid item + the viewer's client.
        let viewer = AssetPixelSizeViewModel(asset: gridItem(), client: mock)
        await viewer.load()

        // Shared link: item built from the same record, no client.
        let link = AssetPixelSizeViewModel(asset: AssetReactItem(from: record), client: nil)
        await link.load()

        // Slideshow: grid item + the same client.
        let slideshow = AssetPixelSizeViewModel(asset: gridItem(), client: mock)
        await slideshow.load()

        XCTAssertEqual(viewer.pixelSize, PixelSize(width: 8000, height: 6000))
        XCTAssertEqual(link.pixelSize, viewer.pixelSize)
        XCTAssertEqual(slideshow.pixelSize, viewer.pixelSize)
        XCTAssertEqual(maxScale(link.pixelSize), maxScale(viewer.pixelSize))
        XCTAssertEqual(maxScale(slideshow.pixelSize), maxScale(viewer.pixelSize))
        XCTAssertEqual(mock.getAssetCalls, ["a1", "a1"], "the link item makes no request")
    }

    /// The viewer and the slideshow display the original, which the EXIF describes:
    /// an edited record read there keeps its native scale.
    func test_AC_111_editedAssetReadsOriginalInViewer() async {
        let mock = MockImmichClient()
        mock.getAssetResponse["a1"] = dto(exif: exif(8000, 6000), isEdited: true)
        let item = AssetReactItem(from: dto(exif: exif(8000, 6000), isEdited: true))
        XCTAssertNil(item.pixelSize)

        let vm = AssetPixelSizeViewModel(asset: item, client: mock)
        await vm.load()

        XCTAssertEqual(vm.pixelSize, PixelSize(width: 8000, height: 6000))
    }

    // MARK: - AC-114

    func test_AC_114_lateReadAndRetryAfterCancel() async {
        let mock = MockImmichClient()
        mock.getAssetResponse["a1"] = dto(exif: exif(400, 300))
        let latch = TestLatch()
        mock.getAssetGate = { _ in try await latch.wait() }
        let vm = AssetPixelSizeViewModel(asset: gridItem(), client: mock)

        let pending = Task { await vm.load() }
        await pollUntil("getAsset(a1)") { mock.getAssetCalls == ["a1"] }
        XCTAssertNil(vm.pixelSize, "the image is not waiting for the size")

        latch.open()
        await pending.value
        XCTAssertEqual(vm.pixelSize, PixelSize(width: 400, height: 300))
        XCTAssertEqual(maxScale(vm.pixelSize), 2, "a lower limit than the provisional 4x")

        await vm.load()
        XCTAssertEqual(mock.getAssetCalls.count, 1, "known size: no second request")

        // A cancelled read counts as not done: the next load retries.
        let cancelled = MockImmichClient()
        cancelled.getAssetResponse["a1"] = dto(exif: exif(8000, 6000))
        let calls = TestBox(0)
        cancelled.getAssetGate = { _ in
            calls.value += 1
            if calls.value == 1 { throw CancellationError() }
        }
        let retrying = AssetPixelSizeViewModel(asset: gridItem(), client: cancelled)
        await retrying.load()
        XCTAssertNil(retrying.pixelSize)
        await retrying.load()
        XCTAssertEqual(cancelled.getAssetCalls.count, 2)
        XCTAssertEqual(retrying.pixelSize, PixelSize(width: 8000, height: 6000))
        XCTAssertGreaterThan(maxScale(retrying.pixelSize), 4, "a higher limit than the provisional 4x")
    }
}
