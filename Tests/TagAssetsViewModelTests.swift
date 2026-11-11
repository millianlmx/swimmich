import XCTest
@testable import ImmichSwiftUI

/// The photos behind one tag: which filters reach the server and how the
/// periods page in (L-03).
final class TagAssetsViewModelTests: XCTestCase {

    private struct BoomError: Error {}

    private func columnar(ids: [String], day: String = "2024-07-01") -> TimeBucketAssetResponseDto {
        let stamp = "\(day)T10:00:00.000Z"
        return TimeBucketAssetResponseDto(
            id: ids,
            ownerId: ids.map { _ in "owner" },
            ratio: ids.map { _ in 1.0 },
            isFavorite: ids.map { _ in false },
            visibility: ids.map { _ in "timeline" },
            isTrashed: ids.map { _ in false },
            isImage: ids.map { _ in true },
            thumbhash: ids.map { _ in nil },
            createdAt: ids.map { _ in stamp },
            fileCreatedAt: ids.map { _ in stamp },
            localOffsetHours: ids.map { _ in 0.0 },
            duration: ids.map { _ in nil },
            livePhotoVideoId: ids.map { _ in nil },
            projectionType: ids.map { _ in nil },
            stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
        )
    }

    /// Two periods, newest first: `a1 a2` then `b1`.
    @MainActor
    private func twoPeriodMock() -> MockImmichClient {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-06-01", count: 1),
        ]
        mock.bucketResponses["2024-07-01"] = columnar(ids: ["a1", "a2"], day: "2024-07-01")
        mock.bucketResponses["2024-06-01"] = columnar(ids: ["b1"], day: "2024-06-01")
        return mock
    }

    @MainActor
    private func makeVM(_ mock: MockImmichClient) -> TagAssetsViewModel {
        TagAssetsViewModel(client: mock, tagId: "japon", tagName: "Japon")
    }

    @MainActor
    func test_AC_12_requestsTagIdWithTimelineVisibilityOnBothRoutes() async {
        let mock = twoPeriodMock()
        let vm = makeVM(mock)

        await vm.load()

        let expected = TimelineFilterCapture(
            isFavorite: nil, isTrashed: nil, personId: nil, withPartners: nil,
            visibility: "timeline", withStacked: nil, orderBy: nil, tagId: "japon"
        )
        XCTAssertEqual(mock.lastTimeBucketsFilters, expected)
        XCTAssertEqual(mock.lastTimeBucketsTagId, "japon")
        XCTAssertEqual(mock.timeBucketCalls.map { $0.filters }, [expected])
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])
    }

    @MainActor
    func test_AC_79_emptyTagIsEmptyState() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = []
        let vm = makeVM(mock)

        await vm.load()

        XCTAssertTrue(vm.hasLoaded)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.hasMore)
    }

    @MainActor
    func test_AC_79_failureThenRetryShowsPhotos() async {
        let mock = twoPeriodMock()
        mock.timeBucketsErrorQueue = [BoomError()]
        let vm = makeVM(mock)

        await vm.load()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.items.isEmpty)

        await vm.load()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])
    }

    @MainActor
    func test_AC_81_loadMoreAppendsNextBucket() async {
        let mock = twoPeriodMock()
        let vm = makeVM(mock)

        await vm.load()
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])
        XCTAssertTrue(vm.hasMore)

        await vm.loadMore()
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "b1"])
        XCTAssertFalse(vm.hasMore)
        XCTAssertEqual(mock.timeBucketCalls.map { $0.filters.tagId }, ["japon", "japon"])
    }

    @MainActor
    func test_AC_81_emptyBucketDoesNotStopPaging() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 0),
            TimeBucketsResponseDto(timeBucket: "2024-06-01", count: 1),
        ]
        mock.bucketResponses["2024-06-01"] = columnar(ids: ["b1"], day: "2024-06-01")
        let vm = makeVM(mock)

        await vm.load()

        XCTAssertEqual(vm.items.map(\.id), ["b1"])
        XCTAssertFalse(vm.hasMore)
    }

    @MainActor
    func test_AC_81_loadMoreFailureKeepsGridThenRetries() async {
        let mock = twoPeriodMock()
        let vm = makeVM(mock)
        await vm.load()

        mock.timeBucketErrorQueue = [BoomError()]
        await vm.loadMore()
        XCTAssertNotNil(vm.loadMoreErrorMessage)
        XCTAssertNil(vm.errorMessage, "the grid stays: only the footer reports it")
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])
        XCTAssertTrue(vm.hasMore)

        await vm.loadMore()
        XCTAssertNil(vm.loadMoreErrorMessage)
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "b1"])
    }

    @MainActor
    func test_AC_12_removeDropsTheDeletedPhoto() async {
        let mock = twoPeriodMock()
        let vm = makeVM(mock)
        await vm.load()

        vm.remove(assetId: "a1")

        XCTAssertEqual(vm.items.map(\.id), ["a2"])
    }

    @MainActor
    func test_AC_81_reloadRestartsFromTheFirstPeriod() async {
        let mock = twoPeriodMock()
        let vm = makeVM(mock)
        await vm.load()
        await vm.loadMore()

        await vm.load()

        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"], "no stale page survives a reload")
        XCTAssertTrue(vm.hasMore)
    }
}
