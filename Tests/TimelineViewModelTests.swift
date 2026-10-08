import XCTest
@testable import ImmichSwiftUI

final class TimelineViewModelTests: XCTestCase {

    /// Builds a columnar TimeBucketAssetResponseDto with two well-known assets
    /// so the zip step has predictable per-index values (AC-013).
    private func columnar(ids: [String], ratios: [Double], thumbhashes: [String?], favorites: [Bool]) -> TimeBucketAssetResponseDto {
        TimeBucketAssetResponseDto(
            id: ids,
            ownerId: ids.map { _ in "owner" },
            ratio: ratios,
            isFavorite: favorites,
            visibility: ids.map { _ in "timeline" },
            isTrashed: ids.map { _ in false },
            isImage: ids.map { _ in true },
            thumbhash: thumbhashes,
            createdAt: ids.map { _ in "2024-07-01T00:00:00.000Z" },
            fileCreatedAt: ids.map { _ in "2024-07-01T00:00:00.000Z" },
            localOffsetHours: ids.map { _ in 0.0 },
            duration: ids.map { _ in nil },
            livePhotoVideoId: ids.map { _ in nil },
            projectionType: ids.map { _ in nil },
            stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
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
        await vm.deleteSelected()
        XCTAssertNil(mock.lastDeleteBody, "no delete call when nothing selected")
        XCTAssertEqual(vm.items.count, 4, "empty delete must not mutate items")

        // Select 2, delete.
        vm.toggleSelection(id: "a2")
        vm.toggleSelection(id: "a4")
        await vm.deleteSelected()

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
        await vm.deleteSelected()

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

        await vm.archiveSelected()

        XCTAssertEqual(mock.lastBulkUpdateDto?.ids.sorted(), ["a1", "a3"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .archive)
    }

    @MainActor
    func test_archive_selected_removesItemsAndExitsSelection() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a2")

        await vm.archiveSelected()

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

        await vm.archiveSelected()

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

        await vm.archiveSelected()

        XCTAssertNil(mock.lastBulkUpdateDto)
        XCTAssertEqual(vm.items.count, 3)
    }

    // MARK: - Filter (P1 card 6/8)

    @MainActor
    func test_filter_favorite_reloadsWithFavoriteParam() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)

        await vm.setFilter(isFavorite: true, visibility: nil)

        XCTAssertEqual(mock.lastTimeBucketsIsFavorite, true)
        XCTAssertNil(mock.lastTimeBucketsVisibility)
        XCTAssertFalse(mock.lastTimeBucketsIsTrashed ?? false)
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "a3"], "fresh reload after filter change")
    }

    @MainActor
    func test_filter_archive_visibility() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)

        await vm.setFilter(isFavorite: nil, visibility: "archive")

        XCTAssertNil(mock.lastTimeBucketsIsFavorite)
        XCTAssertEqual(mock.lastTimeBucketsVisibility, "archive")
        XCTAssertEqual(mock.lastTimeBucketVisibility, "archive", "bucket load inherits the filter")
    }

    @MainActor
    func test_filter_unchanged_isNoOp() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        let calls = mock.requestCount

        await vm.setFilter(isFavorite: nil, visibility: nil)

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

        await vm.setFilter(isFavorite: true, visibility: nil)

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

        await vm.setFilter(isFavorite: true, visibility: nil)

        XCTAssertEqual(vm.loadErrorMessage, localizedString("The server ran into a problem. Please try again."))
    }

    @MainActor
    func test_filter_retryViaRefresh() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        mock.globalError = APIError.serverError(500, "boom")
        await vm.setFilter(isFavorite: true, visibility: nil)
        mock.globalError = nil

        await vm.refresh()

        XCTAssertEqual(mock.lastTimeBucketsIsFavorite, true, "refresh keeps the committed filter")
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "a3"])
    }

    @MainActor
    func test_filter_sharedWithYou_usesWithPartners() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)

        await vm.setFilter(isFavorite: nil, visibility: nil, withPartners: true)

        XCTAssertEqual(mock.lastTimeBucketsWithPartners, true)
        XCTAssertNil(mock.lastTimeBucketsIsFavorite)
        XCTAssertNil(mock.lastTimeBucketsVisibility)
        XCTAssertEqual(mock.lastTimeBucketWithPartners, true, "bucket load inherits withPartners")
    }

    @MainActor
    func test_filter_withPartners_noOpOnIdenticalValues() async {
        let mock = MockImmichClient()
        let vm = await makeLoadedVM(mock)
        await vm.setFilter(isFavorite: nil, visibility: nil, withPartners: true)
        let calls = mock.requestCount

        await vm.setFilter(isFavorite: nil, visibility: nil, withPartners: true)

        XCTAssertEqual(mock.requestCount, calls, "identical partner filter does not reload")
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

        await vm.stackSelected()

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
}
