import UIKit
import XCTest
@testable import ImmichSwiftUI

/// Records every request it receives and answers a 2x2 PNG.
private final class RoadTripRecordingProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _urls: [URL] = []

    static var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _urls
    }

    static func reset() {
        lock.lock(); _urls = []; lock.unlock()
    }

    static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock(); Self._urls.append(url); Self.lock.unlock()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// L-26: a road trip reads the address in use when it needs it, not the one it was created with.
@MainActor
final class RoadTripViewModelTests: XCTestCase {
    private let external = URL(string: "https://photos.example.org")!
    private let local = URL(string: "http://192.168.1.10:2283")!

    private final class Address: @unchecked Sendable {
        private let lock = NSLock()
        private var _url: URL
        private var _reads = 0
        private let switchAfter: Int?
        private let next: URL?

        /// `switchAfter`: number of reads that still return `url`; later reads return `next`.
        init(_ url: URL, switchAfter: Int? = nil, next: URL? = nil) {
            _url = url
            self.switchAfter = switchAfter
            self.next = next
        }

        var url: URL {
            get { lock.lock(); defer { lock.unlock() }; return _url }
            set { lock.lock(); _url = newValue; lock.unlock() }
        }

        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }

        func read() -> URL {
            lock.lock(); defer { lock.unlock() }
            _reads += 1
            if let switchAfter, let next, _reads > switchAfter { return next }
            return _url
        }
    }

    override func setUp() {
        super.setUp()
        RoadTripRecordingProtocol.reset()
    }

    override func tearDown() {
        RoadTripRecordingProtocol.reset()
        ServerAddressBook.shared.clear()
        super.tearDown()
    }

    private func makeAsset(_ id: String) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func makeVM(baseURL: @escaping @Sendable () -> URL, session: URLSession = .shared) -> RoadTripViewModel {
        RoadTripViewModel(
            client: MockImmichClient(), albumId: "album", selectedAssetIds: nil, albumTitle: "Trip",
            baseURL: baseURL, token: "tok", photos: MockPhotoLibraryService(), session: { session }
        )
    }

    func test_AC_238_roadTripReadsCurrentAddress() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoadTripRecordingProtocol.self]
        let session = URLSession(configuration: configuration)
        // One batch holds 8 thumbnails: the first batch starts on the external
        // address, the address then moves to the local one for the ninth.
        let address = Address(external, switchAfter: 1, next: local)
        let vm = makeVM(baseURL: { address.read() }, session: session)
        let assets = (1...9).map { makeAsset("a\($0)") }

        let valid = await vm.validAssetIDs(assets)

        XCTAssertEqual(valid, Set(assets.map(\.id)))
        let urls = RoadTripRecordingProtocol.urls
        XCTAssertEqual(urls.count, 9)
        let firstBatch = urls.filter { $0.host == "photos.example.org" }
        let secondBatch = urls.filter { $0.host == "192.168.1.10" }
        XCTAssertEqual(firstBatch.count, 8, "the first batch of eight left on the address read at its start")
        XCTAssertEqual(secondBatch.count, 1, "the next batch left on the new address")
        XCTAssertEqual(secondBatch.first?.port, 2283)
        for url in urls {
            let id = url.pathComponents[3]
            let expected = ImmichAssetURL.thumbnail(assetId: id, thumbhash: "", baseURL: external, size: .preview)
            XCTAssertEqual(url.path, expected.path)
            XCTAssertEqual(url.query, expected.query)
        }
        XCTAssertEqual(address.reads, 2, "one read per batch")
    }

    func test_AC_238_renderKeepsTheAddressReadAtStart() {
        let address = Address(external)
        let vm = makeVM(baseURL: { address.url })

        let config = vm.makeRenderConfig(reduceMotion: false)
        address.url = local

        XCTAssertEqual(config.baseURL.host, "photos.example.org", "a render in progress keeps its address")
        XCTAssertEqual(vm.makeRenderConfig(reduceMotion: false).baseURL.host, "192.168.1.10")
    }

    func test_AC_238_containerFallsBackToTheFactoryAddress() {
        ServerAddressBook.shared.clear()
        let vm = DependencyContainer.shared.makeRoadTripViewModel(
            albumId: "a", selectedAssetIds: nil, albumTitle: "T", baseURL: external, token: "tok"
        )
        XCTAssertEqual(vm.baseURL, external, "no active address in the book: the factory address")

        ServerAddressBook.shared.update(accountURL: external, addresses: [external, local], activeURL: local)

        XCTAssertEqual(vm.baseURL, local)
    }
}
