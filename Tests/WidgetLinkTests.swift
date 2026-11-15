import XCTest
@testable import ImmichSwiftUI

/// Where a widget link leads, and what it needs from the timeline (L-28, B-32.8).
final class WidgetLinkTests: XCTestCase {

    private func columnar(ids: [String], day: String = "2024-07-01") -> TimeBucketAssetResponseDto {
        TimeBucketAssetResponseDto(
            id: ids,
            ownerId: ids.map { _ in "owner" },
            ratio: ids.map { _ in 1.0 },
            isFavorite: ids.map { _ in false },
            visibility: ids.map { _ in "timeline" },
            isTrashed: ids.map { _ in false },
            isImage: ids.map { _ in true },
            thumbhash: ids.map { _ in nil },
            createdAt: ids.map { _ in "\(day)T00:00:00.000Z" },
            fileCreatedAt: ids.map { _ in "\(day)T00:00:00.000Z" },
            localOffsetHours: ids.map { _ in 0.0 },
            duration: ids.map { _ in nil },
            livePhotoVideoId: ids.map { _ in nil },
            projectionType: ids.map { _ in nil },
            stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
        )
    }

    private func makeMock() -> MockImmichClient {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-06-01", count: 1),
        ]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["a1", "a2"], day: "2024-07-01"),
            "2024-06-01": columnar(ids: ["b1"], day: "2024-06-01"),
        ]
        return mock
    }

    // AC-344: the three links lead to their tabs, and only the asset link names a photo.
    func test_AC_344_routes() {
        let asset = WidgetLinkRoute(.asset(id: "a1", day: "2024-07-01T00:00:00.000Z"))
        XCTAssertEqual(asset.tab, .photos)
        XCTAssertEqual(asset.viewerAsset?.id, "a1")
        XCTAssertEqual(asset.viewerAsset?.day, "2024-07-01T00:00:00.000Z")
        XCTAssertFalse(asset.startsBackup)

        let withoutDay = WidgetLinkRoute(.asset(id: "a2", day: nil))
        XCTAssertEqual(withoutDay.viewerAsset, LinkedAssetRequest(id: "a2", day: nil))

        let memories = WidgetLinkRoute(.memories)
        XCTAssertEqual(memories.tab, .memories)
        XCTAssertNil(memories.viewerAsset)
        XCTAssertFalse(memories.startsBackup)

        let backup = WidgetLinkRoute(.backup)
        XCTAssertEqual(backup.tab, .photos)
        XCTAssertNil(backup.viewerAsset)
        XCTAssertTrue(backup.startsBackup)
    }

    // AC-344: two taps on the same photo are two events, though the request reads the same.
    func test_AC_344_eachTapIsItsOwnEvent() {
        let first = LinkedAssetRequest(id: "a1", day: nil)
        let second = LinkedAssetRequest(id: "a1", day: nil)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertNotEqual(PendingWidgetLink(link: .memories).id, PendingWidgetLink(link: .memories).id)
    }

    // AC-344: a photo of the loaded timeline opens in place, paging through the timeline.
    @MainActor
    func test_AC_344_resolveOpensAPhotoOfTheLoadedTimeline() async {
        let mock = makeMock()
        let vm = TimelineViewModel(client: mock)
        await vm.load()

        let resolution = await vm.resolveLinkedAsset(id: "a2", day: nil)

        XCTAssertEqual(resolution, .open(assets: vm.items, index: vm.items.firstIndex { $0.id == "a2" }!, inTimeline: true))
        XCTAssertEqual(mock.getAssetCalls, ["a2"])
    }

    // AC-344: a cold link finds the grid unloaded and starts its first page.
    @MainActor
    func test_AC_344_resolveStartsTheFirstPageForAColdLink() async {
        let mock = makeMock()
        let vm = TimelineViewModel(client: mock)
        XCTAssertTrue(vm.items.isEmpty)

        let resolution = await vm.resolveLinkedAsset(id: "a1", day: nil)

        guard case let .open(assets, index, inTimeline) = resolution else { return XCTFail("\(resolution)") }
        XCTAssertTrue(inTimeline)
        XCTAssertEqual(assets[index].id, "a1")
    }

    // AC-344: a photo of a month that is not loaded: the grid jumps to its day first.
    @MainActor
    func test_AC_344_resolveJumpsToTheDayOfAPhotoThatIsNotLoaded() async {
        let mock = makeMock()
        let vm = TimelineViewModel(client: mock)
        await vm.load()
        XCTAssertFalse(vm.items.contains { $0.id == "b1" })

        let resolution = await vm.resolveLinkedAsset(id: "b1", day: "2024-06-01")

        guard case let .open(assets, index, inTimeline) = resolution else { return XCTFail("\(resolution)") }
        XCTAssertTrue(inTimeline)
        XCTAssertEqual(assets[index].id, "b1")
    }

    // AC-344: a photo the timeline does not hold (no day, or not in that month) opens alone.
    @MainActor
    func test_AC_344_resolveOpensALonePhotoWhenTheTimelineDoesNotHoldIt() async {
        let mock = makeMock()
        let vm = TimelineViewModel(client: mock)
        await vm.load()

        let resolution = await vm.resolveLinkedAsset(id: "elsewhere", day: nil)

        guard case let .open(assets, index, inTimeline) = resolution else { return XCTFail("\(resolution)") }
        XCTAssertFalse(inTimeline)
        XCTAssertEqual(index, 0)
        XCTAssertEqual(assets.map(\.id), ["elsewhere"])
    }

    // AC-345: a server that cannot be asked (no session, 401, offline) opens nothing.
    @MainActor
    func test_AC_345_linkDroppedWithoutSession() async {
        let failures: [Error] = [APIError.unauthorized, APIError.network(URLError(.notConnectedToInternet))]
        for failure in failures {
            let mock = makeMock()
            mock.getAssetGate = { _ in throw failure }
            let vm = TimelineViewModel(client: mock)

            let resolution = await vm.resolveLinkedAsset(id: "a1", day: "2024-07-01")

            XCTAssertEqual(resolution, .unavailable, "\(failure)")
        }
    }

    // AC-346: a photo the server refuses (404, or 400 for another account's) is asked about once,
    // opens nothing, and does not touch the timeline.
    @MainActor
    func test_AC_346_refusedAssetIsUnavailableOnce() async {
        for status in [404, 400] {
            let mock = makeMock()
            mock.getAssetGate = { _ in throw APIError.serverError(status, "refused") }
            let vm = TimelineViewModel(client: mock)

            let resolution = await vm.resolveLinkedAsset(id: "gone", day: "2024-06-01")

            XCTAssertEqual(resolution, .unavailable, "status \(status)")
            XCTAssertEqual(mock.getAssetCalls, ["gone"], "one request, no retry")
            XCTAssertEqual(mock.requestCount, 1, "no jump, no first page behind a refused photo")
            XCTAssertTrue(vm.items.isEmpty)
        }
    }
}
