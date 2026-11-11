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

        let encoded = try XCTUnwrap(WidgetImageEncoder.encode(JpegXLFixture.thumbnail, at: .cell))
        XCTAssertEqual(Array(encoded.prefix(2)), [0xFF, 0xD8], "widget re-encode is not a JPEG")
    }
}
