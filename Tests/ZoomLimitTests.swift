import XCTest
@testable import ImmichSwiftUI

/// L-06: the viewer's zoom ceiling follows the photo's resolution; the pan stays
/// on the image. Pure geometry, no view.
@MainActor
final class ZoomLimitTests: XCTestCase {

    private let viewport = CGSize(width: 393, height: 852)
    private let displayScale: CGFloat = 3

    private func size(_ w: Int, _ h: Int) -> PixelSize { PixelSize(width: w, height: h)! }

    private func maxScale(_ pixels: PixelSize?) -> CGFloat {
        ZoomGeometry.maxScale(pixelSize: pixels, viewport: viewport, displayScale: displayScale)
    }

    private func dto(exif: ExifResponseDto?, isEdited: Bool? = false) -> AssetResponseDto {
        AssetResponseDto(
            id: "a1", type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T10:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T10:00:00.000Z", ownerId: "owner", originalPath: "/a.jpg",
            originalFileName: "a.jpg", fileCreatedAt: "2024-07-01T10:00:00.000Z",
            fileModifiedAt: "2024-07-01T10:00:00.000Z", updatedAt: "2024-07-01T10:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "abc", isEdited: isEdited, exifInfo: exif
        )
    }

    private func exif(_ w: Int?, _ h: Int?, orientation: String? = "1") -> ExifResponseDto {
        ExifResponseDto(exifImageWidth: w, exifImageHeight: h, orientation: orientation)
    }

    // MARK: - AC-16

    func test_AC_16_maxZoomFollowsResolution() {
        let hd = maxScale(size(8000, 6000))
        let small = maxScale(size(400, 300))

        XCTAssertGreaterThanOrEqual(hd, 6.78, "HD reaches at least its native scale")
        XCTAssertEqual(small, 2, accuracy: 0.0001)
        XCTAssertLessThan(small, hd)
    }

    // MARK: - AC-106

    func test_AC_106_nativeScaleIsTheCeiling() throws {
        let hd = size(8000, 6000)
        let native = try XCTUnwrap(ZoomGeometry.nativeScale(pixelSize: hd, viewport: viewport, displayScale: displayScale))

        XCTAssertEqual(native, 8000.0 / 1179.0, accuracy: 0.01)
        XCTAssertEqual(maxScale(hd), native, accuracy: 0.0001)
        XCTAssertGreaterThan(maxScale(hd), ZoomGeometry.unknownMaxScale, "no cap at the old 4x")
    }

    // MARK: - AC-107

    func test_AC_107_floorAndDoubleTapTarget() {
        let small = maxScale(size(400, 300))
        XCTAssertEqual(small, 2)
        XCTAssertGreaterThan(small, 1)
        XCTAssertLessThan(small, maxScale(size(8000, 6000)))

        XCTAssertEqual(ZoomGeometry.doubleTapTarget(maxScale: 2), 2)
        XCTAssertEqual(ZoomGeometry.doubleTapTarget(maxScale: 6.79), 3)
        XCTAssertEqual(ZoomGeometry.doubleTapTarget(maxScale: 4), 3)
    }

    /// A native scale between the floor and 4x is the ceiling itself; below the
    /// floor the floor wins.
    func test_AC_107_floorWinsOnlyBelowNative() {
        XCTAssertEqual(maxScale(size(1600, 1096)), 2, "native ≈ 1.36 sits under the floor")
        XCTAssertEqual(maxScale(size(3000, 2000)), max(3000.0 / 1179.0, 2), accuracy: 0.0001)
    }

    // MARK: - AC-108

    func test_AC_108_orientationSwapsDimensions() throws {
        for orientation in ["6", "8", "5", "7", "90", "-90"] {
            let px = try XCTUnwrap(PixelSize(exif: exif(8000, 6000, orientation: orientation)), orientation)
            XCTAssertEqual(px, size(6000, 8000), "orientation \(orientation)")
        }
        for orientation in ["1", "3", nil, "abc"] as [String?] {
            let px = try XCTUnwrap(PixelSize(exif: exif(8000, 6000, orientation: orientation)), orientation ?? "nil")
            XCTAssertEqual(px, size(8000, 6000), "orientation \(orientation ?? "nil")")
        }

        let portrait = maxScale(size(6000, 8000))
        XCTAssertEqual(portrait, 6000.0 / 1179.0, accuracy: 0.01)
        XCTAssertEqual(portrait, maxScale(try XCTUnwrap(PixelSize(exif: exif(8000, 6000, orientation: "6")))), accuracy: 0.0001)
        XCTAssertEqual(ZoomGeometry.fittedRect(aspect: size(6000, 8000).aspectRatio, in: viewport).height, 524, accuracy: 0.01)
    }

    // MARK: - AC-109

    func test_AC_109_unknownSizeKeepsFourX() {
        XCTAssertEqual(maxScale(nil), 4)
        XCTAssertNil(PixelSize(exif: nil))
        XCTAssertNil(PixelSize(exif: exif(nil, 6000)))
        XCTAssertNil(PixelSize(exif: exif(8000, nil)))
        XCTAssertNil(PixelSize(exif: exif(0, 6000)))
        XCTAssertNil(PixelSize(width: nil, height: 6000))
        XCTAssertNil(AssetReactItem(from: dto(exif: nil)).pixelSize)
        XCTAssertEqual(
            ZoomGeometry.maxScale(pixelSize: size(8000, 6000), viewport: .zero, displayScale: 3), 4,
            "an unusable viewport falls back to the default"
        )
    }

    func test_AC_109_editedAssetHasUnknownSize() {
        let e = exif(8000, 6000)
        let edited = AssetReactItem(from: dto(exif: e, isEdited: true))
        XCTAssertNil(edited.pixelSize)
        XCTAssertEqual(maxScale(edited.pixelSize), 4)

        XCTAssertEqual(AssetReactItem(from: dto(exif: e, isEdited: false)).pixelSize, size(8000, 6000))
        XCTAssertEqual(AssetReactItem(from: dto(exif: e, isEdited: nil)).pixelSize, size(8000, 6000))
    }

    // MARK: - AC-110

    func test_AC_110_ocrRectFollowsRealAspect() {
        let pixels = size(8000, 6000)
        // A grid item built from a full record has ratio 1.0 (square).
        let aspect = ZoomGeometry.displayAspect(decoded: nil, pixelSize: pixels, fallback: 1)
        let fitted = ZoomGeometry.fittedRect(aspect: aspect, in: viewport)

        XCTAssertEqual(fitted.width, 393, accuracy: 0.01)
        XCTAssertEqual(fitted.height, 294.75, accuracy: 0.01)
        XCTAssertEqual(fitted.minY, (852 - 294.75) / 2, accuracy: 0.01)

        let scale: CGFloat = 8000.0 / 1179.0
        let bound = ZoomGeometry.clampedOffset(
            CGSize(width: 5000, height: -5000), scale: scale, fitted: fitted.size, viewport: viewport
        )
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)] {
            let p = CGPoint(x: fitted.minX + corner.x * fitted.width, y: fitted.minY + corner.y * fitted.height)
            let expected = CGPoint(
                x: center.x + (p.x - center.x) * scale + bound.width,
                y: center.y + (p.y - center.y) * scale + bound.height
            )
            let actual = OcrOverlayView.screenPoint(
                corner, imageRect: fitted, scale: scale, offset: bound, viewport: viewport
            )
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.01)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.01)
        }
    }

    // MARK: - AC-111

    func test_AC_111_sharedAlbumRequestsExif() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let client = ImmichAPIClient(session: URLSession(configuration: config))
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = Data(#"{"assets":{"count":0,"items":[],"nextPage":null}}"#.utf8)
        defer { CapturingURLProtocol.reset() }

        _ = try await client.getSharedLinkAlbumAssets(.key("k"), albumId: "alb-1", page: 1, size: 50)

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: CapturingURLProtocol.lastBody) as? [String: Any]
        )
        XCTAssertEqual(body["withExif"] as? Bool, true)
        XCTAssertEqual(body["albumIds"] as? [String], ["alb-1"])
    }

    // MARK: - AC-112

    func test_AC_112_panBoundOnFittedImage() {
        let fitted = ZoomGeometry.fittedRect(aspect: 4.0 / 3.0, in: viewport).size
        let huge = CGSize(width: 9999, height: 9999)

        let at2 = ZoomGeometry.clampedOffset(huge, scale: 2, fitted: fitted, viewport: viewport)
        XCTAssertEqual(at2.width, 196.5, accuracy: 0.1)
        XCTAssertEqual(at2.height, 0, accuracy: 0.1, "zoomed image still shorter than the screen: centered")

        let at4 = ZoomGeometry.clampedOffset(huge, scale: 4, fitted: fitted, viewport: viewport)
        XCTAssertEqual(at4.width, 589.5, accuracy: 0.1)
        XCTAssertEqual(at4.height, 163.5, accuracy: 0.1)

        let native: CGFloat = 8000.0 / 1179.0
        let atNative = ZoomGeometry.clampedOffset(
            CGSize(width: -9999, height: -9999), scale: native, fitted: fitted, viewport: viewport
        )
        XCTAssertEqual(atNative.width, -1136.8, accuracy: 0.1)
        XCTAssertEqual(atNative.height, -574.0, accuracy: 0.01, "(294.75 × 8000/1179 − 852) / 2 = 574 exactly")

        // Zooming out after a pan re-bounds the offset.
        let settled = ZoomGeometry.settled(
            scale: 4, offset: CGSize(width: 589.5, height: 163.5), maxScale: 4, fitted: fitted, viewport: viewport
        )
        let out = ZoomGeometry.settled(
            scale: 2, offset: settled.offset, maxScale: 4, fitted: fitted, viewport: viewport
        )
        XCTAssertEqual(out.offset.width, 196.5, accuracy: 0.1)
        XCTAssertEqual(out.offset.height, 0, accuracy: 0.1)
    }

    func test_AC_112_boundFollowsDisplayedImage() {
        let pixels = size(8000, 6000)
        XCTAssertEqual(ZoomGeometry.displayAspect(decoded: CGSize(width: 600, height: 800), pixelSize: pixels, fallback: 1), 0.75, accuracy: 0.0001)
        XCTAssertEqual(ZoomGeometry.displayAspect(decoded: nil, pixelSize: pixels, fallback: 1), 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(ZoomGeometry.displayAspect(decoded: CGSize(width: 0, height: 800), pixelSize: pixels, fallback: 1), 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(ZoomGeometry.displayAspect(decoded: nil, pixelSize: nil, fallback: 1), 1)

        // Decoded 3:4 image (a server-rotated preview) in 393×852 at 2x.
        let fitted = ZoomGeometry.fittedRect(aspect: 0.75, in: viewport).size
        XCTAssertEqual(fitted.width, 393, accuracy: 0.01)
        XCTAssertEqual(fitted.height, 524, accuracy: 0.01)
        let bound = ZoomGeometry.clampedOffset(CGSize(width: 9999, height: 9999), scale: 2, fitted: fitted, viewport: viewport)
        XCTAssertEqual(bound.width, 196.5, accuracy: 0.1)
        XCTAssertEqual(bound.height, 98, accuracy: 0.1)

        // The EXIF 4:3 rect would have centered the vertical axis and hidden 98 pt of the photo.
        let wrong = ZoomGeometry.fittedRect(aspect: 4.0 / 3.0, in: viewport).size
        XCTAssertEqual(ZoomGeometry.clampedOffset(CGSize(width: 0, height: 9999), scale: 2, fitted: wrong, viewport: viewport).height, 0, accuracy: 0.1)
    }

    // MARK: - AC-113

    func test_AC_113_releaseUnderThresholdSnapsBack() {
        let fitted = ZoomGeometry.fittedRect(aspect: 4.0 / 3.0, in: viewport).size
        let rest = ZoomGeometry.settled(
            scale: 1.04, offset: CGSize(width: 10, height: 0), maxScale: 4, fitted: fitted, viewport: viewport
        )
        XCTAssertEqual(rest.scale, 1)
        XCTAssertEqual(rest.offset, .zero)

        let kept = ZoomGeometry.settled(
            scale: 1.06, offset: .zero, maxScale: 4, fitted: fitted, viewport: viewport
        )
        XCTAssertEqual(kept.scale, 1.06, accuracy: 0.0001)
    }

    // MARK: - AC-114

    func test_AC_114_settleOnLateLimit() {
        let fitted = ZoomGeometry.fittedRect(aspect: 4.0 / 3.0, in: viewport).size

        // 400×300 zoomed to 4x under the provisional limit; its size then arrives.
        let lowered = ZoomGeometry.settled(
            scale: 4, offset: CGSize(width: 589.5, height: 163.5), maxScale: 2, fitted: fitted, viewport: viewport
        )
        XCTAssertEqual(lowered.scale, 2)
        XCTAssertEqual(lowered.offset.width, 196.5, accuracy: 0.1)
        XCTAssertEqual(lowered.offset.height, 0, accuracy: 0.1)

        // 8000×6000 stuck at 4x: a higher limit changes nothing, the next pinch reaches it.
        let raised = ZoomGeometry.settled(
            scale: 4, offset: CGSize(width: 100, height: 50), maxScale: 6.785, fitted: fitted, viewport: viewport
        )
        XCTAssertEqual(raised.scale, 4)
        XCTAssertEqual(raised.offset, CGSize(width: 100, height: 50))
    }
}
