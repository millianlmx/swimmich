import XCTest
import UIKit
import CoreImage
import ImageIO
@testable import ImmichSwiftUI

/// Shared fixtures for the editor's save-copy tests (`EditorViewModelTests`, `EditedImageRendererTests`).
enum EditorTestSupport {

    enum Corner: Equatable { case topLeft, topRight, bottomLeft, bottomRight }

    /// Opaque blue bitmap with a red square in the RAW top-left corner and a green one in the RAW
    /// top-right corner (side = 1/8 of the smaller dimension). Two adjacent markers tell the 8 EXIF
    /// orientations apart, mirrors included.
    static func rawImage(width: Int, height: Int, orientation: UIImage.Orientation = .up) -> UIImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let side = CGFloat(min(width, height)) / 8
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: CGFloat(height) - side, width: side, height: side))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: CGFloat(width) - side, y: CGFloat(height) - side, width: side, height: side))
        return UIImage(cgImage: ctx.makeImage()!, scale: 1, orientation: orientation)
    }

    /// RGBA of the pixel at (x, y), y counted from the top.
    static func pixel(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }

    /// Corner of each marker, in the UPRIGHT image (orientation applied by UIKit). nil = not found.
    static func markerCorners(of image: UIImage) -> (red: Corner?, green: Corner?) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage!
        let inset = 4
        let spots: [(Corner, Int, Int)] = [
            (.topLeft, inset, inset), (.topRight, upright.width - 1 - inset, inset),
            (.bottomLeft, inset, upright.height - 1 - inset),
            (.bottomRight, upright.width - 1 - inset, upright.height - 1 - inset)
        ]
        var red: Corner?
        var green: Corner?
        for (corner, x, y) in spots {
            let p = pixel(of: upright, x: x, y: y)
            if p.r > p.g + 80 && p.r > p.b + 80 { red = corner }
            if p.g > p.r + 80 && p.g > p.b + 80 { green = corner }
        }
        return (red, green)
    }

    struct DecodedJPEG {
        let width: Int
        let height: Int
        let orientation: Int
        let exif: [String: Any]
        let hasGPS: Bool
    }

    static func decodeJPEG(_ data: Data) -> DecodedJPEG? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return DecodedJPEG(
            width: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
            height: props[kCGImagePropertyPixelHeight] as? Int ?? 0,
            orientation: props[kCGImagePropertyOrientation] as? Int ?? 1,
            exif: props[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:],
            hasGPS: props[kCGImagePropertyGPSDictionary] != nil)
    }

    static func makeAssetDTO(fileName: String = "IMG_0001.HEIC",
                             localDateTime: String = "2024-07-01T01:30:00.000Z",
                             fileCreatedAt: String = "2024-06-30T23:30:00.000Z",
                             fileModifiedAt: String = "2024-07-02T10:00:00.000Z") -> AssetResponseDto {
        AssetResponseDto(
            id: "asset-1", type: "IMAGE", thumbhash: nil, localDateTime: localDateTime,
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: fileCreatedAt,
            ownerId: "owner", originalPath: "/mnt/media/\(fileName)", originalFileName: fileName,
            fileCreatedAt: fileCreatedAt, fileModifiedAt: fileModifiedAt,
            updatedAt: fileCreatedAt, isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false
        )
    }
}

@MainActor
final class EditedImageRendererTests: XCTestCase {

    private typealias Support = EditorTestSupport

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditedImageRendererTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func metadata() throws -> EditedCopyMetadata {
        try EditedCopyMetadata(asset: Support.makeAssetDTO())
    }

    /// Preview of `raw` through the real VM render path, after an exposure-only edit.
    private func renderPreview(of raw: UIImage, configure: (PhotoEditorViewModel) -> Void) -> (UIImage, EditState) {
        let vm = PhotoEditorViewModel(assetId: "asset-1", client: MockImmichClient())
        vm.originalImage = raw
        configure(vm)
        return (vm.previewImage!, vm.editState)
    }

    // MARK: AC-4

    func test_AC4_propertyOrientationTable() {
        let table: [(UIImage.Orientation, CGImagePropertyOrientation)] = [
            (.up, .up), (.down, .down), (.left, .left), (.right, .right),
            (.upMirrored, .upMirrored), (.downMirrored, .downMirrored),
            (.leftMirrored, .leftMirrored), (.rightMirrored, .rightMirrored)
        ]
        for (ui, cg) in table {
            XCTAssertEqual(EditedImageRenderer.propertyOrientation(ui), cg, "\(ui.rawValue)")
        }
    }

    func test_AC4_allEightOrientations_matchPreview() throws {
        let all: [UIImage.Orientation] = [.up, .down, .left, .right,
                                          .upMirrored, .downMirrored, .leftMirrored, .rightMirrored]
        let meta = try metadata()
        for orientation in all {
            let raw = Support.rawImage(width: 400, height: 300, orientation: orientation)
            let (preview, state) = renderPreview(of: raw) { $0.setExposure(0.2) }
            let url = tempDirectory().appendingPathComponent("out.jpg")
            try EditedImageRenderer.writeJPEG(cgImage: raw.cgImage!, orientation: orientation,
                                              state: state, metadata: meta, to: url)
            let data = try Data(contentsOf: url)
            let decoded = try XCTUnwrap(Support.decodeJPEG(data))
            XCTAssertEqual(decoded.width, Int(preview.size.width * preview.scale), "\(orientation.rawValue)")
            XCTAssertEqual(decoded.height, Int(preview.size.height * preview.scale), "\(orientation.rawValue)")
            let expected = Support.markerCorners(of: preview)
            let actual = Support.markerCorners(of: try XCTUnwrap(UIImage(data: data)))
            XCTAssertNotNil(expected.red)
            XCTAssertNotNil(expected.green)
            XCTAssertEqual(actual.red, expected.red, "red marker, orientation \(orientation.rawValue)")
            XCTAssertEqual(actual.green, expected.green, "green marker, orientation \(orientation.rawValue)")
        }
    }

    func test_AC4_straighten_cornersBlack_matchesPreview() throws {
        let raw = Support.rawImage(width: 400, height: 300)
        let (preview, state) = renderPreview(of: raw) { $0.setStraighten(10) }
        let previewCorner = Support.pixel(of: preview.cgImage!, x: 0, y: 0)
        XCTAssertEqual(previewCorner.a, 255)
        XCTAssertLessThanOrEqual(max(previewCorner.r, previewCorner.g, previewCorner.b), 16)

        let url = tempDirectory().appendingPathComponent("out.jpg")
        try EditedImageRenderer.writeJPEG(cgImage: raw.cgImage!, orientation: .up,
                                          state: state, metadata: try metadata(), to: url)
        let data = try Data(contentsOf: url)
        let decoded = try XCTUnwrap(Support.decodeJPEG(data))
        XCTAssertEqual(decoded.width, preview.cgImage!.width)
        XCTAssertEqual(decoded.height, preview.cgImage!.height)
        let corner = Support.pixel(of: try XCTUnwrap(UIImage(data: data)?.cgImage), x: 0, y: 0)
        XCTAssertLessThanOrEqual(max(corner.r, corner.g, corner.b), 16)
    }

    // MARK: AC-10 / AC-11 (renderer contract shared by Save and Save to Photos)
    // The Save to Photos action itself is proven in EditorViewModelTests:
    // test_AC10_saveToPhotos_writesJPEG_noUpload_confirms, test_AC11_saveToPhotos_failure_isExplicit_andRetryable,
    // test_AC23_photosJPEG_matchesSaveCopy (orientation).

    func test_AC10_AC11_rendererIsClientIndependent() throws {
        let raw = Support.rawImage(width: 400, height: 300)
        let (preview, state) = renderPreview(of: raw) { $0.setExposure(0.3) }
        let url = tempDirectory().appendingPathComponent("photos.jpg")
        try EditedImageRenderer.writeJPEG(cgImage: raw.cgImage!, orientation: .up,
                                          state: state, metadata: try metadata(), to: url)
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty)
        let decoded = try XCTUnwrap(Support.decodeJPEG(data))
        XCTAssertEqual(decoded.width, Int(preview.size.width))
        XCTAssertEqual(decoded.height, Int(preview.size.height))

        let blocker = tempDirectory().appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        XCTAssertThrowsError(try EditedImageRenderer.writeJPEG(
            cgImage: raw.cgImage!, orientation: .up, state: state, metadata: try metadata(),
            to: blocker.appendingPathComponent("sub/out.jpg"))) { error in
            XCTAssertEqual(error as? EditorSaveError, .fileWriteFailed)
        }
    }

    // MARK: AC-18 (JPEG content)

    func test_AC18_writeJPEG_carriesDateOffsetAndNoGPS() throws {
        let raw = Support.rawImage(width: 64, height: 48)
        let url = tempDirectory().appendingPathComponent("dates.jpg")
        try EditedImageRenderer.writeJPEG(cgImage: raw.cgImage!, orientation: .up,
                                          state: EditState(exposure: 0.2), metadata: try metadata(), to: url)
        let decoded = try XCTUnwrap(Support.decodeJPEG(Data(contentsOf: url)))
        XCTAssertEqual(decoded.exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2024:07:01 01:30:00")
        XCTAssertEqual(decoded.exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String, "+02:00")
        XCTAssertEqual(decoded.exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String, "000")
        XCTAssertFalse(decoded.hasGPS)
        XCTAssertEqual(decoded.orientation, 1)
    }

    func test_AC18_metadata_offsets() throws {
        func offset(local: String, created: String) throws -> String {
            try EditedCopyMetadata(asset: Support.makeAssetDTO(localDateTime: local, fileCreatedAt: created)).offsetTimeOriginal
        }
        XCTAssertEqual(try offset(local: "2024-07-01T01:30:00.000Z", created: "2024-06-30T23:30:00.000Z"), "+02:00")
        XCTAssertEqual(try offset(local: "2024-07-01T00:00:00.000Z", created: "2024-07-01T03:30:00.000Z"), "-03:30")
        XCTAssertEqual(try offset(local: "2024-07-01T05:45:00.000Z", created: "2024-07-01T00:00:00.000Z"), "+05:45")
        XCTAssertEqual(try offset(local: "2024-07-01T00:00:00.000Z", created: "2024-07-01T00:00:00.000Z"), "+00:00")
    }

    func test_AC18_metadata_fieldsAndErrors() throws {
        let m = try EditedCopyMetadata(asset: Support.makeAssetDTO(localDateTime: "2024-07-01T01:30:05.678Z"))
        XCTAssertEqual(m.dateTimeOriginal, "2024:07:01 01:30:05")
        XCTAssertEqual(m.subsecTimeOriginal, "678")
        let noFraction = try EditedCopyMetadata(asset: Support.makeAssetDTO(localDateTime: "2024-07-01T01:30:05Z"))
        XCTAssertEqual(noFraction.subsecTimeOriginal, "000")

        XCTAssertThrowsError(try EditedCopyMetadata(asset: Support.makeAssetDTO(localDateTime: "garbage"))) {
            XCTAssertEqual($0 as? EditorSaveError, .metadataUnavailable)
        }
        XCTAssertThrowsError(try EditedCopyMetadata(asset: Support.makeAssetDTO(fileCreatedAt: ""))) {
            XCTAssertEqual($0 as? EditorSaveError, .metadataUnavailable)
        }
        XCTAssertThrowsError(try EditedCopyMetadata(asset: Support.makeAssetDTO(fileName: ""))) {
            XCTAssertEqual($0 as? EditorSaveError, .metadataUnavailable)
        }
    }

    func test_AC3_metadata_fileNames() throws {
        func name(_ original: String) throws -> String {
            try EditedCopyMetadata(asset: Support.makeAssetDTO(fileName: original)).fileName
        }
        XCTAssertEqual(try name("IMG_0001.HEIC"), "IMG_0001_edited.jpg")
        XCTAssertEqual(try name("a.b.png"), "a.b_edited.jpg")
        XCTAssertEqual(try name("noext"), "noext_edited.jpg")
    }
}
