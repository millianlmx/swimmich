import UIKit
import XCTest
@testable import ImmichSwiftUI

/// Answers every request with a 4×4 PNG, or with a 500 when `failing`.
private final class RoadTripPreviewProtocol: URLProtocol {
    nonisolated(unsafe) static var failing = false

    static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
        UIColor.green.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let failing = Self.failing
        let response = HTTPURLResponse(
            url: request.url!, statusCode: failing ? 500 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": failing ? "text/plain" : "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: failing ? Data("boom".utf8) : Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The preparation builds the one timeline the film plays, keeps the photos
/// it shows decoded, and keeps its error on screen.
@MainActor
final class RoadTripPreparationTests: XCTestCase {

    override func tearDown() {
        RoadTripPreviewProtocol.failing = false
        super.tearDown()
    }

    private func makeAsset(id: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T10:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T10:00:00.000Z", ownerId: "owner", originalPath: "/x.jpg",
            originalFileName: "x.jpg", fileCreatedAt: "2024-07-01T10:00:00.000Z",
            fileModifiedAt: "2024-07-01T10:00:00.000Z", updatedAt: "2024-07-01T10:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    private func makeVM(assetIDs: [String]) -> (RoadTripViewModel, MockImmichClient) {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = SearchResponseDto(assets: SearchAssetResponseDto(
            count: assetIDs.count, items: assetIDs.map { makeAsset(id: $0) }, nextPage: nil
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoadTripPreviewProtocol.self]
        let session = URLSession(configuration: configuration)
        let vm = RoadTripViewModel(
            client: mock, albumId: "album", selectedAssetIds: nil, albumTitle: "Trip",
            baseURL: { URL(string: "https://photos.example.org")! }, token: "tok",
            photos: MockPhotoLibraryService(), session: { session }
        )
        return (vm, mock)
    }

    func test_preparationKeepsTheDecodedPhotosOfTheFilm() async throws {
        let ids = ["a1", "a2", "a3"]
        let (vm, _) = makeVM(assetIDs: ids)

        await vm.prepare()

        XCTAssertFalse(vm.isPreparing)
        XCTAssertNil(vm.errorMessage)
        let timeline = try XCTUnwrap(vm.timeline)
        let shown = RoadTripViewModel.shownAssets(in: timeline, clusters: vm.clusters).map(\.id)
        XCTAssertEqual(Set(shown), Set(ids))
        XCTAssertEqual(Set(vm.slideImages.keys), Set(shown), "every photo of the film is held decoded, and only those")
        for asset in vm.clusters.flatMap(\.assets) {
            XCTAssertNotNil(vm.slideImage(for: asset), "no preloaded image for \(asset.id)")
        }
    }

    func test_preparationRunsOnce() async {
        let (vm, mock) = makeVM(assetIDs: ["a1", "a2"])

        await vm.prepare()
        let timeline = vm.timeline
        await vm.prepare()

        XCTAssertEqual(mock.searchMetadataCalls.count, 1, "a second appearance must not rebuild the film")
        XCTAssertEqual(vm.timeline, timeline)
    }

    func test_preparationKeepsTheErrorWhenNoPhotoLoads() async {
        RoadTripPreviewProtocol.failing = true
        let (vm, _) = makeVM(assetIDs: ["a1", "a2"])

        await vm.prepare()

        XCTAssertFalse(vm.isPreparing)
        XCTAssertNil(vm.timeline, "no film made of black frames")
        XCTAssertEqual(vm.errorMessage, String(localized: "No displayable photos."))
        XCTAssertTrue(vm.slideImages.isEmpty)
    }

    func test_straightLegsJoinConsecutiveLocatedStops() {
        func stop(_ id: String, _ lat: Double?, _ lon: Double?) -> RoadTripCluster {
            RoadTripCluster(id: id, assets: [], latitude: lat, longitude: lon, placeName: nil, startDate: nil, endDate: nil)
        }
        let legs = RoadTripViewModel.straightLegs(between: [
            stop("paris", 48.85, 2.35), stop("versailles", 48.80, 2.13), stop("nowhere", nil, nil), stop("lyon", 45.76, 4.84)
        ])

        XCTAssertEqual(legs.map(\.fromClusterID), ["paris"])
        XCTAssertEqual(legs.first?.toClusterID, "versailles")
        XCTAssertEqual(legs.first?.route.count, 2)
    }
}
