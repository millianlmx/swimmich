import XCTest
@testable import ImmichSwiftUI

final class TimelineViewModelTests: XCTestCase {

    /// Builds a columnar TimeBucketAssetResponseDto with two well-known assets
    /// so the zip step has predictable per-index values (AC-013).
    private func columnar(
        ids: [String], ratios: [Double], thumbhashes: [String?], favorites: [Bool],
        owners: [String]? = nil, visibilities: [String]? = nil, stacks: [[String]?]? = nil
    ) -> TimeBucketAssetResponseDto {
        TimeBucketAssetResponseDto(
            id: ids,
            ownerId: owners ?? ids.map { _ in "owner" },
            ratio: ratios,
            isFavorite: favorites,
            visibility: visibilities ?? ids.map { _ in "timeline" },
            isTrashed: ids.map { _ in false },
            isImage: ids.map { _ in true },
            thumbhash: thumbhashes,
            createdAt: ids.map { _ in "2024-07-01T00:00:00.000Z" },
            fileCreatedAt: ids.map { _ in "2024-07-01T00:00:00.000Z" },
            localOffsetHours: ids.map { _ in 0.0 },
            duration: ids.map { _ in nil },
            livePhotoVideoId: ids.map { _ in nil },
            projectionType: ids.map { _ in nil },
            stack: stacks, city: nil, country: nil, latitude: nil, longitude: nil
        )
    }

    // AC-006: bucket-level pagination accumulates with no dup IDs.
    @MainActor
    func test_AC_006_bucketPaginationNoDuplicates() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-06-01", count: 2)
        ]
        mock.bucketResponses = [
            "2024-07-01": columnar(
                ids: ["a1", "a2"], ratios: [0.75, 1.33], thumbhashes: ["h1", "h2"], favorites: [false, true]
            ),
            "2024-06-01": columnar(
                ids: ["a3", "a4"], ratios: [0.5, 2.0], thumbhashes: ["h3", "h4"], favorites: [true, false]
            )
        ]

        let vm = TimelineViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertEqual(Set(vm.items.map(\.id)), Set(["a1", "a2"]))

        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 4)
        XCTAssertEqual(Set(vm.items.map(\.id)), Set(["a1", "a2", "a3", "a4"]))

        // loadMore past the last bucket is a no-op (no dup, no growth).
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 4)
        XCTAssertEqual(vm.loadedIds.count, vm.items.count)
        XCTAssertFalse(vm.canLoadMore)
    }

    // AC-009: constructor-injected VM + mock client; state derived without network.
    @MainActor
    func test_AC_009_MVVMTestability() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["x"], ratios: [1.0], thumbhashes: [nil], favorites: [false])
        ]

        let vm = TimelineViewModel(client: mock)
        XCTAssertFalse(vm.isLoading)
        await vm.load()
        XCTAssertGreaterThan(mock.requestCount, 0)
        XCTAssertFalse(vm.items.isEmpty)
        XCTAssertEqual(vm.items.first?.id, "x")
    }

    // AC-013: columnar→object zip correctness (id[i]↔ratio[i]↔thumbhash[i]↔isFavorite[i]).
    @MainActor
    func test_AC_013_columnarZipCorrectness() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)]
        let ids = ["alpha", "beta"]
        let ratios = [0.75, 1.5]
        let thumbs = ["thumb-a", "thumb-b"]
        let favs = [false, true]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ids, ratios: ratios, thumbhashes: thumbs, favorites: favs)
        ]

        let vm = TimelineViewModel(client: mock)
        await vm.load()

        let alpha = vm.items.first { $0.id == "alpha" }
        let beta = vm.items.first { $0.id == "beta" }
        XCTAssertNotNil(alpha)
        XCTAssertNotNil(beta)
        XCTAssertEqual(alpha?.ratio, 0.75)
        XCTAssertEqual(alpha?.thumbhash, "thumb-a")
        XCTAssertEqual(alpha?.isFavorite, false)
        XCTAssertEqual(beta?.ratio, 1.5)
        XCTAssertEqual(beta?.thumbhash, "thumb-b")
        XCTAssertEqual(beta?.isFavorite, true)
    }

    // AC-013b: zip returns [] on malformed (length-mismatched) required arrays.
    func test_AC_013b_zipRejectsMalformed() {
        let bad = TimeBucketAssetResponseDto(
            id: ["a", "b"],
            ownerId: ["o"], // wrong length
            ratio: [1, 1], isFavorite: [false, true], visibility: ["timeline", "timeline"],
            isTrashed: [false, false], isImage: [true, true], thumbhash: [nil, nil],
            createdAt: ["", ""], fileCreatedAt: ["", ""], localOffsetHours: [0, 0],
            duration: [nil, nil], livePhotoVideoId: [nil, nil], projectionType: [nil, nil],
            stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
        )
        XCTAssertTrue(AssetReactItem.zip(bad).isEmpty)
    }

    // AC-007: thumbnailURL canonical format.
    func test_AC_007_thumbnailURL() {
        let url = ImmichAssetURL.thumbnail(
            assetId: "abc123",
            thumbhash: "xyz",
            baseURL: URL(string: "https://example.com")!
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://example.com/api/assets/abc123/thumbnail?size=thumbnail&c=xyz"
        )
    }

    // MARK: - AC-100: groupedByDay semantics (prefix-10 grouping, day desc, intra-day desc)

    @MainActor
    func test_AC_100_groupedByDay() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "mixed", count: 4)]
        // Items intentionally out of day/time order to prove the sort is real.
        mock.bucketResponses = [
            "mixed": TimeBucketAssetResponseDto(
                id: ["x1", "x2", "x3", "x4"],
                ownerId: ["o", "o", "o", "o"],
                ratio: [1.0, 1.0, 1.0, 1.0],
                isFavorite: [false, false, false, false],
                visibility: ["timeline", "timeline", "timeline", "timeline"],
                isTrashed: [false, false, false, false],
                isImage: [true, true, true, true],
                thumbhash: [nil, nil, nil, nil],
                createdAt: ["", "", "", ""],
                fileCreatedAt: [
                    "2024-07-02T10:00:00.000Z",  // x1 — day 02, later
                    "2024-07-01T08:00:00.000Z",  // x2 — day 01
                    "2024-07-02T09:00:00.000Z",  // x3 — day 02, earlier (must sort after x1)
                    "2024-07-03T12:00:00.000Z"   // x4 — day 03 (newest day first)
                ],
                localOffsetHours: [0, 0, 0, 0],
                duration: [nil, nil, nil, nil],
                livePhotoVideoId: [nil, nil, nil, nil],
                projectionType: [nil, nil, nil, nil],
                stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
            )
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.load()

        let groups = vm.groupedByDay
        XCTAssertEqual(groups.count, 3, "expected 3 distinct day groups")
        XCTAssertEqual(groups[0].day, "2024-07-03", "newest day first")
        XCTAssertEqual(groups[0].items.map(\.id), ["x4"])
        XCTAssertEqual(groups[1].day, "2024-07-02")
        XCTAssertEqual(groups[1].items.map(\.id), ["x1", "x3"], "intra-day desc by fileCreatedAt")
        XCTAssertEqual(groups[2].day, "2024-07-01")
        XCTAssertEqual(groups[2].items.map(\.id), ["x2"])
    }

    // MARK: - AC-201: selection-mode state machine

    @MainActor
    func test_AC_201_selectionState() async {
        let vm = TimelineViewModel(client: MockImmichClient())

        // Defaults.
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)

        // Toggle adds.
        vm.toggleSelection(id: "a")
        XCTAssertEqual(vm.selectedIds, ["a"])

        // Toggle removes.
        vm.toggleSelection(id: "a")
        XCTAssertTrue(vm.selectedIds.isEmpty)

        // Enter / exit.
        vm.enterSelectionMode()
        XCTAssertTrue(vm.selectionMode)
        vm.toggleSelection(id: "b")
        XCTAssertEqual(vm.selectedIds, ["b"])
        vm.exitSelectionMode()
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty, "exit must clear selectedIds")
    }

    // MARK: - AC-202: toggleFavorite fires updateAsset + patches items in place

    @MainActor
    func test_AC_202_toggleFavorite() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)]
        mock.bucketResponses = [
            "2024-07-01": columnar(
                ids: ["alpha", "beta"], ratios: [0.75, 1.5],
                thumbhashes: ["ta", "tb"], favorites: [false, true]
            )
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.load()

        // alpha starts false → toggling flips to true.
        await vm.toggleFavorite(id: "alpha")

        XCTAssertEqual(mock.lastUpdateAssetId, "alpha")
        XCTAssertEqual(mock.lastUpdateAssetBody?.isFavorite, true, "dto carries the toggled value")

        let alpha = vm.items.first { $0.id == "alpha" }
        XCTAssertEqual(alpha?.isFavorite, true, "items patched in place via with(isFavorite:)")

        // beta untouched.
        let beta = vm.items.first { $0.id == "beta" }
        XCTAssertEqual(beta?.isFavorite, true, "unrelated items unchanged")
    }

    // MARK: - AC-203: deleteSelected success removes ids + exits selection

    @MainActor
    func test_AC_203_deleteSelected() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 4)]
        mock.bucketResponses = [
            "2024-07-01": columnar(
                ids: ["a1", "a2", "a3", "a4"], ratios: [1, 1, 1, 1],
                thumbhashes: [nil, nil, nil, nil], favorites: [false, false, false, false]
            )
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.items.count, 4)

        // Empty selection → no-op.
        vm.enterSelectionMode()
        await vm.deleteSelected(currentUserId: nil)
        XCTAssertNil(mock.lastDeleteBody, "no delete call when nothing selected")
        XCTAssertEqual(vm.items.count, 4, "empty delete must not mutate items")

        // Select 2, delete.
        vm.toggleSelection(id: "a2")
        vm.toggleSelection(id: "a4")
        await vm.deleteSelected(currentUserId: nil)

        XCTAssertEqual(Set(mock.lastDeleteBody?.ids ?? []), ["a2", "a4"])
        XCTAssertEqual(mock.lastDeleteBody?.force, false)
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertEqual(Set(vm.items.map(\.id)), ["a1", "a3"])
        XCTAssertFalse(vm.loadedIds.contains("a2"))
        XCTAssertFalse(vm.loadedIds.contains("a4"))
        XCTAssertFalse(vm.selectionMode, "selection exited on success")
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    // MARK: - AC-203b: deleteSelected on throw leaves state intact for retry

    @MainActor
    func test_AC_203b_deleteSelectedError() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 4)]
        mock.bucketResponses = [
            "2024-07-01": columnar(
                ids: ["a1", "a2", "a3", "a4"], ratios: [1, 1, 1, 1],
                thumbhashes: [nil, nil, nil, nil], favorites: [false, false, false, false]
            )
        ]
        struct BoomError: Error {}
        mock.deleteError = BoomError()

        let vm = TimelineViewModel(client: mock)
        await vm.load()
        let before = vm.items.count
        let loadedBefore = vm.loadedIds

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a3")
        await vm.deleteSelected(currentUserId: nil)

        XCTAssertEqual(vm.items.count, before, "items unchanged on throw")
        XCTAssertEqual(vm.loadedIds, loadedBefore, "loadedIds unchanged on throw")
        XCTAssertEqual(vm.actionErrorMessage, localizedString("Something went wrong. Please try again."), "error surfaced to UI")
        XCTAssertEqual(vm.selectedIds, ["a1", "a3"], "selection preserved for retry")
        XCTAssertTrue(vm.selectionMode, "still in selection mode so user can retry")
    }

    // MARK: - AC-203c: batchSetFavorite reports success/failure so the view
    // only exits selection on success (audit fix)

    @MainActor
    func test_AC_203c_batchSetFavoriteErrorKeepsSelection() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["a1", "a2"], ratios: [1, 1], thumbhashes: [nil, nil], favorites: [false, false])
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.load()

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")

        struct BoomError: Error {}
        mock.globalError = BoomError()
        let succeeded = await vm.batchSetFavorite(vm.selectedIds, favorite: true)

        XCTAssertFalse(succeeded, "failed batch must report failure to the view")
        XCTAssertEqual(vm.actionErrorMessage, localizedString("Something went wrong. Please try again."), "error surfaced to UI")
        XCTAssertTrue(vm.selectionMode, "selection survives so the user can retry")
        XCTAssertEqual(vm.selectedIds, ["a1", "a2"])
        XCTAssertFalse(vm.items.first { $0.id == "a1" }?.isFavorite ?? true, "no mutation on throw")
    }

    @MainActor
    func test_AC_203d_batchSetFavoriteSuccessReportsTrue() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["a1", "a2"], ratios: [1, 1], thumbhashes: [nil, nil], favorites: [false, false])
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.load()

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")

        let succeeded = await vm.batchSetFavorite(vm.selectedIds, favorite: true)

        XCTAssertTrue(succeeded, "successful batch must report success so the view can exit")
        XCTAssertNil(vm.actionErrorMessage)
        XCTAssertTrue(vm.items.allSatisfy { $0.id != "a1" || $0.isFavorite })
    }

    // MARK: - AC-204: refresh re-fetches buckets then first bucket only

    @MainActor
    func test_AC_204_refresh() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-06-01", count: 2)
        ]
        mock.bucketResponses = [
            "2024-07-01": columnar(
                ids: ["a1", "a2"], ratios: [1, 1], thumbhashes: [nil, nil], favorites: [false, false]
            ),
            "2024-06-01": columnar(
                ids: ["a3", "a4"], ratios: [1, 1], thumbhashes: [nil, nil], favorites: [false, false]
            )
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.load()
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 4)
        let requestsBefore = mock.requestCount

        await vm.refresh()

        XCTAssertEqual(vm.items.count, 2, "refresh loads only the first bucket")
        XCTAssertEqual(Set(vm.items.map(\.id)), ["a1", "a2"])
        XCTAssertGreaterThan(mock.requestCount, requestsBefore)
        XCTAssertTrue(vm.canLoadMore, "can load second bucket again after refresh")
    }

    // MARK: - AC-205: AssetReactItem.with(isFavorite:) copy

    func test_AC_205_withIsFavorite_copy() {
        let dto = columnar(
            ids: ["p"], ratios: [0.75], thumbhashes: ["th"], favorites: [false]
        )
        let original = AssetReactItem.zip(dto).first!
        XCTAssertEqual(original.isFavorite, false)

        let copy = original.with(isFavorite: true)

        XCTAssertEqual(copy.isFavorite, true)
        XCTAssertEqual(original.isFavorite, false, "original unchanged")
        XCTAssertEqual(copy.id, original.id)
        XCTAssertEqual(copy.ratio, original.ratio)
        XCTAssertEqual(copy.thumbhash, original.thumbhash)
        XCTAssertNotEqual(original, copy, "Equatable divergence on favorite")
        XCTAssertEqual(copy.hashValue != original.hashValue, true, "Hashable reflects favorite")
    }

    // MARK: - Archive (P1 card 5/8)

    /// Seeds the VM with a single bucket of items for selection tests.
    @MainActor
    private func makeLoadedVM(_ mock: MockImmichClient) async -> TimelineViewModel {
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 3)]
        mock.bucketResponses = [
            "2024-07-01": columnar(
                ids: ["a1", "a2", "a3"], ratios: [1, 1, 1],
                thumbhashes: [nil, nil, nil], favorites: [false, false, false]
            )
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.load()
        return vm
    }

    @MainActor
    func test_archive_selected_bulkVisibilityArchive() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a3")

        await vm.archiveSelected(currentUserId: nil)

        XCTAssertEqual(mock.lastBulkUpdateDto?.ids.sorted(), ["a1", "a3"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .archive)
    }

    @MainActor
    func test_archive_selected_removesItemsAndExitsSelection() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a2")

        await vm.archiveSelected(currentUserId: nil)

        XCTAssertEqual(vm.items.map(\.id), ["a1", "a3"])
        XCTAssertEqual(vm.loadedIds, Set(["a1", "a3"]))
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    @MainActor
    func test_archive_selected_failureKeepsItems() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        mock.globalError = APIError.serverError(500, "boom")
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")

        await vm.archiveSelected(currentUserId: nil)

        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "a3"], "failure keeps items for retry")
        XCTAssertTrue(vm.selectionMode, "selection survives failure")
        XCTAssertEqual(vm.actionErrorMessage, localizedString("The server ran into a problem. Please try again."))
    }

    @MainActor
    func test_archive_single() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)

        await vm.archive(id: "a2")

        XCTAssertEqual(mock.lastBulkUpdateDto?.ids, ["a2"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .archive)
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a3"])
        XCTAssertEqual(vm.loadedIds, Set(["a1", "a3"]))
    }

    @MainActor
    func test_archive_emptySelection_isNoOp() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        vm.enterSelectionMode()

        await vm.archiveSelected(currentUserId: nil)

        XCTAssertNil(mock.lastBulkUpdateDto)
        XCTAssertEqual(vm.items.count, 3)
    }

    // MARK: - Filter (P1 card 6/8)

    @MainActor
    func test_filter_favorite_reloadsWithFavoriteParam() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)

        await vm.setFilter(.favorites)

        XCTAssertEqual(mock.lastTimeBucketsIsFavorite, true)
        XCTAssertNil(mock.lastTimeBucketsVisibility)
        XCTAssertFalse(mock.lastTimeBucketsIsTrashed ?? false)
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "a3"], "fresh reload after filter change")
    }

    @MainActor
    func test_filter_archive_visibility() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)

        await vm.setFilter(.archived)

        XCTAssertNil(mock.lastTimeBucketsIsFavorite)
        XCTAssertEqual(mock.lastTimeBucketsVisibility, "archive")
        XCTAssertEqual(mock.lastTimeBucketVisibility, "archive", "bucket load inherits the filter")
    }

    @MainActor
    func test_filter_unchanged_isNoOp() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        let calls = mock.requestCount

        await vm.setFilter(.all)

        XCTAssertEqual(mock.requestCount, calls, "identical filter does not reload")
        XCTAssertEqual(vm.items.count, 3)
    }

    @MainActor
    func test_filter_change_reloadsFreshFromServer() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        // Server now only returns a subset for the active filter.
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)]
        mock.bucketResponses = [
            "2024-07-01": columnar(
                ids: ["a4"], ratios: [1],
                thumbhashes: [nil], favorites: [true]
            )
        ]

        await vm.setFilter(.favorites)

        XCTAssertEqual(mock.lastTimeBucketsIsFavorite, true)
        XCTAssertEqual(vm.items.map(\.id), ["a4"], "no stale items leak across filter change")
        XCTAssertEqual(vm.loadedIds, Set(["a4"]))
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    @MainActor
    func test_filter_failureShowsError() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        mock.globalError = APIError.serverError(500, "boom")

        await vm.setFilter(.favorites)

        XCTAssertEqual(vm.loadErrorMessage, localizedString("The server ran into a problem. Please try again."))
    }

    @MainActor
    func test_filter_retryViaRefresh() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        mock.globalError = APIError.serverError(500, "boom")
        await vm.setFilter(.favorites)
        mock.globalError = nil

        await vm.refresh()

        XCTAssertEqual(mock.lastTimeBucketsIsFavorite, true, "refresh keeps the committed filter")
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "a3"])
    }

    // MARK: - Partner photos in « All » (partnerTimeline)

    /// Seeds a VM in « All » with one month holding `owners`' photos (ids `p1…`).
    @MainActor
    private func makePartnerVM(
        _ mock: MockImmichClient, owners: [String], favorites: [Bool]? = nil
    ) async -> TimelineViewModel {
        let ids = owners.indices.map { "p\($0 + 1)" }
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: ids.count)]
        mock.bucketResponses = [
            "2024-07-01": columnar(
                ids: ids, ratios: ids.map { _ in 1 }, thumbhashes: ids.map { _ in nil },
                favorites: favorites ?? ids.map { _ in false }, owners: owners
            )
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.load()
        return vm
    }

    private func assertPartnerParams(
        _ mock: MockImmichClient, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(mock.lastTimeBucketWithPartners, true, "bucket sends withPartners", file: file, line: line)
        XCTAssertEqual(mock.lastTimeBucketVisibility, "timeline", "bucket sends visibility=timeline", file: file, line: line)
    }

    @MainActor
    func test_partnerTimeline_AC1_initialAllRequestsPartnersAndTimelineVisibility() async {
        let mock = MockImmichClient()
        let vm = TimelineViewModel(client: mock)
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)]
        XCTAssertEqual(vm.filter, .all)

        await vm.load()

        XCTAssertEqual(mock.lastTimeBucketsWithPartners, true)
        XCTAssertEqual(mock.lastTimeBucketsVisibility, "timeline")
        XCTAssertNil(mock.lastTimeBucketsIsFavorite)
    }

    @MainActor
    func test_partnerTimeline_AC2_everyBucketLoadPathRepeatsPartnersAndTimeline() async {
        let mock = MockImmichClient()
        let months = ["2024-07-01", "2024-06-01", "2024-05-01"]
        mock.bucketsResponse = months.map { TimeBucketsResponseDto(timeBucket: $0, count: 1) }
        for (i, m) in months.enumerated() {
            mock.bucketResponses[m] = columnar(ids: ["m\(i)"], ratios: [1], thumbhashes: [nil], favorites: [false])
        }
        let vm = TimelineViewModel(client: mock)
        func reset() {
            mock.lastTimeBucketWithPartners = nil
            mock.lastTimeBucketVisibility = nil
        }

        reset()
        await vm.load()
        assertPartnerParams(mock)

        reset()
        await vm.loadMore()
        assertPartnerParams(mock)

        reset()
        await vm.jump(toDay: "2024-06-01")
        assertPartnerParams(mock)

        reset()
        await vm.loadNewer()
        assertPartnerParams(mock)
        XCTAssertEqual(vm.items.first?.id, "m0", "loadNewer really served the newer month")
    }

    @MainActor
    func test_partnerTimeline_AC3_returningToAllRestoresPartnersParams() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        await vm.setFilter(.favorites)
        XCTAssertNil(mock.lastTimeBucketsWithPartners, "favorites precondition")

        await vm.setFilter(.all)

        XCTAssertEqual(vm.filter, .all)
        XCTAssertEqual(mock.lastTimeBucketsWithPartners, true)
        XCTAssertEqual(mock.lastTimeBucketsVisibility, "timeline")
        XCTAssertNil(mock.lastTimeBucketsIsFavorite)
        assertPartnerParams(mock)
    }

    @MainActor
    func test_partnerTimeline_AC4_partnerPhotosStayInGridBesideMine() async {
        let mock = MockImmichClient()

        let vm = await makePartnerVM(mock, owners: ["me", "partner", "me"])

        XCTAssertEqual(vm.items.map(\.id), ["p1", "p2", "p3"], "server order kept, nothing filtered client-side")
        XCTAssertEqual(vm.items.map(\.ownerId), ["me", "partner", "me"])
    }

    @MainActor
    func test_partnerTimeline_AC5_refreshDropsPartnerPhotosNoLongerServed() async {
        let mock = MockImmichClient()
        let vm = await makePartnerVM(mock, owners: ["me", "partner", "me"])
        XCTAssertTrue(vm.items.contains { $0.ownerId == "partner" }, "precondition")
        mock.lastTimeBucketsWithPartners = nil
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)]
        mock.bucketResponses["2024-07-01"] = columnar(
            ids: ["p1", "p3"], ratios: [1, 1], thumbhashes: [nil, nil], favorites: [false, false],
            owners: ["me", "me"]
        )

        await vm.refresh()

        XCTAssertEqual(mock.lastTimeBucketsWithPartners, true)
        XCTAssertEqual(vm.items.map(\.id), ["p1", "p3"])
        XCTAssertFalse(vm.items.contains { $0.ownerId == "partner" })
    }

    @MainActor
    func test_partnerTimeline_AC6_favoritesOmitsWithPartners() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        XCTAssertEqual(mock.lastTimeBucketsWithPartners, true)
        XCTAssertEqual(mock.lastTimeBucketWithPartners, true)
        mock.bucketResponses["2024-07-01"] = columnar(ids: ["f1"], ratios: [1], thumbhashes: [nil], favorites: [true])
        let before = mock.requestCount

        await vm.setFilter(.favorites)

        XCTAssertEqual(mock.requestCount, before + 2, "one /buckets and one /bucket")
        XCTAssertEqual(vm.items.map(\.id), ["f1"], "/bucket was called again and served")
        XCTAssertNil(mock.lastTimeBucketsWithPartners)
        XCTAssertNil(mock.lastTimeBucketWithPartners)
        XCTAssertEqual(mock.lastTimeBucketsIsFavorite, true)
        XCTAssertNil(vm.loadErrorMessage)
    }

    @MainActor
    func test_partnerTimeline_AC7_archivedOmitsWithPartners() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        XCTAssertEqual(mock.lastTimeBucketsWithPartners, true)
        XCTAssertEqual(mock.lastTimeBucketWithPartners, true)
        let before = mock.requestCount

        await vm.setFilter(.archived)

        XCTAssertEqual(mock.requestCount, before + 2)
        XCTAssertEqual(mock.lastTimeBucketsVisibility, "archive")
        XCTAssertEqual(mock.lastTimeBucketVisibility, "archive")
        XCTAssertNil(mock.lastTimeBucketsWithPartners)
        XCTAssertNil(mock.lastTimeBucketWithPartners)
        XCTAssertNil(vm.loadErrorMessage)
    }

    func test_partnerTimeline_AC8_filterMenuOffersExactlyAllFavoritesArchived() {
        XCTAssertEqual(TimelineFilter.allCases, [.all, .favorites, .archived])
    }

    @MainActor
    func test_partnerTimeline_AC9_allAsksTimelineVisibilityArchivedAsksArchive() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        XCTAssertEqual(mock.lastTimeBucketsVisibility, "timeline")
        XCTAssertEqual(mock.lastTimeBucketVisibility, "timeline")
        XCTAssertFalse(vm.items.contains { $0.visibility == "archive" })
        mock.bucketResponses["2024-07-01"] = columnar(
            ids: ["ar1"], ratios: [1], thumbhashes: [nil], favorites: [false], visibilities: ["archive"]
        )

        await vm.setFilter(.archived)

        XCTAssertEqual(mock.lastTimeBucketsVisibility, "archive")
        XCTAssertEqual(mock.lastTimeBucketVisibility, "archive")
        XCTAssertEqual(vm.items.map(\.id), ["ar1"])
    }

    // MARK: - Owner-only batch actions (partner photos are skipped, not refused)

    /// Selects `ids` in a fresh selection mode.
    @MainActor
    private func select(_ vm: TimelineViewModel, _ ids: [String]) {
        vm.enterSelectionMode()
        for id in ids { vm.toggleSelection(id: id) }
    }

    /// p1, p2 mine; p3 a partner's — everything selected.
    @MainActor
    private func makeMixedVM(_ mock: MockImmichClient, favorites: [Bool]? = nil) async -> TimelineViewModel {
        let vm = await makePartnerVM(mock, owners: ["me", "me", "partner"], favorites: favorites)
        select(vm, ["p1", "p2", "p3"])
        return vm
    }

    @MainActor
    func test_ownerOnly_AC1_AC13_mixedDeleteSendsOwnedIdsOnly() async {
        let mock = MockImmichClient()
        let vm = await makeMixedVM(mock)

        await vm.deleteSelected(currentUserId: "me")

        XCTAssertEqual(Set(mock.lastDeleteBody?.ids ?? []), ["p1", "p2"])
        XCTAssertEqual(vm.items.map(\.id), ["p3"])
        XCTAssertEqual(vm.loadedIds, ["p3"])
        XCTAssertFalse(vm.selectionMode)
        XCTAssertNil(vm.skippedPartnerCount, "the confirmation already announced the partner photo")
        XCTAssertNil(vm.actionErrorMessage)
    }

    @MainActor
    func test_ownerOnly_AC2_AC13_mixedArchiveSendsOwnedIdsOnly() async {
        let mock = MockImmichClient()
        let vm = await makeMixedVM(mock)

        await vm.archiveSelected(currentUserId: "me")

        XCTAssertEqual(Set(mock.lastBulkUpdateDto?.ids ?? []), ["p1", "p2"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .archive)
        XCTAssertEqual(vm.items.map(\.id), ["p3"])
        XCTAssertEqual(vm.loadedIds, ["p3"])
        XCTAssertFalse(vm.selectionMode)
    }

    @MainActor
    func test_ownerOnly_AC16_AC13_mixedLockSendsOwnedIdsOnly() async {
        let mock = MockImmichClient()
        let vm = await makeMixedVM(mock)

        await vm.moveSelectedToLockedFolder(currentUserId: "me")

        XCTAssertEqual(Set(mock.lastBulkUpdateDto?.ids ?? []), ["p1", "p2"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .locked)
        XCTAssertEqual(vm.items.map(\.id), ["p3"])
        XCTAssertEqual(vm.loadedIds, ["p3"])
        XCTAssertFalse(vm.selectionMode)
    }

    @MainActor
    func test_ownerOnly_AC3_AC13_heartFavoritesOwnedIdsOnly() async {
        let mock = MockImmichClient()
        let vm = await makeMixedVM(mock)

        await vm.favoriteSelected(currentUserId: "me")

        XCTAssertEqual(Set(mock.updateAssetCalls.map(\.id)), ["p1", "p2"])
        XCTAssertTrue(mock.updateAssetCalls.allSatisfy { $0.dto.isFavorite == true })
        XCTAssertEqual(vm.items.map(\.isFavorite), [true, true, false])
        XCTAssertFalse(vm.selectionMode)
    }

    /// The target comes from the owned photos only: the partner's non-favorite
    /// must not turn "all my photos are favorites" into "favorite everything".
    @MainActor
    func test_ownerOnly_AC14_heartUnfavoritesWhenOwnedAllFavorite() async {
        let mock = MockImmichClient()
        let vm = await makeMixedVM(mock, favorites: [true, true, false])

        await vm.favoriteSelected(currentUserId: "me")

        XCTAssertEqual(Set(mock.updateAssetCalls.map(\.id)), ["p1", "p2"])
        XCTAssertTrue(mock.updateAssetCalls.allSatisfy { $0.dto.isFavorite == false })
        XCTAssertEqual(vm.items.map(\.isFavorite), [false, false, false])
        XCTAssertFalse(vm.selectionMode)
    }

    @MainActor
    func test_ownerOnly_AC4_stackSendsOwnedIdsInGridOrder() async {
        let mock = MockImmichClient()
        let vm = await makePartnerVM(mock, owners: ["me", "partner", "me"])
        select(vm, ["p3", "p2", "p1"])

        await vm.stackSelected(currentUserId: "me")

        XCTAssertEqual(mock.lastCreateStackIds, ["p1", "p3"], "grid order, partner photo left out")
        XCTAssertFalse(vm.selectionMode)
        XCTAssertEqual(vm.skippedPartnerCount, 1)
    }

    @MainActor
    func test_ownerOnly_AC5_stackWithOneOwnedSendsNothingAndReportsSkipped() async {
        let mock = MockImmichClient()
        let vm = await makePartnerVM(mock, owners: ["me", "partner"])
        select(vm, ["p1", "p2"])

        await vm.stackSelected(currentUserId: "me")

        XCTAssertNil(mock.lastCreateStackIds)
        XCTAssertEqual(vm.skippedPartnerCount, 1)
        XCTAssertTrue(vm.selectionMode)
        XCTAssertEqual(vm.selectedIds, ["p1", "p2"])
    }

    /// Four actions publish the notice on success; delete announced it in its confirmation.
    @MainActor
    func test_ownerOnly_AC6_partialSuccessReportsSkippedNotError() async {
        let actions: [(String, (TimelineViewModel) async -> Void)] = [
            ("archive", { await $0.archiveSelected(currentUserId: "me") }),
            ("lock", { await $0.moveSelectedToLockedFolder(currentUserId: "me") }),
            ("heart", { await $0.favoriteSelected(currentUserId: "me") }),
            ("stack", { await $0.stackSelected(currentUserId: "me") }),
        ]
        for (name, act) in actions {
            let vm = await makeMixedVM(MockImmichClient())
            await act(vm)
            XCTAssertEqual(vm.skippedPartnerCount, 1, name)
            XCTAssertNil(vm.actionErrorMessage, name)
        }

        let vm = await makeMixedVM(MockImmichClient())
        await vm.deleteSelected(currentUserId: "me")
        XCTAssertNil(vm.skippedPartnerCount)
        XCTAssertNil(vm.actionErrorMessage)
    }

    @MainActor
    func test_ownerOnly_AC7_partnerOnlySelectionSendsNothing() async {
        let actions: [(String, (TimelineViewModel) async -> Void)] = [
            ("delete", { await $0.deleteSelected(currentUserId: "me") }),
            ("archive", { await $0.archiveSelected(currentUserId: "me") }),
            ("lock", { await $0.moveSelectedToLockedFolder(currentUserId: "me") }),
            ("heart", { await $0.favoriteSelected(currentUserId: "me") }),
        ]
        for (name, act) in actions {
            let mock = MockImmichClient()
            let vm = await makePartnerVM(mock, owners: ["partner", "partner", "partner"])
            select(vm, ["p1", "p2", "p3"])
            let before = mock.requestCount

            await act(vm)

            XCTAssertEqual(mock.requestCount, before, "\(name) sent a request")
            XCTAssertEqual(vm.skippedPartnerCount, 3, name)
            XCTAssertTrue(vm.selectionMode, name)
            XCTAssertEqual(vm.selectedIds, ["p1", "p2", "p3"], name)
            XCTAssertEqual(vm.items.count, 3, name)
        }
    }

    @MainActor
    func test_ownerOnly_AC8_ownedOnlySelectionUnchanged() async {
        let mock = MockImmichClient()
        let vm = await makePartnerVM(mock, owners: ["me", "me"])

        select(vm, ["p1", "p2"])
        await vm.archiveSelected(currentUserId: "me")
        XCTAssertEqual(Set(mock.lastBulkUpdateDto?.ids ?? []), ["p1", "p2"])
        XCTAssertNil(vm.skippedPartnerCount)
        XCTAssertTrue(vm.items.isEmpty)

        let vm2 = await makePartnerVM(mock, owners: ["me", "me"])
        select(vm2, ["p1", "p2"])
        await vm2.deleteSelected(currentUserId: "me")
        XCTAssertEqual(Set(mock.lastDeleteBody?.ids ?? []), ["p1", "p2"])
        XCTAssertNil(vm2.skippedPartnerCount)

        let vm3 = await makePartnerVM(mock, owners: ["me", "me"])
        select(vm3, ["p1", "p2"])
        await vm3.stackSelected(currentUserId: "me")
        XCTAssertEqual(mock.lastCreateStackIds, ["p1", "p2"])
        XCTAssertNil(vm3.skippedPartnerCount)
    }

    @MainActor
    func test_ownerOnly_AC9_unknownOwnerIsSent() async {
        let mock = MockImmichClient()
        let vm = await makePartnerVM(mock, owners: ["", "partner"])
        select(vm, ["p1", "p2"])
        await vm.archiveSelected(currentUserId: "me")
        XCTAssertEqual(mock.lastBulkUpdateDto?.ids, ["p1"], "empty ownerId is sent")
        XCTAssertEqual(vm.skippedPartnerCount, 1)

        let vm2 = await makePartnerVM(mock, owners: ["me", "partner"])
        select(vm2, ["p1", "p2"])
        await vm2.archiveSelected(currentUserId: nil)
        XCTAssertEqual(Set(mock.lastBulkUpdateDto?.ids ?? []), ["p1", "p2"], "no session user id: everything is sent")
        XCTAssertNil(vm2.skippedPartnerCount)
    }

    @MainActor
    func test_ownerOnly_AC15_ownedRefusalKeepsStateAndNoSkippedNotice() async {
        let refusal = APIError.serverError(400, "Not found or no asset.update access")
        let actions: [(String, (MockImmichClient) -> Void, (TimelineViewModel) async -> Void)] = [
            ("delete", { $0.deleteError = refusal }, { await $0.deleteSelected(currentUserId: "me") }),
            ("archive", { $0.globalError = refusal }, { await $0.archiveSelected(currentUserId: "me") }),
            ("lock", { $0.globalError = refusal }, { await $0.moveSelectedToLockedFolder(currentUserId: "me") }),
            ("heart", { $0.updateAssetErrorsById["p1"] = refusal }, { await $0.favoriteSelected(currentUserId: "me") }),
            ("stack", { $0.globalError = refusal }, { await $0.stackSelected(currentUserId: "me") }),
        ]
        for (name, fail, act) in actions {
            let mock = MockImmichClient()
            let vm = await makeMixedVM(mock)
            fail(mock)

            await act(vm)

            XCTAssertNotNil(vm.actionErrorMessage, name)
            XCTAssertNil(vm.skippedPartnerCount, name)
            XCTAssertEqual(vm.items.map(\.id), ["p1", "p2", "p3"], name)
            XCTAssertEqual(vm.loadedIds, ["p1", "p2", "p3"], name)
            XCTAssertTrue(vm.selectionMode, name)
            XCTAssertEqual(vm.selectedIds, ["p1", "p2", "p3"], name)
        }
    }

    @MainActor
    func test_ownerOnly_AC17_deleteConfirmationCountsOwnedIds() async {
        let mock = MockImmichClient()
        let vm = await makeMixedVM(mock)
        let mixed = vm.ownerScopedSelection(currentUserId: "me")
        XCTAssertEqual(Set(mixed.ids), ["p1", "p2"])
        XCTAssertEqual(mixed.skipped, 1)

        let owned = await makePartnerVM(mock, owners: ["me", "me"])
        select(owned, ["p1", "p2"])
        XCTAssertEqual(owned.ownerScopedSelection(currentUserId: "me").skipped, 0)

        let partnerOnly = await makePartnerVM(mock, owners: ["partner", "partner", "partner"])
        select(partnerOnly, ["p1", "p2", "p3"])
        let none = partnerOnly.ownerScopedSelection(currentUserId: "me")
        XCTAssertTrue(none.ids.isEmpty)
        XCTAssertEqual(none.skipped, 3)

        let unknown = vm.ownerScopedSelection(currentUserId: nil)
        XCTAssertEqual(Set(unknown.ids), ["p1", "p2", "p3"])
        XCTAssertEqual(unknown.skipped, 0)
    }

    /// `batchSetFavorite` stops at the first refusal; the hearts match what the server took.
    @MainActor
    func test_partnerTimeline_batchFavoriteRefusedMatchesServerState() async {
        let mock = MockImmichClient()
        let vm = await makePartnerVM(mock, owners: ["me", "partner", "me"])
        vm.enterSelectionMode()
        for id in ["p1", "p2", "p3"] { vm.toggleSelection(id: id) }
        mock.updateAssetErrorsById["p2"] = APIError.serverError(400, "Not found or no asset.update access")

        let ok = await vm.batchSetFavorite(vm.selectedIds, favorite: true)

        XCTAssertFalse(ok)
        XCTAssertNotNil(vm.actionErrorMessage)
        XCTAssertEqual(vm.selectedIds, ["p1", "p2", "p3"])
        XCTAssertEqual(vm.items.first { $0.id == "p2" }?.isFavorite, false, "refused photo keeps its heart")
        let accepted = Set(mock.updateAssetCalls.map(\.id))
        XCTAssertFalse(accepted.contains("p2"))
        for item in vm.items {
            XCTAssertEqual(item.isFavorite, accepted.contains(item.id), "heart of \(item.id) matches what the server accepted")
        }
    }

    func test_partnerTimeline_AC11_tapRouteOpensViewerForPartnerStacks() {
        func item(owner: String, stack: [String]) -> AssetReactItem {
            AssetReactItem(
                id: "x", ownerId: owner, ratio: 1, isFavorite: false, visibility: "timeline",
                isTrashed: false, isImage: true, thumbhash: nil,
                createdAt: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z",
                localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, projectionType: nil,
                city: nil, country: nil, latitude: nil, longitude: nil, stack: stack
            )
        }
        let route = TimelineViewModel.tapRoute(for:currentUserId:)

        XCTAssertEqual(route(item(owner: "partner", stack: []), "me"), .viewer)
        XCTAssertEqual(route(item(owner: "partner", stack: ["stk-p", "3"]), "me"), .viewer)
        XCTAssertEqual(route(item(owner: "me", stack: ["stk-m", "2"]), "me"), .stack(id: "stk-m"))
        XCTAssertEqual(route(item(owner: "partner", stack: ["stk-p", "3"]), nil), .stack(id: "stk-p"))
        XCTAssertEqual(route(item(owner: "partner", stack: ["stk-p", "3"]), ""), .stack(id: "stk-p"))
        XCTAssertEqual(route(item(owner: "", stack: ["stk-o", "3"]), "me"), .stack(id: "stk-o"))
    }

    // MARK: - Stacks (gap #1)

    /// `withStacked` is not a cosmetic flag: the server drops every non-primary
    /// member from the bucket, so the timeline must ask for it on both calls
    /// (bucket list + bucket page) or stacks would never collapse.
    @MainActor
    func test_stacks_timelineRequestsStackedPrimaries() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["a1"], ratios: [1.0], thumbhashes: [nil], favorites: [false])
        ]
        let vm = TimelineViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(mock.lastTimeBucketsWithStacked, true)
        XCTAssertEqual(mock.lastTimeBucketWithStacked, true)
    }

    /// The bucket carries `[stackId, assetCount]` per row — the count is a
    /// *string* and it includes the cover. The badge shows the rest.
    @MainActor
    func test_stacks_bucketTupleMapsToStackIdAndCount() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)]
        mock.bucketResponses = [
            "2024-07-01": TimeBucketAssetResponseDto(
                id: ["cover", "solo"],
                ownerId: ["owner", "owner"],
                ratio: [1.0, 1.0],
                isFavorite: [false, false],
                visibility: ["timeline", "timeline"],
                isTrashed: [false, false],
                isImage: [true, true],
                thumbhash: [nil, nil],
                createdAt: ["2024-07-01T00:00:00.000Z", "2024-07-01T00:00:00.000Z"],
                fileCreatedAt: ["2024-07-01T00:00:00.000Z", "2024-07-01T00:00:00.000Z"],
                localOffsetHours: [0.0, 0.0],
                duration: [nil, nil],
                livePhotoVideoId: [nil, nil],
                projectionType: [nil, nil],
                stack: [["stk-1", "3"], nil],
                city: nil, country: nil, latitude: nil, longitude: nil
            )
        ]
        let vm = TimelineViewModel(client: mock)

        await vm.load()

        let cover = vm.items.first { $0.id == "cover" }
        XCTAssertEqual(cover?.stackId, "stk-1")
        XCTAssertEqual(cover?.stackCount, 3)
        XCTAssertEqual(cover?.stackedExtraCount, 2, "the badge counts what's behind the cover")
        XCTAssertEqual(cover?.isStacked, true)

        let solo = vm.items.first { $0.id == "solo" }
        XCTAssertNil(solo?.stackId)
        XCTAssertNil(solo?.stackCount)
        XCTAssertEqual(solo?.isStacked, false)
    }

    /// The server makes the first id the cover, and `selectedIds` is a Set —
    /// without grid ordering the cover would be arbitrary.
    @MainActor
    func test_stacks_stackSelectedFollowsGridOrder() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 3)]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["a1", "a2", "a3"], ratios: [1, 1, 1], thumbhashes: [nil, nil, nil], favorites: [false, false, false])
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.load()
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a3")
        vm.toggleSelection(id: "a2")

        await vm.stackSelected(currentUserId: nil)

        XCTAssertEqual(mock.lastCreateStackIds, ["a2", "a3"], "grid order, not Set order")
        XCTAssertFalse(vm.selectionMode)
    }

    // MARK: - AC-10 / AC-1 / AC-2: a cancelled load is silent and keeps what is shown (SP-1, SP-7)

    /// Refreshed VM holding one non-empty bucket: the starting point of every cancelled-load test.
    @MainActor
    private func makeRefreshedVM(_ mock: MockImmichClient) async -> TimelineViewModel {
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["a1", "a2"], ratios: [1.0, 1.0], thumbhashes: [nil, nil], favorites: [false, false])
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.refresh()
        return vm
    }

    @MainActor
    func test_AC10_cancelledLoadIsSilentAndKeepsShownPhotos() async {
        let mock = MockImmichClient()
        let vm = await makeRefreshedVM(mock)
        let shownIds = vm.items.map(\.id)
        XCTAssertFalse(shownIds.isEmpty, "precondition: a non-empty bucket is on screen")

        mock.globalError = URLError(.cancelled)
        await vm.refresh()

        XCTAssertNil(vm.loadErrorMessage, "a cancelled refresh writes no banner")
        XCTAssertNil(vm.actionErrorMessage, "a cancelled refresh never raises the modal")
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.items.map(\.id), shownIds, "photos already shown stay")
    }

    @MainActor
    func test_AC2_cancelledLoadNewerIsSilent() async {
        let mock = MockImmichClient()
        let vm = await makeRefreshedVM(mock)
        vm.upperBucketIndex = 0
        let shownIds = vm.items.map(\.id)

        mock.globalError = URLError(.cancelled)
        await vm.loadNewer()

        XCTAssertNil(vm.loadErrorMessage, "a cancelled loadNewer writes no banner")
        XCTAssertNil(vm.actionErrorMessage)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.items.map(\.id), shownIds, "photos already shown stay")
    }

    @MainActor
    func test_AC1_scrollToTopCancellationKeepsPhotosAndNoBanner() async {
        let mock = MockImmichClient()
        let vm = await makeRefreshedVM(mock)
        let shownIds = vm.items.map(\.id)

        mock.globalError = URLError(.cancelled)
        await vm.jump(toDay: "2024-07-01")

        XCTAssertNil(vm.loadErrorMessage, "a cancelled jump writes no banner")
        XCTAssertNil(vm.actionErrorMessage)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.items.map(\.id), shownIds, "photos already shown stay")
    }

    // MARK: - Favorites filter: /bucket repeats the /buckets filters

    private struct FavBoomError: Error {}

    /// Two months of favorites, so loadMore / jump / loadNewer have somewhere to go.
    @MainActor
    private func favoritesMock() -> MockImmichClient {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-06-01", count: 1)
        ]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["a1", "a2"], ratios: [1, 1], thumbhashes: [nil, nil], favorites: [true, true]),
            "2024-06-01": columnar(ids: ["a3"], ratios: [1], thumbhashes: [nil], favorites: [true])
        ]
        return mock
    }

    @MainActor
    func test_AC1_favoritesFilter_firstBucketRepeatsBucketsFilters() async {
        let mock = favoritesMock()
        let vm = TimelineViewModel(client: mock)
        await vm.setFilter(.favorites)

        XCTAssertEqual(mock.timeBucketCalls.count, 1)
        let sent = mock.timeBucketCalls[0].filters
        XCTAssertEqual(sent.isFavorite, true)
        XCTAssertEqual(sent, mock.lastTimeBucketsFilters, "same filters on /bucket as on /buckets")
    }

    @MainActor
    func test_AC2_favoritesFilter_loadMoreRepeatsBucketsFilters() async {
        let mock = favoritesMock()
        let vm = TimelineViewModel(client: mock)
        await vm.setFilter(.favorites)
        await vm.loadMore()

        XCTAssertEqual(mock.timeBucketCalls.last?.timeBucket, "2024-06-01")
        XCTAssertEqual(mock.timeBucketCalls.last?.filters.isFavorite, true)
        XCTAssertEqual(mock.timeBucketCalls.last?.filters, mock.lastTimeBucketsFilters)
    }

    @MainActor
    func test_AC3_favoritesFilter_jumpAndLoadNewerRepeatBucketsFilters() async {
        let mock = favoritesMock()
        let vm = TimelineViewModel(client: mock)
        await vm.setFilter(.favorites)
        await vm.jump(toDay: "2024-06-01")
        await vm.loadNewer()

        let lastTwo = Array(mock.timeBucketCalls.suffix(2))
        XCTAssertEqual(lastTwo.map(\.timeBucket), ["2024-06-01", "2024-07-01"])
        for call in lastTwo {
            XCTAssertEqual(call.filters.isFavorite, true)
            XCTAssertEqual(call.filters, mock.lastTimeBucketsFilters)
        }
    }

    @MainActor
    func test_AC4_noFilter_bucketSendsNoNewFilter() async {
        let mock = MockImmichClient()
        _ = await makeLoadedVM(mock)

        XCTAssertNil(mock.lastTimeBucketIsFavorite)
        XCTAssertNil(mock.lastTimeBucketIsTrashed)
        XCTAssertNil(mock.lastTimeBucketOrderBy)
    }

    @MainActor
    func test_AC17_mockCapturesTimeBucketFilters() async throws {
        let mock = MockImmichClient()
        _ = try await mock.getTimeBucket(
            timeBucket: "x", isFavorite: true, isTrashed: false, personId: nil,
            withPartners: nil, visibility: nil, withStacked: nil, orderBy: .createdAt
        )

        XCTAssertEqual(mock.lastTimeBucketIsFavorite, true)
        XCTAssertEqual(mock.lastTimeBucketIsTrashed, false)
        XCTAssertEqual(mock.lastTimeBucketOrderBy, .createdAt)
        XCTAssertEqual(mock.timeBucketCalls.count, 1)
    }

    /// Every path that loads a month (first load, scroll down, jump, scroll
    /// back up) must send what `/buckets` sent: this fails the moment one of
    /// them lists a filter on its own and forgets one.
    @MainActor
    func test_AC18_favoritesFilter_everyBucketCallMatchesBucketsFilters() async {
        let mock = favoritesMock()
        let vm = TimelineViewModel(client: mock)
        await vm.setFilter(.favorites)
        await vm.loadMore()
        await vm.jump(toDay: "2024-06-01")
        await vm.loadNewer()

        XCTAssertGreaterThanOrEqual(mock.timeBucketCalls.count, 4)
        let expected = mock.lastTimeBucketsFilters
        XCTAssertNotNil(expected)
        for call in mock.timeBucketCalls {
            XCTAssertEqual(call.filters, expected, "\(call.timeBucket) differs from /buckets")
        }
    }

    // MARK: - Favorites filter: an un-favorited asset leaves the grid

    @MainActor
    private func favoritesGridVM(_ mock: MockImmichClient) async -> TimelineViewModel {
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["a1", "a2"], ratios: [1, 1], thumbhashes: [nil, nil], favorites: [true, true])
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.setFilter(.favorites)
        return vm
    }

    @MainActor
    func test_AC12_favoritesFilter_toggleOffRemovesFromGrid() async {
        let vm = await favoritesGridVM(MockImmichClient())

        await vm.toggleFavorite(id: "a1")

        XCTAssertEqual(vm.items.map(\.id), ["a2"])
        XCTAssertFalse(vm.loadedIds.contains("a1"))
    }

    @MainActor
    func test_AC13_favoritesFilter_batchUnfavoriteRemovesAll() async {
        let vm = await favoritesGridVM(MockImmichClient())
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")

        let ok = await vm.batchSetFavorite(vm.selectedIds, favorite: false)

        XCTAssertTrue(ok)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertTrue(vm.loadedIds.isEmpty)
    }

    @MainActor
    func test_AC14_favoritesFilter_setFavoriteFalseRemovesFromGrid() async {
        let vm = await favoritesGridVM(MockImmichClient())

        let ok = await vm.setFavorite(id: "a1", isFavorite: false)

        XCTAssertTrue(ok)
        XCTAssertEqual(vm.items.map(\.id), ["a2"])
        XCTAssertFalse(vm.loadedIds.contains("a1"))
    }

    @MainActor
    func test_AC15_favoritesFilter_failedUnfavoriteKeepsAsset() async {
        let mock = MockImmichClient()
        let vm = await favoritesGridVM(mock)
        mock.globalError = FavBoomError()

        await vm.toggleFavorite(id: "a1")

        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2"])
        XCTAssertEqual(vm.items.first { $0.id == "a1" }?.isFavorite, true, "heart stays lit")
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    @MainActor
    func test_AC16_noFilter_unfavoriteKeepsAssetPatched() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["a1"], ratios: [1], thumbhashes: [nil], favorites: [true])
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.load()

        await vm.setFavorite(id: "a1", isFavorite: false)

        XCTAssertEqual(vm.items.map(\.id), ["a1"])
        XCTAssertEqual(vm.items.first?.isFavorite, false)
    }

    @MainActor
    func test_AC19_favoritesFilter_partialBatchFailureRemovesOnlyWrittenIds() async {
        let mock = MockImmichClient()
        let vm = await favoritesGridVM(mock)
        mock.updateAssetError = FavBoomError()
        mock.updateAssetErrorAfterSuccesses = 1
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")

        let ok = await vm.batchSetFavorite(vm.selectedIds, favorite: false)

        XCTAssertFalse(ok)
        XCTAssertNotNil(vm.actionErrorMessage)
        let written = mock.updateAssetCalls.first!.id
        let failed = written == "a1" ? "a2" : "a1"
        XCTAssertEqual(mock.updateAssetCalls.count, 1)
        XCTAssertFalse(vm.items.contains { $0.id == written })
        XCTAssertFalse(vm.loadedIds.contains(written))
        XCTAssertFalse(vm.selectedIds.contains(written))
        XCTAssertEqual(vm.items.first { $0.id == failed }?.isFavorite, true)
        XCTAssertTrue(vm.loadedIds.contains(failed))
        XCTAssertEqual(vm.selectedIds, [failed])
        XCTAssertTrue(vm.selectionMode)
    }

    @MainActor
    func test_AC20_favoritesFilter_refavoriteOfRemovedAssetIsWritten() async {
        let mock = MockImmichClient()
        let vm = await favoritesGridVM(mock)
        await vm.setFavorite(id: "a1", isFavorite: false)

        let ok = await vm.setFavorite(id: "a1", isFavorite: true)

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.updateAssetCalls.last?.id, "a1")
        XCTAssertEqual(mock.updateAssetCalls.last?.dto.isFavorite, true)
        XCTAssertFalse(vm.items.contains { $0.id == "a1" }, "not re-inserted before the next refresh")

        mock.updateAssetError = FavBoomError()
        let failed = await vm.setFavorite(id: "a1", isFavorite: true)
        XCTAssertFalse(failed)
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    // MARK: - Unarchive

    /// Items a1…a3, all archived, under the Archived filter.
    @MainActor
    private func archivedGridVM(_ mock: MockImmichClient) async -> TimelineViewModel {
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 3)]
        mock.bucketResponses = [
            "2024-07-01": columnar(
                ids: ["a1", "a2", "a3"], ratios: [1, 1, 1], thumbhashes: [nil, nil, nil],
                favorites: [false, false, false], visibilities: ["archive", "archive", "archive"]
            )
        ]
        let vm = TimelineViewModel(client: mock)
        await vm.setFilter(.archived)
        return vm
    }

    /// Favorites filter listing a1, a2 (archived) and a3 (not archived).
    @MainActor
    private func favoritesMixedVM(_ mock: MockImmichClient, client: (any ImmichClient)? = nil) async -> TimelineViewModel {
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 3)]
        mock.bucketResponses = [
            "2024-07-01": columnar(
                ids: ["a1", "a2", "a3"], ratios: [1, 1, 1], thumbhashes: [nil, nil, nil],
                favorites: [true, true, true], visibilities: ["archive", "archive", "timeline"]
            )
        ]
        let vm = TimelineViewModel(client: client ?? mock)
        await vm.setFilter(.favorites)
        return vm
    }

    /// The items the grid renders (from the memoized sections), by id.
    @MainActor
    private func renderedItems(_ vm: TimelineViewModel) -> [String: AssetReactItem] {
        var byId: [String: AssetReactItem] = [:]
        for section in vm.timelineSections(groupBy: .day) {
            if case .dayGroup(_, let items) = section {
                for item in items { byId[item.id] = item }
            }
        }
        return byId
    }

    @MainActor
    func test_unarchive_AC1_archivedFilterOffersUnarchive() async {
        let vm = await archivedGridVM(MockImmichClient())

        XCTAssertFalse(vm.items.isEmpty)
        for item in vm.items { XCTAssertTrue(vm.offersUnarchive(for: item)) }
        // Under Archived the filter alone decides, whatever the item says.
        XCTAssertTrue(vm.offersUnarchive(for: vm.items[0].with(visibility: "timeline")))
    }

    @MainActor
    func test_unarchive_AC2_allFilterTimelineAssetOffersArchive() async {
        let vm = await makeLoadedVM(MockImmichClient())
        let item = vm.items[0]

        XCTAssertEqual(vm.filter, .all)
        XCTAssertFalse(vm.offersUnarchive(for: item))

        let copy = item.with(visibility: "archive")
        XCTAssertEqual(copy.visibility, "archive")
        XCTAssertEqual(copy.with(visibility: item.visibility), item, "only the visibility differs")
        XCTAssertEqual(copy.id, item.id)
        XCTAssertEqual(copy.isFavorite, item.isFavorite)
        XCTAssertEqual(copy.ownerId, item.ownerId)
        XCTAssertEqual(copy.ratio, item.ratio)
        XCTAssertEqual(copy.stack, item.stack)
        XCTAssertTrue(vm.offersUnarchive(for: copy), "an archived item offers Unarchive under All too")
    }

    @MainActor
    func test_unarchive_AC3_favoritesFilterArchivedAssetOffersUnarchive() async {
        let vm = await favoritesMixedVM(MockImmichClient())
        let byId = Dictionary(uniqueKeysWithValues: vm.items.map { ($0.id, $0) })

        XCTAssertTrue(vm.offersUnarchive(for: byId["a1"]!))
        XCTAssertFalse(vm.offersUnarchive(for: byId["a3"]!))
    }

    @MainActor
    func test_unarchive_AC4_singleUnderArchivedSendsTimelineAndRemoves() async {
        let mock = MockImmichClient()
        let vm = await archivedGridVM(mock)

        let ok = await vm.unarchive(id: "a2")

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastBulkUpdateDto?.ids, ["a2"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .timeline)
        XCTAssertFalse(vm.items.contains { $0.id == "a2" })
        XCTAssertFalse(vm.loadedIds.contains("a2"))
        XCTAssertEqual(vm.items.count, 2)
    }

    @MainActor
    func test_unarchive_AC5_archivedFilterSelectionOffersUnarchive() async {
        let vm = await archivedGridVM(MockImmichClient())
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")

        XCTAssertTrue(vm.selectionOffersUnarchive)
    }

    @MainActor
    func test_unarchive_AC6_selectedUnderArchivedSingleRequestRemovesAndExits() async {
        let mock = MockImmichClient()
        let vm = await archivedGridVM(mock)
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")
        let before = mock.requestCount

        await vm.unarchiveSelected()

        XCTAssertEqual(mock.requestCount, before + 1)
        XCTAssertEqual(Set(mock.lastBulkUpdateDto?.ids ?? []), ["a1", "a2"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .timeline)
        XCTAssertEqual(vm.items.map(\.id), ["a3"])
        XCTAssertEqual(vm.loadedIds, ["a3"])
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    @MainActor
    func test_unarchive_AC6_emptySelectionIsNoOp() async {
        let mock = MockImmichClient()
        let vm = await archivedGridVM(mock)
        vm.enterSelectionMode()
        let before = mock.requestCount

        await vm.unarchiveSelected()

        XCTAssertEqual(mock.requestCount, before)
        XCTAssertNil(mock.lastBulkUpdateDto)
        XCTAssertEqual(vm.items.count, 3)
    }

    @MainActor
    func test_unarchive_AC7_favoritesMixedSelectionOffersArchive() async {
        let vm = await favoritesMixedVM(MockImmichClient())
        vm.enterSelectionMode()
        XCTAssertFalse(vm.selectionOffersUnarchive, "empty selection → Archive")

        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a3")
        XCTAssertFalse(vm.selectionOffersUnarchive, "mixed selection → Archive")

        vm.toggleSelection(id: "a3")
        vm.toggleSelection(id: "a2")
        XCTAssertEqual(vm.selectedIds, ["a1", "a2"])
        XCTAssertTrue(vm.selectionOffersUnarchive, "only archived photos → Unarchive")
    }

    @MainActor
    func test_unarchive_AC7_selectedIdAbsentFromGridCountsAsNotArchived() async {
        let vm = await favoritesMixedVM(MockImmichClient())
        vm.enterSelectionMode()
        vm.toggleSelection(id: "ghost")

        XCTAssertFalse(vm.selectionOffersUnarchive)
    }

    @MainActor
    func test_unarchive_AC10_idOutsideGridStillSent() async {
        let mock = MockImmichClient()
        let vm = TimelineViewModel(client: mock)

        let ok = await vm.unarchive(id: "A")

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastBulkUpdateDto?.ids, ["A"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .timeline)
        XCTAssertTrue(vm.items.isEmpty)
    }

    @MainActor
    func test_setArchived_AC10_standaloneDispatchesTargetVisibility() async {
        let mock = MockImmichClient()
        let vm = TimelineViewModel(client: mock)

        let first = await vm.setArchived(id: "A", archived: false, handOffError: false)
        XCTAssertNil(first)
        XCTAssertEqual(mock.lastBulkUpdateDto?.ids, ["A"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .timeline)

        let second = await vm.setArchived(id: "B", archived: true, handOffError: false)
        XCTAssertNil(second)
        XCTAssertEqual(mock.lastBulkUpdateDto?.ids, ["B"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .archive)
    }

    @MainActor
    func test_unarchive_AC13_favoritesKeepsAssetPatchedAndSectionsRefreshed() async {
        let mock = MockImmichClient()
        let vm = await favoritesMixedVM(mock)
        let idsBefore = vm.items.map(\.id)
        XCTAssertEqual(renderedItems(vm)["a1"]?.visibility, "archive", "primes the section cache")

        let ok = await vm.unarchive(id: "a1")

        XCTAssertTrue(ok)
        XCTAssertEqual(vm.items.map(\.id), idsBefore, "same rows, same positions")
        let patched = vm.items.first { $0.id == "a1" }
        XCTAssertEqual(patched?.visibility, "timeline")
        XCTAssertFalse(vm.offersUnarchive(for: patched!))
        XCTAssertEqual(renderedItems(vm)["a1"]?.visibility, "timeline", "the grid reads fresh copies")
        XCTAssertEqual(renderedItems(vm)["a2"]?.visibility, "archive", "other rows untouched")
        XCTAssertTrue(vm.loadedIds.contains("a1"))
    }

    @MainActor
    func test_unarchive_AC14_refusedOrReadOnlyKeepsAsset() async {
        let mock = MockImmichClient()
        let vm = await archivedGridVM(mock)
        let itemsBefore = vm.items
        let loadedBefore = vm.loadedIds
        mock.globalError = APIError.serverError(500, "boom")

        let ok = await vm.unarchive(id: "a1")

        XCTAssertFalse(ok)
        XCTAssertEqual(vm.actionErrorMessage, localizedString("The server ran into a problem. Please try again."))
        XCTAssertEqual(vm.items, itemsBefore)
        XCTAssertEqual(vm.loadedIds, loadedBefore)

        // Read-only mode: the guard refuses before anything reaches the mock.
        let roMock = MockImmichClient()
        let roVM = await favoritesMixedVM(roMock, client: ReadOnlyGuardClient(inner: roMock, isEnabled: { true }))
        let roItems = roVM.items
        let roOk = await roVM.unarchive(id: "a1")

        XCTAssertFalse(roOk)
        XCTAssertEqual(roVM.actionErrorMessage, UserFacingError.readOnlyModeMessage)
        XCTAssertNil(roMock.lastBulkUpdateDto)
        XCTAssertEqual(roVM.items, roItems)
    }

    @MainActor
    func test_unarchive_AC15_refusedSelectionKeepsItemsAndSelection() async {
        let mock = MockImmichClient()
        let vm = await archivedGridVM(mock)
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")
        let itemsBefore = vm.items
        let loadedBefore = vm.loadedIds
        mock.globalError = APIError.serverError(500, "boom")

        await vm.unarchiveSelected()

        XCTAssertNotNil(vm.actionErrorMessage)
        XCTAssertEqual(vm.items, itemsBefore)
        XCTAssertEqual(vm.loadedIds, loadedBefore)
        XCTAssertEqual(vm.selectedIds, ["a1", "a2"])
        XCTAssertTrue(vm.selectionMode)
    }

    @MainActor
    func test_setArchived_AC16_refusalHandedOffToViewer() async {
        let mock = MockImmichClient()
        let vm = await archivedGridVM(mock)
        let itemsBefore = vm.items
        let loadedBefore = vm.loadedIds
        mock.globalError = APIError.serverError(500, "boom")

        let message = await vm.setArchived(id: "a1", archived: false, handOffError: true)

        XCTAssertEqual(message, localizedString("The server ran into a problem. Please try again."))
        XCTAssertNil(vm.actionErrorMessage, "the grid no longer presents it")
        XCTAssertEqual(vm.items, itemsBefore)
        XCTAssertEqual(vm.loadedIds, loadedBefore)

        // Read-only variant.
        let roMock = MockImmichClient()
        let roVM = TimelineViewModel(client: ReadOnlyGuardClient(inner: roMock, isEnabled: { true }))
        let roMessage = await roVM.setArchived(id: "a1", archived: false, handOffError: true)
        XCTAssertEqual(roMessage, UserFacingError.readOnlyModeMessage)
        XCTAssertNil(roVM.actionErrorMessage)
    }

    @MainActor
    func test_unarchive_AC17_favoritesSelectionStaysPatchedAndExits() async {
        let mock = MockImmichClient()
        let vm = await favoritesMixedVM(mock)
        let idsBefore = vm.items.map(\.id)
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")
        XCTAssertEqual(renderedItems(vm)["a1"]?.visibility, "archive", "primes the section cache")
        let before = mock.requestCount

        await vm.unarchiveSelected()

        XCTAssertEqual(mock.requestCount, before + 1)
        XCTAssertEqual(Set(mock.lastBulkUpdateDto?.ids ?? []), ["a1", "a2"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .timeline)
        XCTAssertEqual(vm.items.map(\.id), idsBefore)
        for id in ["a1", "a2"] {
            let item = vm.items.first { $0.id == id }
            XCTAssertEqual(item?.visibility, "timeline")
            XCTAssertFalse(vm.offersUnarchive(for: item!))
            XCTAssertEqual(renderedItems(vm)[id]?.visibility, "timeline")
        }
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    @MainActor
    func test_setArchived_AC19_refusalKeptForGridWhenViewerClosed() async {
        let mock = MockImmichClient()
        let vm = await archivedGridVM(mock)
        let itemsBefore = vm.items
        mock.globalError = APIError.serverError(500, "boom")
        let expected = localizedString("The server ran into a problem. Please try again.")

        let message = await vm.setArchived(id: "a1", archived: false, handOffError: false)

        XCTAssertEqual(message, expected)
        XCTAssertEqual(vm.actionErrorMessage, expected)
        XCTAssertEqual(vm.items, itemsBefore)
    }
}
