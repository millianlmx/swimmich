import XCTest
@testable import ImmichSwiftUI

final class ThumbHashDecoderTests: XCTestCase {

    // Common standard ThumbHash sample representations.
    private let sampleLandscape = "XakJJYI/WFWSaGZ1d/ZXdnlw5gdn"
    private let sampleWithAlpha = "ZZcJbwKUaIh/iXdheKeFl5iDdwi3dUgP"

    override func setUp() {
        super.setUp()
        ThumbHashDecoder.shared.clearCache()
    }

    func test_decodeValidThumbHash_returnsNonNilImage() {
        let decoder = ThumbHashDecoder()
        let image = decoder.decode(thumbhash: sampleLandscape)

        XCTAssertNotNil(image, "Expected valid ThumbHash to decode into a UIImage")
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
        XCTAssertGreaterThan(image?.size.height ?? 0, 0)
    }

    func test_decodeValidThumbHashWithAlpha_returnsNonNilImage() {
        let decoder = ThumbHashDecoder()
        let image = decoder.decode(thumbhash: sampleWithAlpha)

        XCTAssertNotNil(image, "Expected alpha ThumbHash to decode into a UIImage")
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
        XCTAssertGreaterThan(image?.size.height ?? 0, 0)
    }

    func test_approximateAspectRatio() {
        let decoder = ThumbHashDecoder()
        guard let data = Data(base64Encoded: sampleLandscape) else {
            XCTFail("Failed to decode sample base64")
            return
        }
        let ratio = decoder.approximateAspectRatio(hash: data)
        XCTAssertGreaterThan(ratio, 0)
    }

    func test_decodeEmptyString_returnsNil() {
        let decoder = ThumbHashDecoder()
        XCTAssertNil(decoder.decode(thumbhash: ""))
        XCTAssertNil(decoder.image(for: ""))
        XCTAssertNil(decoder.cachedImage(for: ""))
    }

    func test_decodeInvalidBase64_returnsNilSafely() {
        let decoder = ThumbHashDecoder()
        XCTAssertNil(decoder.decode(thumbhash: "!!!Not Valid Base64???"))
    }

    func test_decodeTruncatedBytes_returnsNilSafely() {
        let decoder = ThumbHashDecoder()
        // 2 bytes base64 encoded -> hash.count < 5
        let shortBase64 = "AA=="
        XCTAssertNil(decoder.decode(thumbhash: shortBase64))
    }

    func test_cachingReturnsSameInstance() {
        let decoder = ThumbHashDecoder()

        XCTAssertNil(decoder.cachedImage(for: sampleLandscape))

        let first = decoder.image(for: sampleLandscape)
        XCTAssertNotNil(first)

        let cached = decoder.cachedImage(for: sampleLandscape)
        XCTAssertNotNil(cached)
        XCTAssertTrue(first === cached, "Expected cached instance to match first decoded instance")

        let second = decoder.image(for: sampleLandscape)
        XCTAssertTrue(first === second)
    }

    func test_clearCacheRemovesEntries() {
        let decoder = ThumbHashDecoder()
        _ = decoder.image(for: sampleLandscape)
        XCTAssertNotNil(decoder.cachedImage(for: sampleLandscape))

        decoder.clearCache()
        XCTAssertNil(decoder.cachedImage(for: sampleLandscape))
    }

    func test_concurrentDecodingThreadSafety() async {
        let decoder = ThumbHashDecoder()
        let hashes = [sampleLandscape, sampleWithAlpha]

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                let hash = hashes[i % hashes.count]
                group.addTask {
                    let img = decoder.image(for: hash)
                    XCTAssertNotNil(img)
                }
            }
        }

        XCTAssertNotNil(decoder.cachedImage(for: sampleLandscape))
        XCTAssertNotNil(decoder.cachedImage(for: sampleWithAlpha))
    }
}
