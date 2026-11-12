import XCTest
@testable import ImmichSwiftUI

/// Behaviour of the two "recent" grids (gap G13): which sort axis reaches the
/// server, how days are grouped, and how the footer pagination accumulates.
///
/// Nothing here pins a user-visible label: the titles live in `RecentAssetsMode`
/// and would change with the interface language, which is exactly the trap this
/// suite must not walk into.
final class RecentAssetsViewModelTests: XCTestCase {

    /// Builds a columnar bucket payload with `ids` in the given order.
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

    private struct BoomError: Error {}

    // MARK: - Sort axis

    @MainActor
    func test_takenMode_requestsBucketsOrderedByTakenAt() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)]
        mock.bucketResponses = ["2024-07-01": columnar(ids: ["a1"])]

        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()

        XCTAssertEqual(mock.lastTimeBucketsOrderBy, .takenAt)
        XCTAssertEqual(mock.lastTimeBucketsWithStacked, true, "the +N badge needs stack primaries")
    }

    @MainActor
    func test_addedMode_requestsBucketsOrderedByCreatedAt() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)]
        mock.bucketResponses = ["2024-07-01": columnar(ids: ["a1"])]

        let vm = RecentAssetsViewModel(client: mock, mode: .added)
        await vm.load()

        XCTAssertEqual(mock.lastTimeBucketsOrderBy, .createdAt)
    }

    // MARK: - Grouping

    @MainActor
    func test_load_groupsItemsByBucketDay() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-02", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)
        ]
        mock.bucketResponses = [
            "2024-07-02": columnar(ids: ["b1", "b2"], day: "2024-07-02"),
            "2024-07-01": columnar(ids: ["c1"], day: "2024-07-01")
        ]

        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()

        // Only the newest day is loaded up front: the other comes from loadMore.
        XCTAssertEqual(vm.dayGroups.count, 1)
        XCTAssertEqual(vm.dayGroups.map(\.id), ["2024-07-02"])
        XCTAssertEqual(vm.dayGroups[0].items.map(\.id), ["b1", "b2"])
        XCTAssertFalse(vm.dayGroups[0].title.isEmpty, "the day label is formatted by the view model")
    }

    // MARK: - Footer pagination

    @MainActor
    func test_loadMore_appendsOlderBucketsAtTheEnd() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-02", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)
        ]
        mock.bucketResponses = [
            "2024-07-02": columnar(ids: ["b1", "b2"], day: "2024-07-02"),
            "2024-07-01": columnar(ids: ["c1", "c2"], day: "2024-07-01")
        ]

        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()
        await vm.loadMore()

        // Older day appended BELOW the loaded one — the timeline prepends, this
        // grid must not (it only ever scrolls down).
        XCTAssertEqual(vm.dayGroups.map(\.id), ["2024-07-02", "2024-07-01"])
        XCTAssertEqual(vm.dayGroups.flatMap { $0.items.map(\.id) }, ["b1", "b2", "c1", "c2"])
    }

    @MainActor
    func test_loadMore_dedupesAssetsAlreadyLoaded() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-02", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)
        ]
        // "b2" sits in both days (an asset uploaded and taken on different days).
        mock.bucketResponses = [
            "2024-07-02": columnar(ids: ["b1", "b2"], day: "2024-07-02"),
            "2024-07-01": columnar(ids: ["b2", "c1"], day: "2024-07-01")
        ]

        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()
        await vm.loadMore()

        XCTAssertEqual(vm.dayGroups.flatMap { $0.items.map(\.id) }, ["b1", "b2", "c1"])
        XCTAssertEqual(vm.dayGroups.count, 2, "the second day keeps only its unseen item")
        XCTAssertEqual(vm.dayGroups[1].items.map(\.id), ["c1"])
    }

    @MainActor
    func test_loadMore_stopsAtTheLastBucket() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-02", count: 1)]
        mock.bucketResponses = ["2024-07-02": columnar(ids: ["b1"], day: "2024-07-02")]

        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()
        XCTAssertFalse(vm.hasMore, "no bucket left after the first day")

        let callsAfterLoad = mock.requestCount
        await vm.loadMore()

        XCTAssertEqual(mock.requestCount, callsAfterLoad, "loadMore must not hit the client")
        XCTAssertEqual(vm.dayGroups.flatMap { $0.items.map(\.id) }, ["b1"])
    }

    // MARK: - Failure and refresh

    @MainActor
    func test_load_failure_surfacesMessageAndKeepsEmptyGrid() async {
        let mock = MockImmichClient()
        mock.globalError = BoomError()

        let vm = RecentAssetsViewModel(client: mock, mode: .added)
        await vm.load()

        XCTAssertNotNil(vm.errorMessage, "the screen replays load() from this message")
        XCTAssertTrue(vm.dayGroups.isEmpty)
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertEqual(vm.renderState, .error(vm.errorMessage ?? ""))
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func test_refresh_replacesTheGrid() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-02", count: 1)]
        mock.bucketResponses = ["2024-07-02": columnar(ids: ["b1"], day: "2024-07-02")]

        let vm = RecentAssetsViewModel(client: mock, mode: .added)
        await vm.load()
        XCTAssertEqual(vm.dayGroups.flatMap { $0.items.map(\.id) }, ["b1"])

        // A new upload lands: the bucket list itself changes, so refresh must
        // rebuild the grid rather than append to what is on screen.
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-03", count: 1)]
        mock.bucketResponses = ["2024-07-03": columnar(ids: ["d1"], day: "2024-07-03")]

        await vm.refresh()

        XCTAssertEqual(vm.dayGroups.map(\.id), ["2024-07-03"])
        XCTAssertEqual(vm.dayGroups.flatMap { $0.items.map(\.id) }, ["d1"])
        XCTAssertFalse(vm.hasMore)
    }

    // MARK: - /bucket repeats the /buckets filters

    @MainActor
    private func twoDayMock() -> MockImmichClient {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-02", count: 1),
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)
        ]
        mock.bucketResponses = [
            "2024-07-02": columnar(ids: ["b1"], day: "2024-07-02"),
            "2024-07-01": columnar(ids: ["c1"], day: "2024-07-01")
        ]
        return mock
    }

    @MainActor
    func test_AC5_addedMode_bucketsAndBucketShareCreatedAt() async {
        let mock = twoDayMock()
        let vm = RecentAssetsViewModel(client: mock, mode: .added)
        await vm.load()
        await vm.loadMore()

        XCTAssertEqual(mock.timeBucketCalls.map(\.timeBucket), ["2024-07-02", "2024-07-01"])
        for call in mock.timeBucketCalls {
            XCTAssertEqual(call.filters.orderBy, .createdAt)
            XCTAssertEqual(call.filters, mock.lastTimeBucketsFilters)
        }
    }

    @MainActor
    func test_AC6_takenMode_bucketSendsTakenAt() async {
        let mock = twoDayMock()
        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()

        XCTAssertEqual(mock.lastTimeBucketOrderBy, .takenAt)
        XCTAssertEqual(mock.lastTimeBucketOrderBy, mock.lastTimeBucketsOrderBy)
    }

    @MainActor
    func test_AC18_addedMode_everyBucketCallMatchesBucketsFilters() async {
        for mode in [RecentAssetsMode.added, .taken] {
            let mock = twoDayMock()
            let vm = RecentAssetsViewModel(client: mock, mode: mode)
            await vm.load()
            await vm.loadMore()

            XCTAssertEqual(mock.timeBucketCalls.count, 2)
            XCTAssertNotNil(mock.lastTimeBucketsFilters)
            for call in mock.timeBucketCalls {
                XCTAssertEqual(call.filters, mock.lastTimeBucketsFilters, "\(mode) \(call.timeBucket)")
            }
        }
    }

    // MARK: - List states (L-16)

    private let serverError = APIError.serverError(500, "x")

    /// One day, one asset: the smallest data a read can return.
    @MainActor
    private func oneDayMock(_ day: String = "2024-07-02", id: String = "b1") -> MockImmichClient {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: day, count: 1)]
        mock.bucketResponses = [day: columnar(ids: [id], day: day)]
        return mock
    }

    /// Suspends every `getTimeBuckets` on `latch` (or only the first one) and
    /// counts how many arrived.
    private func bucketsGate(
        _ latch: TestLatch,
        calls: TestBox<Int>,
        firstOnly: Bool = false
    ) -> (String) async -> Void {
        return { key in
            guard key == "buckets" else { return }
            calls.value += 1
            if !firstOnly || calls.value == 1 { try? await latch.wait() }
        }
    }

    @MainActor
    func test_AC_142_recent_loadingUntilFirstAnswer() async {
        let mock = oneDayMock()
        let latch = TestLatch()
        let calls = TestBox(0)
        mock.timelineGate = bucketsGate(latch, calls: calls)
        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        XCTAssertEqual(vm.renderState, .loading)

        let read = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { calls.value == 1 }

        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_149_recent_firstReadFailsShowsErrorNotEmpty() async {
        let mock = oneDayMock()
        mock.globalError = serverError
        let vm = RecentAssetsViewModel(client: mock, mode: .taken)

        await vm.load()

        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.dayGroups.isEmpty)
    }

    @MainActor
    func test_AC_147_recent_successfulEmptyReadIsEmptyState() async {
        let vm = RecentAssetsViewModel(client: MockImmichClient(), mode: .taken)

        await vm.load()

        XCTAssertEqual(vm.renderState, .empty)
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertFalse(vm.hasMore)
    }

    @MainActor
    func test_AC_149_recent_retryShowsLoadingThenData() async {
        let mock = oneDayMock()
        mock.globalError = serverError
        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()
        mock.globalError = nil
        let latch = TestLatch()
        let calls = TestBox(0)
        mock.timelineGate = bucketsGate(latch, calls: calls)

        let retry = Task { @MainActor in await vm.load() }
        await pollUntil("retry in flight") { calls.value == 1 }

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(vm.dayGroups.flatMap { $0.items.map(\.id) }, ["b1"])
    }

    @MainActor
    func test_AC_152_recent_refreshFailureKeepsDataThenRetryClears() async {
        let mock = oneDayMock()
        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()

        mock.globalError = serverError
        await vm.refresh()

        XCTAssertEqual(vm.renderState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.dayGroups.flatMap { $0.items.map(\.id) }, ["b1"])

        mock.globalError = nil
        await vm.load()
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_152_recent_loadMoreFailureKeepsDaysAsBanner() async {
        let mock = twoDayMock()
        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()

        mock.timeBucketErrorQueue = [serverError]
        await vm.loadMore()

        XCTAssertEqual(vm.renderState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.dayGroups.map(\.id), ["2024-07-02"])
        XCTAssertTrue(vm.hasMore, "the sentinel can ask again")

        await vm.loadMore()
        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(vm.dayGroups.map(\.id), ["2024-07-02", "2024-07-01"])
    }

    @MainActor
    func test_AC_154_recent_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()
        XCTAssertEqual(vm.renderState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        let emptyCalls = TestBox(0)
        mock.timelineGate = bucketsGate(emptyLatch, calls: emptyCalls)
        let emptyPull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull from empty in flight") { emptyCalls.value == 1 }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .empty)
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-02", count: 1)]
        mock.bucketResponses = ["2024-07-02": columnar(ids: ["b1"], day: "2024-07-02")]
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .data(.idle))

        // From the error state.
        mock.timelineGate = nil
        let failing = RecentAssetsViewModel(client: mock, mode: .taken)
        mock.globalError = serverError
        await failing.load()
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        let errorCalls = TestBox(0)
        mock.timelineGate = bucketsGate(errorLatch, calls: errorCalls)
        let errorPull = Task { @MainActor in await failing.refresh() }
        await pollUntil("pull from error in flight") { errorCalls.value == 1 }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        mock.globalError = nil
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_recent_refreshDuringReadIsNotIgnored() async {
        let mock = oneDayMock()
        let latch = TestLatch()
        let calls = TestBox(0)
        mock.timelineGate = bucketsGate(latch, calls: calls, firstOnly: true)
        let vm = RecentAssetsViewModel(client: mock, mode: .taken)

        let first = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { calls.value == 1 }
        await vm.refresh()
        XCTAssertEqual(calls.value, 2, "a pull during a read is a request of its own")
        XCTAssertEqual(vm.renderState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.globalError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }

    /// The grid on screen survives a refresh until the first day of the new
    /// series arrived (try-then-write).
    @MainActor
    func test_AC_143_recent_gridKeptUntilFirstDayArrives() async {
        let mock = oneDayMock("2024-07-02", id: "b1")
        let vm = RecentAssetsViewModel(client: mock, mode: .taken)
        await vm.load()
        XCTAssertEqual(vm.dayGroups.map(\.id), ["2024-07-02"])

        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-03", count: 1)]
        mock.bucketResponses = ["2024-07-03": columnar(ids: ["d1"], day: "2024-07-03")]
        let bucketsLatch = TestLatch()
        let dayLatch = TestLatch()
        mock.timelineGate = { key in
            try? await (key == "buckets" ? bucketsLatch : dayLatch).wait()
        }
        let pull = Task { @MainActor in await vm.refresh() }
        await pollUntil("buckets request in flight") { mock.requestCount == 3 }

        XCTAssertEqual(vm.dayGroups.map(\.id), ["2024-07-02"], "kept while the bucket list is read")
        XCTAssertEqual(vm.renderState, .data(.idle))
        bucketsLatch.open()
        await pollUntil("first day request in flight") { mock.requestCount == 4 }

        XCTAssertEqual(vm.dayGroups.map(\.id), ["2024-07-02"], "kept while the first day is read")
        XCTAssertEqual(vm.renderState, .data(.idle))
        dayLatch.open()
        await pull.value

        XCTAssertEqual(vm.dayGroups.map(\.id), ["2024-07-03"])
        XCTAssertEqual(vm.renderState, .data(.idle))
    }
}
