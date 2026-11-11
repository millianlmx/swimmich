import XCTest
@testable import ImmichSwiftUI

/// The library of one partner (L-08): which filters reach the server, how the
/// periods page in, how the photos are grouped and what the screen's states are.
final class PartnerLibraryViewModelTests: XCTestCase {

    private struct BoomError: Error {}

    /// A bucket in columns; each entry is an id and the `fileCreatedAt` stamp
    /// of that photo (the grid groups and orders by it).
    private func columnar(_ entries: [(id: String, stamp: String)], owner: String = "partner-a") -> TimeBucketAssetResponseDto {
        TimeBucketAssetResponseDto(
            id: entries.map(\.id),
            ownerId: entries.map { _ in owner },
            ratio: entries.map { _ in 1.0 },
            isFavorite: entries.map { _ in false },
            visibility: entries.map { _ in "timeline" },
            isTrashed: entries.map { _ in false },
            isImage: entries.map { _ in true },
            thumbhash: entries.map { _ in nil },
            createdAt: entries.map(\.stamp),
            fileCreatedAt: entries.map(\.stamp),
            localOffsetHours: entries.map { _ in 0.0 },
            duration: entries.map { _ in nil },
            livePhotoVideoId: entries.map { _ in nil },
            projectionType: entries.map { _ in nil },
            stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
        )
    }

    private func columnar(ids: [String], day: String) -> TimeBucketAssetResponseDto {
        columnar(ids.map { (id: $0, stamp: "\(day)T10:00:00.000Z") })
    }

    /// Three periods, newest first: `a1 a2`, `b1`, `c1`.
    @MainActor
    private func threePeriodMock() -> MockImmichClient {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-06-01", count: 1),
            TimeBucketsResponseDto(timeBucket: "2024-05-01", count: 1),
        ]
        mock.bucketResponses["2024-07-01"] = columnar(ids: ["a1", "a2"], day: "2024-07-01")
        mock.bucketResponses["2024-06-01"] = columnar(ids: ["b1"], day: "2024-06-01")
        mock.bucketResponses["2024-05-01"] = columnar(ids: ["c1"], day: "2024-05-01")
        return mock
    }

    @MainActor
    private func makeVM(_ mock: MockImmichClient) -> PartnerLibraryViewModel {
        PartnerLibraryViewModel(client: mock, partnerId: "partner-a", partnerName: "Ivan")
    }

    @MainActor
    func test_AC_18_3_requestsPartnerUserIdWithTimelineVisibilityOnBothRoutes() async {
        let mock = threePeriodMock()
        let vm = makeVM(mock)

        await vm.load()

        let expected = TimelineFilterCapture(
            isFavorite: nil, isTrashed: nil, personId: nil, withPartners: nil,
            visibility: "timeline", withStacked: nil, orderBy: nil, tagId: nil, userId: "partner-a"
        )
        XCTAssertEqual(mock.lastTimeBucketsFilters, expected)
        XCTAssertEqual(mock.lastTimeBucketsUserId, "partner-a")
        XCTAssertEqual(mock.timeBucketCalls.map { $0.filters }, [expected])
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])
    }

    @MainActor
    func test_AC_18_4_loadMoreReachesOldestPeriodInOrder() async {
        let mock = threePeriodMock()
        let vm = makeVM(mock)

        await vm.load()
        XCTAssertTrue(vm.hasMore)
        await vm.loadMore()
        await vm.loadMore()

        XCTAssertEqual(mock.timeBucketCalls.map(\.timeBucket), ["2024-07-01", "2024-06-01", "2024-05-01"])
        XCTAssertFalse(vm.hasMore)
        XCTAssertEqual(vm.loadedBucketCount, 3)
        XCTAssertTrue(vm.items.map(\.id).contains("c1"), "the oldest period's photo is reachable")
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "b1", "c1"])
    }

    @MainActor
    func test_AC_18_4_emptyPeriodNeverEndsPaging() async {
        let mock = threePeriodMock()
        mock.bucketResponses["2024-06-01"] = nil // the mock answers an empty month
        let vm = makeVM(mock)

        await vm.load()
        await vm.loadMore()

        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "c1"], "one page crosses the empty month")
        XCTAssertFalse(vm.hasMore)
        XCTAssertNil(vm.loadMoreErrorMessage)
    }

    @MainActor
    func test_AC_18_4_sectionsFollowGroupBy() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 3),
            TimeBucketsResponseDto(timeBucket: "2024-06-01", count: 1),
        ]
        mock.bucketResponses["2024-07-01"] = columnar([
            (id: "j2", stamp: "2024-07-02T09:00:00.000Z"),
            (id: "j2b", stamp: "2024-07-02T08:00:00.000Z"),
            (id: "j1", stamp: "2024-07-01T09:00:00.000Z"),
        ])
        mock.bucketResponses["2024-06-01"] = columnar(ids: ["m1"], day: "2024-06-15")
        let vm = makeVM(mock)
        await vm.load()
        await vm.loadMore()

        func shape(_ sections: [TimelineSectionBuilder.Section]) -> (months: Int, days: Int, monthGroups: Int, flat: [Int]) {
            var months = 0, days = 0, monthGroups = 0
            var flat: [Int] = []
            for section in sections {
                switch section {
                case .monthHeader: months += 1
                case .dayGroup: days += 1
                case .monthGroup: monthGroups += 1
                case .flat(let items): flat.append(items.count)
                }
            }
            return (months, days, monthGroups, flat)
        }

        let day = shape(vm.sections(groupBy: .day))
        XCTAssertEqual(day.months, 2)
        XCTAssertEqual(day.days, 3)
        let month = shape(vm.sections(groupBy: .month))
        XCTAssertEqual(month.months, 2)
        XCTAssertEqual(month.monthGroups, 2)
        XCTAssertEqual(month.days, 0)
        let none = shape(vm.sections(groupBy: .none))
        XCTAssertEqual(none.flat, [4], "one run holding every photo, no header")
        XCTAssertEqual(none.months, 0)
        XCTAssertEqual(none.days, 0)
    }

    @MainActor
    func test_AC_18_4_noPhotosGiveNoSections() {
        let vm = makeVM(MockImmichClient())
        XCTAssertTrue(vm.sections(groupBy: .day).isEmpty)
    }

    @MainActor
    func test_AC_18_5_itemsFollowGridOrder() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 4)]
        mock.bucketResponses["2024-07-01"] = columnar([
            (id: "x1", stamp: "2024-07-01T08:00:00.000Z"),
            (id: "x2", stamp: "2024-07-02T09:00:00.000Z"),
            (id: "x3", stamp: "2024-07-01T12:00:00.000Z"),
            (id: "x4", stamp: "2024-07-02T10:00:00.000Z"),
        ])
        let vm = makeVM(mock)

        await vm.load()

        XCTAssertEqual(vm.items.map(\.id), ["x4", "x2", "x3", "x1"], "day descending, then time descending")
        XCTAssertEqual(vm.items.map(\.id), vm.groupedByDay.flatMap(\.items).map(\.id), "the viewer pages in grid order")
    }

    @MainActor
    func test_AC_18_6_failureThenEmptyThenPhotos() async {
        let mock = threePeriodMock()
        let vm = makeVM(mock)

        mock.timeBucketsErrorQueue = [BoomError()]
        await vm.load()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.items.isEmpty)

        mock.bucketsResponse = []
        await vm.load()
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertNil(vm.errorMessage)

        mock.bucketsResponse = threePeriodMock().bucketsResponse
        await vm.refresh()
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_AC_18_6_listOfEmptyPeriodsIsEmptyNotError() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 0),
            TimeBucketsResponseDto(timeBucket: "2024-06-01", count: 0),
        ]
        let vm = makeVM(mock)

        await vm.load()

        XCTAssertTrue(vm.hasLoaded)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertFalse(vm.hasMore)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(mock.timeBucketCalls.count, 2, "every month is read before the screen says empty")
    }

    @MainActor
    func test_AC_18_6_isLoadingDuringRequests() async {
        let mock = threePeriodMock()
        let vm = makeVM(mock)
        let seen = TestBox<[(loading: Bool, refreshing: Bool)]>([])
        mock.timeBucketGate = { _ in seen.value.append((vm.isLoading, vm.isRefreshing)) }

        await vm.load()
        XCTAssertEqual(seen.value.count, 1)
        XCTAssertTrue(seen.value[0].loading)
        XCTAssertFalse(seen.value[0].refreshing)
        XCTAssertFalse(vm.isLoading)

        await vm.refresh()
        XCTAssertEqual(seen.value.count, 2)
        XCTAssertTrue(seen.value[1].loading)
        XCTAssertTrue(seen.value[1].refreshing)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
    }

    @MainActor
    func test_AC_18_6_refreshFailureKeepsPhotos() async {
        let mock = threePeriodMock()
        let vm = makeVM(mock)
        await vm.load()
        let before = vm.items.map(\.id)
        XCTAssertTrue(vm.hasMore)

        mock.timeBucketsErrorQueue = [BoomError()]
        await vm.load()
        XCTAssertNotNil(vm.errorMessage, "the list failed")
        XCTAssertEqual(vm.items.map(\.id), before)
        XCTAssertTrue(vm.hasMore)
        XCTAssertTrue(vm.hasLoaded)

        mock.timeBucketErrorQueue = [BoomError()]
        await vm.load()
        XCTAssertNotNil(vm.errorMessage, "the first period failed")
        XCTAssertEqual(vm.items.map(\.id), before)
        XCTAssertTrue(vm.hasMore)

        await vm.load()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.items.map(\.id), before)
    }

    @MainActor
    func test_AC_18_6_refreshKeepsPhotosUntilFirstPeriodArrives() async {
        let mock = threePeriodMock()
        let vm = makeVM(mock)
        await vm.load()
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])

        mock.bucketResponses["2024-07-01"] = columnar(ids: ["n1", "n2"], day: "2024-07-01")
        let latch = TestLatch()
        mock.timeBucketGate = { _ in try await latch.wait() }
        let refresh = Task { await vm.refresh() }
        await pollUntil("the first period of the refresh") { mock.timeBucketCalls.count == 2 }

        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"], "the old photos stay until the new first period arrives")
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.isRefreshing)

        latch.open()
        await refresh.value
        XCTAssertEqual(vm.items.map(\.id), ["n1", "n2"])
        XCTAssertFalse(vm.isRefreshing)
    }

    @MainActor
    func test_AC_18_6_loadMoreFailureKeepsGridAndRetries() async {
        let mock = threePeriodMock()
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
        XCTAssertEqual(
            mock.timeBucketCalls.map(\.timeBucket),
            ["2024-07-01", "2024-06-01", "2024-06-01"],
            "the retry reads the same period again"
        )
    }

    @MainActor
    func test_AC_18_6_staleRefreshIgnoresInFlightPage() async {
        let mock = threePeriodMock()
        let vm = makeVM(mock)
        await vm.load()

        let latch = TestLatch()
        mock.timeBucketGate = { key in if key == "2024-06-01" { try await latch.wait() } }
        let page = Task { await vm.loadMore() }
        await pollUntil("the second period requested") { mock.timeBucketCalls.last?.timeBucket == "2024-06-01" }

        mock.bucketResponses["2024-07-01"] = columnar(ids: ["n1"], day: "2024-07-01")
        await vm.refresh()
        XCTAssertEqual(vm.items.map(\.id), ["n1"])

        latch.open()
        await page.value

        XCTAssertEqual(vm.items.map(\.id), ["n1"], "the page of the replaced list adds nothing")
        XCTAssertTrue(vm.hasMore)
        XCTAssertEqual(vm.loadedBucketCount, 1)
        XCTAssertNil(vm.loadMoreErrorMessage)
    }
}
