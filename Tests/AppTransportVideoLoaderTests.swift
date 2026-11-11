import XCTest
@testable import ImmichSwiftUI

/// The pure parts of the video path for a server with a client certificate: the
/// private scheme, the byte ranges, and which engine path a URL takes.
final class AppTransportVideoLoaderTests: XCTestCase {
    func test_AC_21_3_loaderURLRoundTrips() throws {
        let https = URL(string: "https://photos.example.com:8443/api/assets/a1/video/playback?x=1")!
        let loaderURL = try XCTUnwrap(AppTransportVideoLoader.loaderURL(for: https))
        XCTAssertEqual(loaderURL.scheme, "swimmich-https")
        XCTAssertEqual(loaderURL.host, "photos.example.com")
        XCTAssertEqual(loaderURL.path, "/api/assets/a1/video/playback")
        XCTAssertEqual(AppTransportVideoLoader.networkURL(for: loaderURL), https)

        let http = URL(string: "http://nas.local/v")!
        let plain = try XCTUnwrap(AppTransportVideoLoader.loaderURL(for: http))
        XCTAssertEqual(plain.scheme, "swimmich-http")
        XCTAssertEqual(AppTransportVideoLoader.networkURL(for: plain), http)
    }

    func test_AC_21_3_otherSchemesAreNotOurs() {
        XCTAssertNil(AppTransportVideoLoader.loaderURL(for: URL(fileURLWithPath: "/tmp/video.mp4")))
        XCTAssertNil(AppTransportVideoLoader.loaderURL(for: URL(string: "ftp://h/v")!))
        XCTAssertNil(AppTransportVideoLoader.networkURL(for: URL(string: "https://h/v")!))
    }

    func test_AC_21_3_rangeHeader() {
        XCTAssertEqual(AppTransportVideoLoader.rangeHeader(offset: 0, length: 2, toEnd: false), "bytes=0-1")
        XCTAssertEqual(AppTransportVideoLoader.rangeHeader(offset: 100, length: 50, toEnd: false), "bytes=100-149")
        XCTAssertEqual(AppTransportVideoLoader.rangeHeader(offset: 7, length: 0, toEnd: true), "bytes=7-")
        XCTAssertEqual(AppTransportVideoLoader.rangeHeader(offset: 4_000_000_000, length: 10, toEnd: false), "bytes=4000000000-4000000009")
    }

    func test_AC_21_3_totalLengthOfContentRange() {
        XCTAssertEqual(AppTransportVideoLoader.totalLength(contentRange: "bytes 0-1/12345"), 12345)
        XCTAssertEqual(AppTransportVideoLoader.totalLength(contentRange: "bytes 100-199/5000000000"), 5_000_000_000)
        XCTAssertNil(AppTransportVideoLoader.totalLength(contentRange: "bytes 0-1/*"))
        XCTAssertNil(AppTransportVideoLoader.totalLength(contentRange: "bytes 0-1"))
        XCTAssertNil(AppTransportVideoLoader.totalLength(contentRange: "garbage/oops"))
        XCTAssertNil(AppTransportVideoLoader.totalLength(contentRange: nil))
    }

    // MARK: Engine path choice

    private func transport(with store: InMemoryClientIdentityStore) -> VideoAppTransport {
        VideoAppTransport(session: { .shared }, identities: store)
    }

    func test_AC_21_3_loaderOnlyForAServerWithAnIdentity() throws {
        let store = InMemoryClientIdentityStore()
        let url = URL(string: "https://photos.example.com/api/assets/a1/video/playback")!

        let without = AVVideoPlaybackEngine.assetURL(for: url, transport: transport(with: store))
        XCTAssertEqual(without.url, url)
        XCTAssertFalse(without.usesLoader, "no certificate: the code path of before")

        try store.save(try ClientCertificateTestSupport.identityA(), for: ClientCertificateTestSupport.key("https://photos.example.com"))
        let with = AVVideoPlaybackEngine.assetURL(for: url, transport: transport(with: store))
        XCTAssertTrue(with.usesLoader)
        XCTAssertEqual(with.url.scheme, "swimmich-https")

        let otherPort = URL(string: "https://photos.example.com:8443/v")!
        XCTAssertFalse(AVVideoPlaybackEngine.assetURL(for: otherPort, transport: transport(with: store)).usesLoader,
                       "the certificate belongs to one host + port")
    }

    func test_AC_21_3_noTransportNeverUsesTheLoader() throws {
        let url = URL(string: "https://photos.example.com/v")!
        let result = AVVideoPlaybackEngine.assetURL(for: url, transport: nil)
        XCTAssertEqual(result.url, url)
        XCTAssertFalse(result.usesLoader)
    }

    func test_AC_21_3_aLocalFileNeverGoesThroughTheLoader() throws {
        let store = InMemoryClientIdentityStore()
        let file = URL(fileURLWithPath: "/tmp/offline-copy.mp4")
        let result = AVVideoPlaybackEngine.assetURL(for: file, transport: transport(with: store))
        XCTAssertEqual(result.url, file)
        XCTAssertFalse(result.usesLoader)
    }
}
