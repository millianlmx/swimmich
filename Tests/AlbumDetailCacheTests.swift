import XCTest
@testable import ImmichSwiftUI

/// An album opened again shows its photos at once, and coming back to the
/// screen (a viewer closed over it) does not read it again.
@MainActor
final class AlbumDetailCacheTests: XCTestCase {

    private func makeAlbum(id: String = "alb", name: String = "Trip") -> AlbumResponseDto {
        AlbumResponseDto(
            id: id, albumName: name, description: "", createdAt: "2024-01-01T00:00:00.000Z",
            updatedAt: "2024-01-01T00:00:00.000Z", albumThumbnailAssetId: nil, shared: false,
            hasSharedLink: false, assetCount: 3, isActivityEnabled: false, order: nil,
            albumUsers: [], ownerId: "owner"
        )
    }

    private func makeAsset(id: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T00:00:00.000Z", ownerId: "owner", originalPath: "/x.jpg",
            originalFileName: "x.jpg", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z", updatedAt: "2024-07-01T00:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    private func makeMock(assetIDs: [String]) -> MockImmichClient {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum()]
        mock.searchMetadataResponse = SearchResponseDto(assets: SearchAssetResponseDto(
            count: assetIDs.count, items: assetIDs.map { makeAsset(id: $0) }, nextPage: nil
        ))
        return mock
    }

    func test_reopenedAlbumStartsFromWhatItShowed() async {
        let cache = AlbumDetailCache()
        let first = AlbumDetailViewModel(client: makeMock(assetIDs: ["a", "b", "c"]), albumId: "alb", cache: cache)
        XCTAssertTrue(first.assets.isEmpty)
        await first.appear()
        XCTAssertEqual(first.assets.map(\.id), ["a", "b", "c"])

        let reopened = AlbumDetailViewModel(client: makeMock(assetIDs: ["a", "b", "c"]), albumId: "alb", cache: cache)

        XCTAssertEqual(reopened.assets.map(\.id), ["a", "b", "c"], "the photos are there before any read")
        XCTAssertEqual(reopened.album?.albumName, "Trip")
        XCTAssertEqual(reopened.assetsState, .data(.reloading), "no skeleton: the grid shows while the read runs")
    }

    func test_firstAppearanceReplacesTheKeptPhotosInPlace() async {
        let cache = AlbumDetailCache()
        let first = AlbumDetailViewModel(client: makeMock(assetIDs: ["a", "b"]), albumId: "alb", cache: cache)
        await first.appear()

        let mock = makeMock(assetIDs: ["a", "b", "new"])
        let reopened = AlbumDetailViewModel(client: mock, albumId: "alb", cache: cache)
        await reopened.appear()

        XCTAssertEqual(reopened.assets.map(\.id), ["a", "b", "new"])
        XCTAssertEqual(cache.snapshot(for: "alb")?.assets.map(\.id), ["a", "b", "new"], "the read is kept for the next opening")
    }

    func test_comingBackToTheScreenReadsNothing() async {
        let mock = makeMock(assetIDs: ["a", "b"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb", cache: AlbumDetailCache())

        await vm.appear()
        await vm.appear()

        XCTAssertEqual(mock.searchMetadataCalls.count, 1, "closing the viewer over the album must not reload it")
    }

    func test_withoutCacheNothingIsKept() async {
        let vm = AlbumDetailViewModel(client: makeMock(assetIDs: ["a"]), albumId: "alb")
        await vm.appear()
        vm.saveSnapshot()

        let next = AlbumDetailViewModel(client: makeMock(assetIDs: ["a"]), albumId: "alb")
        XCTAssertTrue(next.assets.isEmpty)
    }

    func test_cacheKeepsTheMostRecentAlbums() {
        let cache = AlbumDetailCache(capacity: 2)
        func snapshot(_ id: String) -> AlbumDetailCache.Snapshot {
            AlbumDetailCache.Snapshot(album: makeAlbum(id: id), assets: [], nextPage: nil, pageOrder: nil)
        }
        cache.store(snapshot("one"), for: "one")
        cache.store(snapshot("two"), for: "two")
        cache.store(snapshot("one"), for: "one")
        cache.store(snapshot("three"), for: "three")

        XCTAssertNotNil(cache.snapshot(for: "one"), "stored again, it is recent")
        XCTAssertNil(cache.snapshot(for: "two"), "the least recently stored goes")
        XCTAssertNotNil(cache.snapshot(for: "three"))

        cache.remove("one")
        XCTAssertNil(cache.snapshot(for: "one"))
        cache.removeAll()
        XCTAssertNil(cache.snapshot(for: "three"))
    }
}
