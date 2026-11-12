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
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertEqual(vm.renderState, .empty)
        XCTAssertFalse(vm.hasMore)
    }

    @MainActor
    func test_AC_79_failureThenRetryShowsPhotos() async {
        let mock = twoPeriodMock()
        mock.timeBucketsErrorQueue = [BoomError()]
        let vm = makeVM(mock)

        await vm.load()
        XCTAssertNotNil(vm.loadErrorMessage)
        XCTAssertTrue(vm.items.isEmpty)

        await vm.load()
        XCTAssertNil(vm.loadErrorMessage)
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
        XCTAssertNil(vm.loadErrorMessage, "the grid stays: only the footer reports it")
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

    // MARK: - List states (L-16)

    private let serverError = APIError.serverError(500, "x")

    @MainActor
    func test_AC_142_tagAssets_loadingUntilFirstAnswer() async {
        let mock = twoPeriodMock()
        let latch = TestLatch()
        mock.timelineGate = { _ in try? await latch.wait() }
        let vm = makeVM(mock)
        XCTAssertEqual(vm.renderState, .loading)

        let read = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_147_tagAssets_successfulEmptyReadIsEmptyState() async {
        let vm = makeVM(MockImmichClient())

        await vm.load()

        XCTAssertEqual(vm.renderState, .empty)
        XCTAssertTrue(vm.hasLoaded)
    }

    @MainActor
    func test_AC_149_tagAssets_firstReadFailsShowsErrorNotEmpty() async {
        let mock = twoPeriodMock()
        mock.timeBucketsErrorQueue = [serverError]
        let vm = makeVM(mock)

        await vm.load()

        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.items.isEmpty)
    }

    @MainActor
    func test_AC_149_tagAssets_firstPageFailureAfterTheBucketListIsAnError() async {
        let mock = twoPeriodMock()
        mock.timeBucketErrorQueue = [serverError]
        let vm = makeVM(mock)

        await vm.load()

        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoaded, "a list of periods without its first page is not a read")
    }

    @MainActor
    func test_AC_149_tagAssets_retryShowsLoadingThenData() async {
        let mock = twoPeriodMock()
        mock.timeBucketsErrorQueue = [serverError]
        let vm = makeVM(mock)
        await vm.load()
        let latch = TestLatch()
        mock.timelineGate = { _ in try? await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.load() }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])
    }

    @MainActor
    func test_AC_152_tagAssets_refreshFailureKeepsDataThenRetryClears() async {
        let mock = twoPeriodMock()
        let vm = makeVM(mock)
        await vm.load()

        mock.timeBucketsErrorQueue = [serverError]
        await vm.refresh()

        XCTAssertEqual(vm.renderState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])

        // A failing first page keeps the grid too.
        mock.timeBucketErrorQueue = [serverError]
        await vm.refresh()
        XCTAssertEqual(vm.renderState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])

        await vm.load()
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_tagAssets_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock)
        await vm.load()
        XCTAssertEqual(vm.renderState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        mock.timelineGate = { _ in try? await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 1 }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .empty)
        let loaded = twoPeriodMock()
        mock.bucketsResponse = loaded.bucketsResponse
        mock.bucketResponses = loaded.bucketResponses
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .data(.idle))

        // From the error state.
        mock.timelineGate = nil
        let failing = makeVM(mock)
        mock.timeBucketsErrorQueue = [serverError]
        await failing.load()
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        mock.timelineGate = { _ in try? await errorLatch.wait() }
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refresh() }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 1 }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_tagAssets_refreshDuringReadIsNotIgnored() async {
        let mock = twoPeriodMock()
        let latch = TestLatch()
        let calls = TestBox(0)
        mock.timelineGate = { key in
            guard key == "buckets" else { return }
            calls.value += 1
            if calls.value == 1 { try? await latch.wait() }
        }
        let vm = makeVM(mock)

        let first = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }
        await vm.refresh()
        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])

        // The superseded read fails late: it must not write.
        mock.timeBucketsErrorQueue = [serverError]
        latch.open()
        await first.value

        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func test_AC_143_tagAssets_dataKeptDuringRefresh() async {
        let mock = twoPeriodMock()
        let vm = makeVM(mock)
        await vm.load()

        let listLatch = TestLatch()
        let pageLatch = TestLatch()
        mock.timelineGate = { key in
            if key == "buckets" { try? await listLatch.wait() } else { try? await pageLatch.wait() }
        }
        let before = mock.requestCount
        let pull = Task { @MainActor in await vm.refresh() }

        await pollUntil("bucket list in flight") { mock.requestCount == before + 1 }
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])
        XCTAssertEqual(vm.renderState, .data(.idle))

        listLatch.open()
        await pollUntil("first period in flight") { mock.requestCount == before + 2 }
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"], "the grid stays until the first period arrives")
        XCTAssertEqual(vm.renderState, .data(.idle))

        pageLatch.open()
        await pull.value
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])
        XCTAssertEqual(vm.renderState, .data(.idle))
    }
}
