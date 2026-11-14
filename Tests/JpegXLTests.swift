import CryptoKit
import ImageIO
import UIKit
import XCTest
@testable import ImmichSwiftUI

/// Real JPEG XL bytes shared by the L-05 unit tests. `thumbnail` is
/// `UITests/stubs/fixtures/jxl/thumbnail-200x200.jxl` (libjxl/conformance case
/// `grayscale`, BSD-3-Clause), inlined so the test bundle needs no resource.
enum JpegXLFixture {
    static let thumbnailSHA256 = "78fbbba852e99946d187dcf0bcbd7fb0e7c22be2f0852523aaae6ed91e7e3c39"

    static let thumbnail = Data(base64Encoded: "/wpxQBpPGgMmACAAIECYmAjOITWLjZ23bku0OQH5DAuJy8MlLlAtF7p0zTnFci1cxzICStSsQgOmUlVBtIQAYIIhRphi/QXgAWw9t//OAPE+CXFOJgAAxp133Cn5hvjFzOCBMik5EDp07Ny5c4MJEI9QhplkE1U0c5iEMzwS9EgBVZAeskN46DCHIHFDx4Zd+HNY+1oRwE67fSrT+r/sWPzPEL+ZXmW5VBhHoUeBB26Bu5mby+0HucxewyU5JplkmCGTJD0JjDfA0MubOfJIuhIYR/7N7t+4IgnpW3xUYlzZNyFxSG/JWXjlENj+pbPsTggkQAIAEogCAMQMVQ8AAKhQGWXc4OVcz5cfOiymbVxnaKttC0sSCZB5KxeA9wQPg8FMCgrcqpI3LWc4rByfo2NjI2PGiTOXNxUZBULYYVERWlTAEBQ0CAUhMWFAKATEBEFISIVEwEhQEUkQkJHnQxC22u28z7cnMEb0G/aDKSjrl/J5MCAOiO/nG3fXXZ08sne9d//3FugRUN4eQmcM8biXq2AyPktnr09wrqbwg75jb+fvhKegN2PgF3j0/q1mxd+NcEaIi/+258LGV/IkIIvQ5HpqPw3beq+F0I/MEFC1xiCwIMihp2D+UEfr/5SfwFeOIA4HxdYNt+L+Is/aaDg/bW/w7xLnw1fW6FFNrsiTx4nQVm9JR9wXnWaK8LHHow5tvqm5y9fQFo3m35dUlxxPACe6jinvu5a7lo4WE7+A3rWvz5bvBu6G7y685GVXLw9fL1YvN5+s3lvIn191/h2vDY+QD2C/nVb8ABsuOKZZ36busqgoi2TtLKJCvSiLZO0sokK9KItk7SyiQr0oi2TtLKJCvSiLZO0sokK9KItk7SyiQr0oi2TtLKJCvSgLTG2caPFlhsUoxmv+H+AdZv1zLJYQ7tDMMFihxRoB5mESwkwHbgcQQjAS5xDZATFSDSjgHyjiEUAY9hR+Dq7KMeHbtyTCiuI7HbG1oW8DsLJm11+9l1Wt93/fYPocML36tcP/1Q6fHhQNuTot0qWNkuwHuSPlQDgtGXU3GaoJPeQUQEKZsc2jWIEoN8sXCAcoWtj/wukAQGaoFlPW0WnKbHmF9IgPVQeOIgicaDYpKFDZbVQ8nBiGBiQxitTYOQB0kQig9D2gD/UaSkrp3RtlT+9mDr4a5Vf7gTGyLRmWOQMn+diiULhe1Davu67/XNRvPelAgFtKlk7TJo9J8n7vqEpKsBvH1pAzaa6Ay08rzLWYHJMgAN7L5fTy1pwzuPtdfs1VITAIuk5NxUX1TSHRNEi/uPttiAGKly2H0Zu9ZCRI6jbmCTNiE4qvsl28cloIw2rT90WaXqT7bYiZ0KLRaATH5T0Z0FXGpNJuyCkXdTib6Z4IksDrhUUAFXBurA1KxgIuVR/XdcDITxrwJA==")!

    /// The bare codestream signature only: no size header, so ImageIO cannot
    /// build even a partial image from it (decision #9).
    static let truncated = Data([0xFF, 0x0A])

    /// ISOBMFF container signature box (`JXL `).
    static let containerHeader = Data([0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A])
}

/// S-1: ImageIO decodes JPEG XL natively on iOS 26, through every path the app
/// uses (UIImage, the offline-copy downsampler, the widget encoder).
final class JpegXLDecodingTests: XCTestCase {

    func test_AC_97_imageIODecodesJpegXL() throws {
        let types = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        XCTAssertTrue(types.contains("public.jpeg-xl"), "ImageIO does not list public.jpeg-xl: \(types)")

        let image = try XCTUnwrap(UIImage(data: JpegXLFixture.thumbnail), "UIImage(data:) cannot decode JPEG XL")
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, 200)
        XCTAssertEqual(cg.height, 200)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jxl-gate-\(UUID().uuidString).jxl")
        try JpegXLFixture.thumbnail.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let down = try XCTUnwrap(ImageDownsampler.image(at: url, maxPixelSize: 4096))
        XCTAssertEqual(down.cgImage?.width, 200)
        XCTAssertEqual(down.cgImage?.height, 200)

        let encoded = try XCTUnwrap(WidgetImageEncoder.encode(JpegXLFixture.thumbnail, toCover: WidgetPixelSize(width: 320, height: 320)))
        XCTAssertEqual(Array(encoded.prefix(2)), [0xFF, 0xD8], "widget re-encode is not a JPEG")
    }
}

extension JpegXLDecodingTests {

    /// Negative control: two signature bytes carry no size header, so nothing
    /// can be decoded — the grid and the widget must see a failure, not an image.
    func test_AC_97_truncatedJpegXLIsNotDecoded() {
        XCTAssertNil(UIImage(data: JpegXLFixture.truncated))
        XCTAssertNil(WidgetImageEncoder.encode(JpegXLFixture.truncated, toCover: WidgetPixelSize(width: 320, height: 320)))
    }

    func test_AC_97_fixtureIsTheConformanceFileUnmodified() {
        let digest = SHA256.hash(data: JpegXLFixture.thumbnail).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, JpegXLFixture.thumbnailSHA256)
        XCTAssertEqual(JpegXLFixture.thumbnail.count, 1069)
    }

    func test_AC_97_loadStateProbeValues() throws {
        XCTAssertEqual(ImageLoadState.placeholder.probeValue(extra: nil), "placeholder")
        XCTAssertEqual(ImageLoadState.failed.probeValue(extra: nil), "failed")
        XCTAssertEqual(ImageLoadState.loaded(pixelWidth: 1024, pixelHeight: 631).probeValue(extra: nil), "loaded 1024x631")

        XCTAssertEqual(ImageLoadState.placeholder.probeValue(extra: "zoom=1.00"), "placeholder zoom=1.00")
        XCTAssertEqual(ImageLoadState.failed.probeValue(extra: "zoom=1.00"), "failed zoom=1.00")
        XCTAssertEqual(
            ImageLoadState.loaded(pixelWidth: 1024, pixelHeight: 631).probeValue(extra: "zoom=2.50"),
            "loaded 1024x631 zoom=2.50"
        )
        XCTAssertEqual(ImageLoadState.failed.probeValue(extra: ""), "failed", "an empty extra adds nothing")

        let image = try XCTUnwrap(UIImage(data: JpegXLFixture.thumbnail))
        XCTAssertEqual(ImageLoadState(loaded: image), .loaded(pixelWidth: 200, pixelHeight: 200))
    }

    /// AC-100: an offline copy is an original, read from disk through the
    /// downsampler that bounds its decoded size.
    func test_AC_100_downsamplerDecodesJpegXLFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jxl-offline-\(UUID().uuidString).jxl")
        try JpegXLFixture.thumbnail.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        for limit in [2048, 4096] {
            let image = try XCTUnwrap(ImageDownsampler.image(at: url, maxPixelSize: limit))
            XCTAssertEqual(image.cgImage?.width, 200, "maxPixelSize \(limit)")
            XCTAssertEqual(image.cgImage?.height, 200, "maxPixelSize \(limit)")
        }

        let small = try XCTUnwrap(ImageDownsampler.image(at: url, maxPixelSize: 100))
        let longest = max(small.cgImage?.width ?? 0, small.cgImage?.height ?? 0)
        XCTAssertEqual(longest, 100)
    }

    /// AC-103: the formats that worked before keep working and keep their names.
    func test_AC_103_otherFormatsUnchanged() throws {
        // Scale 1: the default format takes the screen scale, which would make
        // the encoded pixels 2-3x the point size (OfflineAssetStoreTests does the same).
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format)
        let canvas = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let jpeg = try XCTUnwrap(canvas.jpegData(compressionQuality: 0.8))
        let png = try XCTUnwrap(canvas.pngData())

        for data in [jpeg, png] {
            let decoded = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(ImageLoadState(loaded: decoded), .loaded(pixelWidth: 40, pixelHeight: 30))
            XCTAssertEqual(PhotoLibraryServiceImpl.imageExtension(for: data), "jpg")
        }

        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/png"), "png")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/webp"), "webp")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/heic"), "heic")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/gif"), "gif")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/avif"), "avif")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "video/mp4"), "mp4")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "video/quicktime"), "mov")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "video/mpeg"), "mpg")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "application/octet-stream"), "jpg")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: nil), "jpg")
    }

    /// AC-104: "Partager" sends the preview, so the extension follows the
    /// preview's own `Content-Type`, not the original's.
    func test_AC_104_shareExtensionFollowsSharedBytes() {
        XCTAssertEqual(AssetFileTransfer.sharedFileExtension(sharedContentType: "image/jxl", originalMime: "image/jxl"), "jxl")
        XCTAssertEqual(AssetFileTransfer.sharedFileExtension(sharedContentType: "image/jpeg", originalMime: "image/jxl"), "jpg")
        XCTAssertEqual(AssetFileTransfer.sharedFileExtension(sharedContentType: nil, originalMime: "image/jxl"), "jxl")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/jxl; charset=binary"), "jxl")
    }

    /// AC-105: Photos infers the type from the file, so a JPEG XL original must
    /// be written as `.jxl` — by its bytes, whichever name the server gave.
    func test_AC_105_photosExtensionSniffsJpegXL() throws {
        XCTAssertEqual(PhotoLibraryServiceImpl.imageExtension(for: JpegXLFixture.thumbnail), "jxl")
        XCTAssertEqual(PhotoLibraryServiceImpl.imageExtension(for: JpegXLFixture.containerHeader), "jxl")

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format)
        let canvas = renderer.image { $0.cgContext.fill(CGRect(x: 0, y: 0, width: 40, height: 30)) }
        XCTAssertEqual(PhotoLibraryServiceImpl.imageExtension(for: try XCTUnwrap(canvas.jpegData(compressionQuality: 0.8))), "jpg")
        XCTAssertEqual(PhotoLibraryServiceImpl.imageExtension(for: try XCTUnwrap(canvas.pngData())), "jpg")
        XCTAssertEqual(PhotoLibraryServiceImpl.imageExtension(for: Data("....ftypheic".utf8)), "heic")
        XCTAssertEqual(PhotoLibraryServiceImpl.imageExtension(for: Data()), "jpg")
    }
}
