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

    // MARK: - Date scrubber (L-04)

    /// Server key of the month `k` places back from December 2025 (`0` = newest).
    private func scrubKey(_ k: Int) -> String {
        let total = 2025 * 12 + 11 - k
        return String(format: "%04d-%02d-01", total / 12, total % 12 + 1)
    }

    /// Id of the photo of rank `rank` (grid order, newest first) of month `k`.
    private func scrubId(_ k: Int, rank: Int) -> String {
        let month: String = String(scrubKey(k).prefix(7))
        let padded: String = String(format: "%03d", rank)
        return "s-\(month)-\(padded)"
    }

    /// A month of `count` photos with distinct, strictly decreasing capture
    /// times by rank — served in the REVERSE order, so that the server order
    /// is never the grid order.
    private func scrubColumnar(month k: Int, count: Int) -> TimeBucketAssetResponseDto {
        let month: String = String(scrubKey(k).prefix(7))
        var ids: [String] = []
        var stamps: [String] = []
        for rank in (0..<count).reversed() {
            ids.append(scrubId(k, rank: rank))
            let minute: String = String(format: "%02d", 59 - rank)
            stamps.append("\(month)-15T12:\(minute):00.000Z")
        }
        let n: Int = ids.count
        let noStrings: [String?] = Array(repeating: nil, count: n)
        let noInts: [Int?] = Array(repeating: nil, count: n)
        return TimeBucketAssetResponseDto(
            id: ids,
            ownerId: Array(repeating: "owner", count: n),
            ratio: Array(repeating: 1.0, count: n),
            isFavorite: Array(repeating: false, count: n),
            visibility: Array(repeating: "timeline", count: n),
            isTrashed: Array(repeating: false, count: n),
            isImage: Array(repeating: true, count: n),
            thumbhash: noStrings,
            createdAt: stamps,
            fileCreatedAt: stamps,
            localOffsetHours: Array(repeating: 0.0, count: n),
            duration: noInts,
            livePhotoVideoId: noStrings,
            projectionType: noStrings,
            stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
        )
    }

    /// 36 months (Dec 2025 … Jan 2023), 6 photos each unless `counts` says otherwise.
    @MainActor
    private func scrubMock(counts: [Int: Int] = [:]) -> MockImmichClient {
        let mock = MockImmichClient()
        mock.bucketsResponse = (0..<36).map { TimeBucketsResponseDto(timeBucket: scrubKey($0), count: counts[$0] ?? 6) }
        for k in 0..<36 { mock.bucketResponses[scrubKey(k)] = scrubColumnar(month: k, count: counts[k] ?? 6) }
        return mock
    }

    /// A VM that has done its first load: only the newest month is in.
    @MainActor
    private func scrubVM(_ mock: MockImmichClient) async -> TimelineViewModel {
        let vm = TimelineViewModel(client: mock)
        await vm.load()
        return vm
    }

    private func monthPrefixes(_ vm: TimelineViewModel) -> [String] {
        vm.items.map { String($0.id.dropFirst(2).prefix(7)) }
    }

    func test_AC_90_scrubberMath_monthAtEachBoundary() {
        let n = 36
        for k in 0..<n {
            let inside = TimelineScrubberMath.target(atTrackFraction: (Double(k) + 0.5) / Double(n), monthCount: n)
            XCTAssertEqual(inside?.monthIndex, k)
            XCTAssertEqual(inside?.fraction ?? -1, 0.5, accuracy: 1e-9)
            XCTAssertEqual(TimelineScrubberMath.target(atTrackFraction: Double(k) / Double(n) + 1e-9, monthCount: n)?.monthIndex, k)
            XCTAssertEqual(TimelineScrubberMath.target(atTrackFraction: Double(k + 1) / Double(n) - 1e-9, monthCount: n)?.monthIndex, k)
        }
        let top = TimelineScrubberMath.target(atTrackFraction: 0, monthCount: n)
        XCTAssertEqual(top?.monthIndex, 0)
        XCTAssertEqual(top?.fraction, 0)
        let bottom = TimelineScrubberMath.target(atTrackFraction: 1, monthCount: n)
        XCTAssertEqual(bottom?.monthIndex, 35)
        XCTAssertLessThan(bottom?.fraction ?? 2, 1, "the end of the track stays inside the oldest month")
        XCTAssertEqual(TimelineScrubberMath.target(atTrackFraction: -3, monthCount: n)?.monthIndex, 0)
        XCTAssertEqual(TimelineScrubberMath.target(atTrackFraction: 7, monthCount: n)?.monthIndex, 35)

        let only = TimelineScrubberMath.target(atTrackFraction: 0.4, monthCount: 1)
        XCTAssertEqual(only?.monthIndex, 0)
        XCTAssertEqual(only?.fraction ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertNil(TimelineScrubberMath.target(atTrackFraction: 0.4, monthCount: 0))

        XCTAssertEqual(TimelineScrubberMath.trackFraction(monthIndex: 18, fraction: 0.5, monthCount: 36), 18.5 / 36, accuracy: 1e-12)
        XCTAssertEqual(TimelineScrubberMath.trackFraction(monthIndex: 0, fraction: 0, monthCount: 0), 0)
    }

    func test_AC_90_monthLabel_followsLocale() {
        XCTAssertEqual(TimelineSectionBuilder.monthLabel(forTimeBucket: "2023-03-01", locale: Locale(identifier: "fr_FR")), "mars 2023")
        XCTAssertEqual(TimelineSectionBuilder.monthLabel(forTimeBucket: "2023-03-01", locale: Locale(identifier: "en_US")), "March 2023")
    }

    func test_AC_90_labelVisibleAndUpdatedDuringDrag() {
        let n = 36
        var gesture = TimelineScrubberGesture()
        XCTAssertNil(gesture.labelMonthIndex)
        XCTAssertFalse(gesture.isScrubbing)

        for k in [10, 11, 12] {
            gesture.changed(trackFraction: (Double(k) + 0.5) / Double(n), monthCount: n)
            XCTAssertTrue(gesture.isScrubbing, "the finger is still down")
            XCTAssertEqual(gesture.labelMonthIndex, k, "the bubble names the month under the finger")
        }
        let before = gesture.labelMonthIndex
        gesture.changed(trackFraction: 12.7 / Double(n), monthCount: n)
        XCTAssertEqual(gesture.labelMonthIndex, before, "a move inside the same month changes nothing")

        gesture.changed(trackFraction: 12.5 / Double(n), monthCount: n)
        let staleToken = gesture.lingerToken
        let release = gesture.ended(monthCount: n)
        XCTAssertEqual(release?.monthIndex, 12)
        XCTAssertEqual(release?.fraction ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertFalse(gesture.isScrubbing)
        XCTAssertEqual(gesture.labelMonthIndex, 12, "the bubble keeps the released month")

        // A new gesture before the delay is up cancels the planned fade.
        let lingering = gesture.lingerToken
        gesture.changed(trackFraction: 13.5 / Double(n), monthCount: n)
        gesture.lingerExpired(token: lingering)
        XCTAssertEqual(gesture.labelMonthIndex, 13)
        XCTAssertNotEqual(staleToken, gesture.lingerToken)

        _ = gesture.ended(monthCount: n)
        let finalToken = gesture.lingerToken
        gesture.lingerExpired(token: finalToken)
        XCTAssertNil(gesture.labelMonthIndex, "the bubble fades once the delay is up")
    }

    func test_AC_92_anchorRank() {
        XCTAssertEqual(TimelineScrubberMath.anchorRank(fraction: 0.5, count: 21), 10)
        XCTAssertEqual(TimelineScrubberMath.anchorRank(fraction: 0, count: 21), 0)
        XCTAssertEqual(TimelineScrubberMath.anchorRank(fraction: 1.0.nextDown, count: 21), 20)
        XCTAssertEqual(TimelineScrubberMath.anchorRank(fraction: 0.9, count: 1), 0)
        XCTAssertEqual(TimelineScrubberMath.anchorRank(fraction: 0.5, count: 0), 0)
    }

    @MainActor
    func test_AC_92_jumpToMonth_anchorsOnRankInGridOrder() async {
        let mock = scrubMock(counts: [18: 21])
        let vm = await scrubVM(mock)

        let middle = await vm.jumpToMonth(at: 18, fraction: 0.5)
        XCTAssertEqual(middle, scrubId(18, rank: 10), "the 11th photo of the month in grid order")
        XCTAssertEqual(vm.items.count, 21)
        XCTAssertEqual(vm.topVisibleId, middle)

        let first = await vm.jumpToMonth(at: 18, fraction: 0)
        XCTAssertEqual(first, scrubId(18, rank: 0), "the newest photo of the month, whatever the server order")
        XCTAssertEqual(vm.scrubPosition, TimelineScrubPosition(monthIndex: 18, fraction: 0))
    }

    @MainActor
    func test_AC_87_jumpToMonth_repeatsBucketsFiltersAndOpensNeighbours() async {
        let mock = scrubMock()
        let vm = await scrubVM(mock)
        XCTAssertEqual(mock.timeBucketCalls.count, 1)

        await vm.jumpToMonth(at: 10, fraction: 0)

        XCTAssertEqual(mock.timeBucketCalls.count, 2, "one GET bucket for the jump")
        XCTAssertEqual(mock.timeBucketCalls.last?.timeBucket, scrubKey(10))
        XCTAssertEqual(mock.timeBucketCalls.last?.filters, mock.lastTimeBucketsFilters, "same filters on /bucket as on /buckets")
        XCTAssertEqual(mock.lastTimeBucketVisibility, "timeline", "visibility=timeline is explicit for «All»")
        XCTAssertEqual(mock.lastTimeBucketWithPartners, true)
        XCTAssertEqual(vm.bucketIndex, 11)
        XCTAssertEqual(vm.upperBucketIndex, 9)
        XCTAssertEqual(monthPrefixes(vm), Array(repeating: String(scrubKey(10).prefix(7)), count: 6))

        await vm.loadNewer()
        await vm.loadMore()

        XCTAssertEqual(vm.upperBucketIndex, 8)
        XCTAssertEqual(vm.bucketIndex, 12)
        let months = monthPrefixes(vm)
        XCTAssertEqual(months.count, 18)
        XCTAssertEqual(Set(vm.items.map(\.id)).count, 18, "no photo twice")
        let expected = [9, 10, 11].flatMap { Array(repeating: String(scrubKey($0).prefix(7)), count: 6) }
        XCTAssertEqual(months, expected, "the neighbours come in order, no month skipped")
    }

    @MainActor
    func test_AC_95_obsoleteJumpResponseIsIgnored() async {
        let mock = scrubMock()
        let vm = await scrubVM(mock)
        let latch = TestLatch()
        let slow = scrubKey(20)
        mock.timeBucketGate = { key in if key == slow { try await latch.wait() } }

        let jumpA = Task { await vm.jumpToMonth(at: 20, fraction: 0) }
        await pollUntil("the request of A") { mock.timeBucketCalls.last?.timeBucket == slow }
        let idB = await vm.jumpToMonth(at: 10, fraction: 0)
        XCTAssertNotNil(idB)
        latch.open()
        let idA = await jumpA.value

        XCTAssertNil(idA, "the late answer of A is dropped")
        XCTAssertEqual(monthPrefixes(vm), Array(repeating: String(scrubKey(10).prefix(7)), count: 6))
        XCTAssertEqual(vm.scrubPosition?.monthIndex, 10)
        XCTAssertEqual(vm.upperBucketIndex, 9)
        XCTAssertEqual(vm.bucketIndex, 11)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.loadErrorMessage)
    }

    @MainActor
    func test_AC_95_jumpDuringLoadNewerKeepsJumpWindow() async {
        let mock = scrubMock()
        let vm = await scrubVM(mock)
        await vm.jumpToMonth(at: 10, fraction: 0)
        let latch = TestLatch()
        let held = scrubKey(9)
        mock.timeBucketGate = { key in if key == held { try await latch.wait() } }

        let newer = Task { await vm.loadNewer() }
        await pollUntil("the request of the newer month") { mock.timeBucketCalls.last?.timeBucket == held }
        await vm.jumpToMonth(at: 20, fraction: 0)
        latch.open()
        await newer.value

        XCTAssertEqual(monthPrefixes(vm), Array(repeating: String(scrubKey(20).prefix(7)), count: 6), "the interrupted load adds nothing")
        XCTAssertEqual(vm.upperBucketIndex, 19)
        XCTAssertEqual(vm.bucketIndex, 21)
        XCTAssertFalse(vm.isLoading)

        await vm.loadNewer()
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 18, "both neighbours of the jump still load")
    }

    @MainActor
    func test_AC_95_jumpDuringLoadMoreKeepsJumpWindow() async {
        let mock = scrubMock()
        let vm = await scrubVM(mock)
        let latch = TestLatch()
        let held = scrubKey(1)
        mock.timeBucketGate = { key in if key == held { try await latch.wait() } }

        let more = Task { await vm.loadMore() }
        await pollUntil("the request of the older month") { mock.timeBucketCalls.last?.timeBucket == held }
        await vm.jumpToMonth(at: 10, fraction: 0)
        latch.open()
        await more.value

        XCTAssertEqual(monthPrefixes(vm), Array(repeating: String(scrubKey(10).prefix(7)), count: 6), "the interrupted load adds nothing")
        XCTAssertEqual(vm.bucketIndex, 11)
        XCTAssertEqual(vm.upperBucketIndex, 9)

        await vm.loadMore()
        XCTAssertEqual(vm.bucketIndex, 12)
        XCTAssertEqual(vm.items.count, 12)
    }

    @MainActor
    func test_AC_95_refreshSupersedesJumpInFlight() async {
        let mock = scrubMock()
        let vm = await scrubVM(mock)
        let latch = TestLatch()
        let slow = scrubKey(20)
        mock.timeBucketGate = { key in if key == slow { try await latch.wait() } }

        let jumpA = Task { await vm.jumpToMonth(at: 20, fraction: 0) }
        await pollUntil("the request of A") { mock.timeBucketCalls.last?.timeBucket == slow }
        await vm.refresh()
        latch.open()
        let idA = await jumpA.value

        XCTAssertNil(idA)
        XCTAssertEqual(monthPrefixes(vm), Array(repeating: String(scrubKey(0).prefix(7)), count: 6), "the refresh wins")
        XCTAssertNil(vm.scrubPosition)
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.windowStartsAtNewest)
    }

    @MainActor
    func test_AC_89_failedJumpRetryReloadsSameMonthOnly() async {
        let mock = scrubMock()
        let vm = await scrubVM(mock)
        let itemsBefore = vm.items

        mock.timeBucketErrorQueue = [APIError.serverError(500, "boom")]
        let failed = await vm.jumpToMonth(at: 12, fraction: 0.5)

        XCTAssertNil(failed)
        XCTAssertNotNil(vm.loadErrorMessage, "the banner offers «Try Again»")
        XCTAssertEqual(vm.pendingJump, PendingJump(timeBucket: scrubKey(12), fraction: 0.5))
        XCTAssertEqual(vm.items, itemsBefore, "the window on screen stays")
        XCTAssertNil(vm.scrubPosition, "the handle goes back where it was")
        XCTAssertFalse(vm.isLoading)

        let requests = mock.requestCount
        let id = await vm.retryLoad()

        XCTAssertEqual(id, scrubId(12, rank: 3))
        XCTAssertEqual(mock.requestCount, requests + 1, "one GET bucket, no GET buckets")
        XCTAssertEqual(mock.timeBucketCalls.last?.timeBucket, scrubKey(12))
        XCTAssertEqual(monthPrefixes(vm), Array(repeating: String(scrubKey(12).prefix(7)), count: 6))
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertNil(vm.pendingJump)
    }

    @MainActor
    func test_AC_89_cancelledJumpLeavesNoPendingRetry() async {
        let mock = scrubMock()
        let vm = await scrubVM(mock)

        mock.timeBucketErrorQueue = [URLError(.cancelled)]
        let result = await vm.jumpToMonth(at: 12, fraction: 0)

        XCTAssertNil(result)
        XCTAssertNil(vm.loadErrorMessage, "a cancelled jump writes no banner")
        XCTAssertNil(vm.pendingJump)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func test_AC_91_updateScrubPosition_usesMinimumPlaceWhateverTheOrder() async {
        let mock = scrubMock(counts: [5: 21])
        let vm = await scrubVM(mock)
        await vm.jumpToMonth(at: 5, fraction: 0)

        vm.updateScrubPosition(visibleIds: [scrubId(5, rank: 12), "unknown", scrubId(5, rank: 7), scrubId(5, rank: 9)])
        XCTAssertEqual(vm.scrubPosition, TimelineScrubPosition(monthIndex: 5, fraction: 7.0 / 21.0))
        XCTAssertEqual(vm.topVisibleId, scrubId(5, rank: 7))

        vm.updateScrubPosition(visibleIds: [])
        XCTAssertEqual(vm.scrubPosition?.monthIndex, 5, "nothing reported, nothing changes")

        await vm.loadMore()
        vm.updateScrubPosition(visibleIds: [scrubId(6, rank: 0), scrubId(5, rank: 20)])
        XCTAssertEqual(vm.scrubPosition, TimelineScrubPosition(monthIndex: 5, fraction: 20.0 / 21.0), "an older month's photo never wins")

        vm.updateScrubPosition(visibleIds: [scrubId(6, rank: 0)])
        XCTAssertEqual(vm.scrubPosition, TimelineScrubPosition(monthIndex: 6, fraction: 0))
    }

    @MainActor
    func test_AC_91_failedReloadLeavesNoOutOfRangePlace() async {
        let mock = scrubMock()
        let vm = await scrubVM(mock)
        await vm.jumpToMonth(at: 3, fraction: 0)
        let shown = vm.items.map(\.id)
        vm.updateScrubPosition(visibleIds: [shown[0]])
        XCTAssertEqual(vm.scrubPosition?.monthIndex, 3)

        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2025-10-01", count: 3),
            TimeBucketsResponseDto(timeBucket: "2024-10-01", count: 3)
        ]
        mock.timeBucketErrorQueue = [APIError.serverError(500, "boom")]
        await vm.setFilter(.archived)

        XCTAssertEqual(vm.items.map(\.id), shown, "the photos from before stay")
        XCTAssertNil(vm.scrubPosition, "the handle waits at the top")
        vm.updateScrubPosition(visibleIds: shown)
        XCTAssertNil(vm.scrubPosition, "old places are not restored against the new list")
    }

    func test_AC_93_adjustedMonthIndexClamps() {
        // The slider runs oldest (0) to newest (n - 1): an increment is a newer month.
        XCTAssertEqual(TimelineScrubberMath.sliderValue(monthIndex: 0, monthCount: 36), 35)
        XCTAssertEqual(TimelineScrubberMath.sliderValue(monthIndex: 35, monthCount: 36), 0)
        XCTAssertEqual(TimelineScrubberMath.monthIndex(sliderValue: 34, monthCount: 36), 1, "one step down = older")
        XCTAssertEqual(TimelineScrubberMath.monthIndex(sliderValue: 35, monthCount: 36), 0, "one step up = newer")
        XCTAssertEqual(TimelineScrubberMath.monthIndex(sliderValue: 99, monthCount: 36), 0, "clamped to the newest")
        XCTAssertEqual(TimelineScrubberMath.monthIndex(sliderValue: -4, monthCount: 36), 35, "clamped to the oldest")
        XCTAssertEqual(TimelineScrubberMath.monthIndex(sliderValue: .nan, monthCount: 36), 0)
        for month in 0..<36 {
            let value = TimelineScrubberMath.sliderValue(monthIndex: month, monthCount: 36)
            XCTAssertEqual(TimelineScrubberMath.monthIndex(sliderValue: value, monthCount: 36), month)
        }
    }

    @MainActor
    func test_AC_96_jumpToNewestRestoresWindowStart() async {
        let mock = scrubMock()
        let vm = await scrubVM(mock)
        XCTAssertTrue(vm.windowStartsAtNewest)

        await vm.jumpToMonth(at: 35, fraction: 0)
        XCTAssertFalse(vm.windowStartsAtNewest, "a newer month is missing above the window")

        let id = await vm.jumpToMonth(at: 0, fraction: 0)
        XCTAssertEqual(id, scrubId(0, rank: 0))
        XCTAssertTrue(vm.windowStartsAtNewest)
        XCTAssertEqual(monthPrefixes(vm), Array(repeating: String(scrubKey(0).prefix(7)), count: 6))
        XCTAssertEqual(vm.scrubPosition, TimelineScrubPosition(monthIndex: 0, fraction: 0))
    }
}

// MARK: - Realtime

private let rt8 = "2024-08-01", rt7 = "2024-07-01", rt6 = "2024-06-01"
private let rt5 = "2024-05-01", rt4 = "2024-04-01", rt3 = "2024-03-01"

/// Holds the `matching`-th (0-based `skip`) timeline call whose key equals
/// `target`, until `open()`. Logs every key it sees. Thread-safe: the mock calls
/// it off the main actor.
private final class RTGate: @unchecked Sendable {
    private let lock = NSLock()
    private let target: String
    private var skip: Int
    private var entered = false
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var keys: [String] = []

    init(target: String, skip: Int = 0) {
        self.target = target
        self.skip = skip
    }

    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return entered && !opened }
    var seen: [String] { lock.lock(); defer { lock.unlock() }; return keys }

    /// Locked, synchronous part of `pass`: true when this call must park.
    private func shouldPark(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        keys.append(key)
        guard key == target, !entered else { return false }
        if skip > 0 { skip -= 1; return false }
        entered = true
        return true
    }

    private func park(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if opened {
            lock.unlock()
            c.resume()
            return
        }
        continuation = c
        lock.unlock()
    }

    func pass(_ key: String) async {
        guard shouldPark(key) else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in park(c) }
    }

    func open() {
        lock.lock()
        opened = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

extension TimelineViewModelTests {

    private func rtMonth(_ key: String, _ ids: [String], favorites: [Bool]? = nil, stacks: [[String]?]? = nil) -> TimeBucketAssetResponseDto {
        TimeBucketAssetResponseDto(
            id: ids,
            ownerId: ids.map { _ in "owner" },
            ratio: ids.map { _ in 1.0 },
            isFavorite: favorites ?? ids.map { _ in false },
            visibility: ids.map { _ in "timeline" },
            isTrashed: ids.map { _ in false },
            isImage: ids.map { _ in true },
            thumbhash: ids.map { _ in nil },
            createdAt: ids.map { _ in "\(key)T00:00:00.000Z" },
            fileCreatedAt: ids.map { _ in "\(key)T00:00:00.000Z" },
            localOffsetHours: ids.map { _ in 0.0 },
            duration: ids.map { _ in nil },
            livePhotoVideoId: ids.map { _ in nil },
            projectionType: ids.map { _ in nil },
            stack: stacks, city: nil, country: nil, latitude: nil, longitude: nil
        )
    }

    /// Server state: the month list (in the given, newest-first order) and each month's photos.
    private func rtServe(_ mock: MockImmichClient, _ months: [(String, [String])]) {
        mock.bucketsResponse = months.map { TimeBucketsResponseDto(timeBucket: $0.0, count: $0.1.count) }
        mock.bucketResponses = Dictionary(uniqueKeysWithValues: months.map { ($0.0, rtMonth($0.0, $0.1)) })
    }

    /// Photos the grid renders, from the memoized sections.
    private func rtRendered(_ vm: TimelineViewModel) -> [AssetReactItem] {
        vm.timelineSections(groupBy: .day).flatMap { section -> [AssetReactItem] in
            switch section {
            case .dayGroup(_, let items), .monthGroup(_, let items), .flat(let items): return items
            case .monthHeader: return []
            }
        }
    }

    @MainActor
    private func rtWaitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for the condition", file: file, line: line)
    }

    /// A VM refreshed on `months`, then `moreMonths` scroll loads.
    @MainActor
    private func rtLoadedVM(_ mock: MockImmichClient, _ months: [(String, [String])], scrolled: Int = 0) async -> TimelineViewModel {
        rtServe(mock, months)
        let vm = TimelineViewModel(client: mock)
        await vm.refresh()
        for _ in 0..<scrolled { await vm.loadMore() }
        return vm
    }

    /// Same chain as the app: names → `RealtimeService` (no socket) → notification →
    /// `RealtimeRelay.handle`, with the other screens on a second mock (`side`).
    @MainActor
    private func deliver(_ events: [String], to vm: TimelineViewModel, side: MockImmichClient = MockImmichClient()) async {
        let center = NotificationCenter()
        let transport = MockRealtimeTransport()
        let service = RealtimeService(transport: transport, debounceInterval: .zero, notificationCenter: center)
        service.connect(baseURL: URL(string: "https://photos.example.com")!, token: "t")
        var captured: Notification?
        let arrived = expectation(forNotification: .immichAssetsChanged, object: nil, notificationCenter: center) { note in
            captured = note
            return true
        }
        events.forEach(transport.emit)
        await fulfillment(of: [arrived], timeout: 2)
        guard let note = captured else { return XCTFail("no notification") }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rt-offline-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: "rt-offline-\(UUID().uuidString)")!
        let store = OfflineAssetStore(rootURL: folder, transport: MockFileDownloadTransport(), defaults: defaults)
        await RealtimeRelay.handle(
            note, timeline: vm,
            albums: AlbumsViewModel(client: side), people: PeopleViewModel(client: side),
            memories: MemoriesViewModel(client: side),
            offline: OfflineDownloadViewModel(store: store, client: side, index: OfflineAssetIndex(), accountID: "rt-account")
        )
    }

    // MARK: Selection

    // AC-4: an asset event during a selection keeps the mode and the exact selection.
    @MainActor
    func test_realtime_AC4_eventDuringSelectionKeepsSelection() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2", "a3"])])
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")
        rtServe(mock, [(rt7, ["n1", "a1", "a2", "a3"])])

        await deliver(["on_upload_success"], to: vm)

        XCTAssertTrue(vm.selectionMode)
        XCTAssertEqual(vm.selectedIds, ["a1", "a2"])
    }

    // AC-5: a photo added during a selection is on the grid once the user leaves selection mode.
    @MainActor
    func test_realtime_AC5_photoAddedDuringSelectionShownAfterExit() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"])])
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        rtServe(mock, [(rt7, ["n1", "a1", "a2"])])

        await deliver(["on_upload_success"], to: vm)
        vm.exitSelectionMode()

        XCTAssertTrue(rtRendered(vm).contains { $0.id == "n1" })
        XCTAssertTrue(vm.items.contains { $0.id == "n1" })
    }

    // AC-6: a photo deleted elsewhere leaves the grid and the selection; the mode stays.
    @MainActor
    func test_realtime_AC6_photoDeletedElsewhereLeavesGridAndSelection() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2", "a3"])])
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")
        rtServe(mock, [(rt7, ["a2", "a3"])])

        await deliver(["on_asset_delete"], to: vm)

        XCTAssertFalse(vm.items.contains { $0.id == "a1" })
        XCTAssertFalse(rtRendered(vm).contains { $0.id == "a1" })
        XCTAssertEqual(vm.selectedIds, ["a2"])
        XCTAssertTrue(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isSubset(of: vm.loadedIds))
    }

    // MARK: Loaded window kept

    // AC-7: three scrolled months stay loaded; one list + three months are re-read, nothing else.
    @MainActor
    func test_realtime_AC7_threeLoadedMonthsStayLoaded() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1", "b2"]), (rt5, ["c1"]), (rt4, ["d1"])], scrolled: 2)
        XCTAssertEqual(vm.bucketIndex, 3)
        let before = mock.requestCount
        let revision = vm.realtimeRevision

        await deliver(["on_asset_update"], to: vm)

        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "b1", "b2", "c1"])
        XCTAssertEqual(vm.bucketIndex, 3)
        XCTAssertEqual(vm.upperBucketIndex, -1)
        XCTAssertEqual(mock.requestCount - before, 4, "1 list + 3 loaded months")
        XCTAssertEqual(vm.realtimeRevision, revision + 1)
    }

    // AC-8: a photo deleted on the server leaves the rendered sections; the others stay.
    @MainActor
    func test_realtime_AC8_deletedPhotoLeavesRenderedSections() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1", "b2"])], scrolled: 1)
        XCTAssertEqual(rtRendered(vm).count, 4, "primes the section cache")
        rtServe(mock, [(rt7, ["a1", "a2"]), (rt6, ["b2"])])

        await deliver(["on_asset_delete"], to: vm)

        XCTAssertEqual(Set(rtRendered(vm).map(\.id)), ["a1", "a2", "b2"])
        XCTAssertEqual(Set(vm.groupedByDay.flatMap(\.items).map(\.id)), ["a1", "a2", "b2"])
    }

    // AC-9: a photo added to a loaded month appears once, in the rendered sections.
    @MainActor
    func test_realtime_AC9_addedPhotoAppearsOnceInItsMonth() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1"]), (rt6, ["b1"])], scrolled: 1)
        XCTAssertEqual(rtRendered(vm).count, 2)
        rtServe(mock, [(rt7, ["a1"]), (rt6, ["b1", "n1"])])

        await deliver(["on_upload_success"], to: vm)

        let rendered = rtRendered(vm).map(\.id)
        XCTAssertEqual(rendered.filter { $0 == "n1" }.count, 1)
        XCTAssertEqual(Set(rendered), ["a1", "b1", "n1"])
        XCTAssertEqual(vm.items.count, Set(vm.items.map(\.id)).count, "no duplicate")
        XCTAssertEqual(vm.loadedIds, Set(vm.items.map(\.id)))
    }

    // AC-10: after a jump the window stays; paging then continues up and down without skip or repeat.
    @MainActor
    func test_realtime_AC10_jumpWindowKeptAndPagingContinues() async {
        let mock = MockImmichClient()
        let months = [(rt8, ["h1"]), (rt7, ["a1"]), (rt6, ["b1"]), (rt5, ["c1"]), (rt4, ["d1"])]
        rtServe(mock, months)
        let vm = TimelineViewModel(client: mock)
        await vm.jump(toDay: rt5)
        XCTAssertEqual(vm.items.map(\.id), ["c1"])
        let callsBefore = mock.timeBucketCalls.count
        rtServe(mock, [(rt8, ["h1"]), (rt7, ["a1"]), (rt6, ["b1"]), (rt5, ["c1", "c2"]), (rt4, ["d1"])])

        await deliver(["on_asset_update"], to: vm)

        XCTAssertEqual(vm.items.map(\.id), ["c1", "c2"], "window stays on the jumped month")
        XCTAssertEqual(vm.upperBucketIndex, 2)
        XCTAssertEqual(vm.bucketIndex, 4)
        await vm.loadNewer()
        await vm.loadNewer()
        await vm.loadNewer()
        await vm.loadMore()
        XCTAssertEqual(vm.items.map(\.id), ["h1", "a1", "b1", "c1", "c2", "d1"])
        XCTAssertEqual(mock.timeBucketCalls.dropFirst(callsBefore).map(\.timeBucket), [rt5, rt6, rt7, rt8, rt4])
    }

    // AC-11 (example 3): the last loaded month vanishes; its neighbour loads without a scroll call, no repeat.
    @MainActor
    func test_realtime_AC11_monthEmptiedThenLoadMoreNoSkipNoRepeat() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1"]), (rt6, ["b1"]), (rt5, ["c1"])], scrolled: 1)
        XCTAssertEqual(vm.bucketIndex, 2)
        rtServe(mock, [(rt7, ["a1"]), (rt5, ["c1"])])
        let callsBefore = mock.timeBucketCalls.count

        await deliver(["on_asset_delete"], to: vm)

        XCTAssertEqual(vm.items.map(\.id), ["a1", "c1"], "05 loaded by the edge relaunch")
        XCTAssertEqual(vm.bucketIndex, 2)
        let afterEvent = mock.timeBucketCalls.count
        await vm.loadMore()
        XCTAssertEqual(mock.timeBucketCalls.count, afterEvent, "nothing left to load")
        XCTAssertEqual(mock.timeBucketCalls.dropFirst(callsBefore).map(\.timeBucket), [rt7, rt5])
        XCTAssertEqual(vm.items.map(\.id), ["a1", "c1"])
    }

    // AC-11 (example 4): a month that appears inside the loaded window is loaded.
    @MainActor
    func test_realtime_AC11_monthAppearedInsideWindowIsLoaded() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1"]), (rt5, ["c1"])], scrolled: 1)
        rtServe(mock, [(rt7, ["a1"]), (rt6, ["b1"]), (rt5, ["c1"])])

        await deliver(["on_upload_success"], to: vm)

        XCTAssertEqual(vm.items.map(\.id), ["a1", "b1", "c1"])
        XCTAssertEqual(vm.bucketIndex, 3)
        XCTAssertEqual(vm.upperBucketIndex, -1)
    }

    // AC-12: under the Favorites filter every request repeats the view's filters; only favorites show.
    @MainActor
    func test_realtime_AC12_favoritesFilterRepeatedOnEveryRequest() async {
        let mock = MockImmichClient()
        rtServe(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1"])])
        let vm = TimelineViewModel(client: mock)
        await vm.setFilter(.favorites)
        await vm.loadMore()
        let callsBefore = mock.timeBucketCalls.count
        mock.bucketResponses = [
            rt7: rtMonth(rt7, ["a1", "n1"], favorites: [true, true]),
            rt6: rtMonth(rt6, ["b1"], favorites: [true]),
        ]

        await deliver(["on_asset_update"], to: vm)

        let sent = mock.timeBucketCalls.dropFirst(callsBefore)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(mock.lastTimeBucketsFilters?.isFavorite, true)
        XCTAssertTrue(sent.allSatisfy { $0.filters == mock.lastTimeBucketsFilters })
        XCTAssertEqual(vm.items.map(\.id), ["a1", "n1", "b1"])
        XCTAssertTrue(vm.items.allSatisfy(\.isFavorite))
        XCTAssertTrue(vm.selectedIds.isSubset(of: vm.loadedIds))
    }

    // MARK: Event classification

    // AC-13: on_person_thumbnail alone: no timeline request, nothing moves.
    @MainActor
    func test_realtime_AC13_personThumbnailOnlyLeavesTimelineUntouched() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1"])], scrolled: 1)
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        let requests = mock.requestCount
        let items = vm.items, bucketIndex = vm.bucketIndex, upper = vm.upperBucketIndex, buckets = vm.buckets
        rtServe(mock, [(rt7, ["zz"])])

        await deliver(["on_person_thumbnail"], to: vm)

        XCTAssertEqual(mock.requestCount, requests)
        XCTAssertEqual(vm.items, items)
        XCTAssertEqual(vm.buckets, buckets)
        XCTAssertEqual(vm.bucketIndex, bucketIndex)
        XCTAssertEqual(vm.upperBucketIndex, upper)
        XCTAssertEqual(vm.selectedIds, ["a1"])
        XCTAssertTrue(vm.selectionMode)
    }

    // AC-14: a mixed burst updates the timeline like the asset event alone.
    @MainActor
    func test_realtime_AC14_mixedBurstUpdatesTimeline() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"])])
        rtServe(mock, [(rt7, ["a1"])])

        await deliver(["on_person_thumbnail", "on_asset_trash"], to: vm)

        XCTAssertEqual(vm.items.map(\.id), ["a1"])
    }

    // AC-15: the people list reloads on on_person_thumbnail, the timeline does not.
    @MainActor
    func test_realtime_AC15_personThumbnailReloadsPeopleNotTimeline() async {
        let mock = MockImmichClient()
        let side = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1"])])
        let requests = mock.requestCount
        XCTAssertNil(side.lastPeopleWithHidden)

        await deliver(["on_person_thumbnail"], to: vm, side: side)

        XCTAssertNotNil(side.lastPeopleWithHidden, "RealtimeRelay reloads people")
        XCTAssertEqual(mock.requestCount, requests)
    }

    // MARK: Failure

    // AC-16: a failed update (list, then a month) changes nothing visible.
    @MainActor
    func test_realtime_AC16_failedSyncKeepsGridAndSelection() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1"])], scrolled: 1)
        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        let items = vm.items, buckets = vm.buckets, bucketIndex = vm.bucketIndex, upper = vm.upperBucketIndex
        let revision = vm.realtimeRevision
        func assertUnchanged(_ note: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(vm.items, items, note, file: file, line: line)
            XCTAssertEqual(vm.buckets, buckets, note, file: file, line: line)
            XCTAssertEqual(vm.bucketIndex, bucketIndex, note, file: file, line: line)
            XCTAssertEqual(vm.upperBucketIndex, upper, note, file: file, line: line)
            XCTAssertEqual(vm.selectedIds, ["a1"], note, file: file, line: line)
            XCTAssertTrue(vm.selectionMode, note, file: file, line: line)
            XCTAssertNil(vm.loadErrorMessage, note, file: file, line: line)
            XCTAssertNil(vm.actionErrorMessage, note, file: file, line: line)
            XCTAssertFalse(vm.isLoading, note, file: file, line: line)
            XCTAssertEqual(vm.realtimeRevision, revision, note, file: file, line: line)
        }
        rtServe(mock, [(rt8, ["h1"]), (rt7, ["a2"]), (rt6, ["b1", "b2"])])

        mock.globalError = URLError(.notConnectedToInternet)
        await deliver(["on_asset_update"], to: vm)
        assertUnchanged("list fails")

        mock.globalError = nil
        mock.timelineGate = { key in if key == rt6 { mock.globalError = URLError(.timedOut) } }
        await deliver(["on_asset_update"], to: vm)
        assertUnchanged("second month fails, first month discarded")
    }

    // MARK: Section cache

    // AC-17: swap one photo for another (same count, same last id): the sections follow.
    @MainActor
    func test_realtime_AC17_sameCountSameLastIdStillRendered() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1", "b2"])], scrolled: 1)
        XCTAssertEqual(rtRendered(vm).count, 4)
        XCTAssertEqual(vm.groupedByDay.flatMap(\.items).count, 4)
        rtServe(mock, [(rt7, ["n1", "a2"]), (rt6, ["b1", "b2"])])

        await deliver(["on_asset_delete", "on_upload_success"], to: vm)

        XCTAssertEqual(vm.items.count, 4)
        XCTAssertEqual(vm.items.last?.id, "b2")
        for ids in [rtRendered(vm).map(\.id), vm.groupedByDay.flatMap(\.items).map(\.id)] {
            XCTAssertFalse(ids.contains("a1"))
            XCTAssertTrue(ids.contains("n1"))
        }
    }

    // AC-18: a favorite changed elsewhere shows on the rendered tile.
    @MainActor
    func test_realtime_AC18_favoriteChangedElsewhereShownInSections() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"])])
        XCTAssertEqual(rtRendered(vm).first { $0.id == "a1" }?.isFavorite, false)
        mock.bucketResponses[rt7] = rtMonth(rt7, ["a1", "a2"], favorites: [true, false])

        await deliver(["on_asset_update"], to: vm)

        XCTAssertEqual(rtRendered(vm).first { $0.id == "a1" }?.isFavorite, true)
        XCTAssertEqual(vm.groupedByDay.flatMap(\.items).first { $0.id == "a1" }?.isFavorite, true)
    }

    // AC-18: a photo removed from a stack elsewhere loses its stack badge on the tile.
    @MainActor
    func test_realtime_AC18_stackChangedElsewhereShownInSections() async {
        let mock = MockImmichClient()
        rtServe(mock, [(rt7, ["a1", "a2"])])
        mock.bucketResponses[rt7] = rtMonth(rt7, ["a1", "a2"], stacks: [["s1", "2"], nil])
        let vm = TimelineViewModel(client: mock)
        await vm.refresh()
        XCTAssertEqual(rtRendered(vm).first { $0.id == "a1" }?.stackId, "s1")
        mock.bucketResponses[rt7] = rtMonth(rt7, ["a1", "a2"], stacks: [nil, nil])

        await deliver(["on_asset_stack_update"], to: vm)

        XCTAssertNil(rtRendered(vm).first { $0.id == "a1" }?.stackId)
    }

    // AC-18: a redated photo moves to its new month when loaded, leaves the grid otherwise; never duplicated.
    @MainActor
    func test_realtime_AC18_redatedPhotoMovesOrLeaves() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1"]), (rt5, ["c1"])], scrolled: 1)
        XCTAssertEqual(rtRendered(vm).count, 3)
        rtServe(mock, [(rt7, ["a2"]), (rt6, ["b1", "a1"]), (rt5, ["c1"])])

        await deliver(["on_asset_update"], to: vm)

        let moved = rtRendered(vm).filter { $0.id == "a1" }
        XCTAssertEqual(moved.count, 1)
        XCTAssertTrue(moved.first?.fileCreatedAt.hasPrefix("2024-06") == true)
        XCTAssertEqual(vm.items.count, Set(vm.items.map(\.id)).count)

        // The photo moves to 04: neither loaded nor the neighbour of the window.
        // (05 is loaded by the edge relaunch, since the last photo changed.)
        rtServe(mock, [(rt7, ["a2"]), (rt6, ["b1"]), (rt5, ["c1"]), (rt4, ["a1"])])
        await deliver(["on_asset_update"], to: vm)

        XCTAssertFalse(rtRendered(vm).contains { $0.id == "a1" }, "new month is not loaded")
        XCTAssertFalse(vm.loadedIds.contains("a1"))
        XCTAssertEqual(vm.items.map(\.id), ["a2", "b1", "c1"])
        XCTAssertEqual(vm.bucketIndex, 3)
    }

    // MARK: New head months

    // AC-19 (example 1): a newer month appears while the head is loaded: it is loaded in front, order kept.
    @MainActor
    func test_realtime_AC19_newHeadMonthLoadedWhenWindowHasHead() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1"])])
        let revision = vm.realtimeRevision
        rtServe(mock, [(rt8, ["h1", "h2"]), (rt7, ["a1", "a2"]), (rt6, ["b1"])])

        await deliver(["on_upload_success"], to: vm)

        XCTAssertEqual(vm.items.map(\.id), ["h1", "h2", "a1", "a2"])
        XCTAssertEqual(vm.upperBucketIndex, -1)
        XCTAssertEqual(vm.bucketIndex, 2)
        XCTAssertEqual(vm.realtimeRevision, revision + 1)
        await vm.loadMore()
        XCTAssertEqual(vm.items.map(\.id), ["h1", "h2", "a1", "a2", "b1"])
    }

    // AC-19 (example 2): after a jump, a newer month is not requested.
    @MainActor
    func test_realtime_AC19_newHeadMonthNotLoadedAfterJump() async {
        let mock = MockImmichClient()
        rtServe(mock, [(rt7, ["a1"]), (rt6, ["b1"]), (rt5, ["c1"]), (rt4, ["d1"])])
        let vm = TimelineViewModel(client: mock)
        await vm.jump(toDay: rt5)
        rtServe(mock, [(rt8, ["h1"]), (rt7, ["a1"]), (rt6, ["b1"]), (rt5, ["c1"]), (rt4, ["d1"])])

        await deliver(["on_upload_success"], to: vm)

        XCTAssertFalse(mock.timeBucketCalls.contains { $0.timeBucket == rt8 })
        XCTAssertEqual(vm.items.map(\.id), ["c1"])
        XCTAssertEqual(vm.buckets[vm.upperBucketIndex].timeBucket, rt6)
    }

    // AC-19: first upload into an empty library.
    @MainActor
    func test_realtime_AC19_firstUploadIntoEmptyLibrary() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [])
        XCTAssertTrue(vm.items.isEmpty)
        rtServe(mock, [(rt8, ["h1"])])

        await deliver(["on_upload_success"], to: vm)

        XCTAssertEqual(vm.items.map(\.id), ["h1"])
        XCTAssertEqual(vm.bucketIndex, 1)
    }

    // MARK: Concurrency

    // AC-20: a second burst during a pass ends on the latest answers, with exactly two list reads.
    @MainActor
    func test_realtime_AC20_secondBurstDuringSyncEndsOnLatest() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"])])
        let gate = RTGate(target: rt7)
        mock.timelineGate = { await gate.pass($0) }
        let first = Task { await self.deliver(["on_asset_update"], to: vm) }
        await rtWaitUntil { gate.isWaiting }
        rtServe(mock, [(rt7, ["n1", "a1", "a2"])])

        let requests = mock.requestCount
        await deliver(["on_asset_update"], to: vm)
        XCTAssertEqual(mock.requestCount, requests, "the second burst returns without a request")
        gate.open()
        await first.value

        XCTAssertEqual(vm.items.map(\.id), ["n1", "a1", "a2"])
        XCTAssertEqual(gate.seen.filter { $0 == "buckets" }.count, 2)
    }

    // AC-20: a scroll load in flight during a pass: no duplicate, indices consistent.
    @MainActor
    func test_realtime_AC20_loadMoreDuringSyncNoDuplicate() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1"]), (rt5, ["c1"])])
        let gate = RTGate(target: rt6)
        mock.timelineGate = { await gate.pass($0) }
        let scroll = Task { await vm.loadMore() }
        await rtWaitUntil { gate.isWaiting }
        rtServe(mock, [(rt7, ["n1", "a1", "a2"]), (rt6, ["b1"]), (rt5, ["c1"])])

        await deliver(["on_upload_success"], to: vm)
        gate.open()
        await scroll.value

        XCTAssertEqual(vm.items.map(\.id), ["n1", "a1", "a2", "b1"])
        XCTAssertEqual(vm.items.count, Set(vm.items.map(\.id)).count)
        XCTAssertEqual(vm.bucketIndex, 2)
        XCTAssertEqual(vm.buckets[vm.bucketIndex].timeBucket, rt5)
    }

    // AC-20: the window moved during a pass: the pass restarts and includes the new month.
    @MainActor
    func test_realtime_AC20_syncRestartsWhenWindowMovedMidFlight() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1"]), (rt5, ["c1"])])
        let gate = RTGate(target: rt7)
        mock.timelineGate = { await gate.pass($0) }
        let pass = Task { await self.deliver(["on_asset_update"], to: vm) }
        await rtWaitUntil { gate.isWaiting }

        await vm.loadMore()
        XCTAssertEqual(vm.bucketIndex, 2)
        gate.open()
        await pass.value

        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "b1"])
        XCTAssertEqual(vm.bucketIndex, 2)
        XCTAssertEqual(vm.items.count, Set(vm.items.map(\.id)).count)
    }

    // AC-21: bursts during a pass: each finished pass is applied, and they make one more pass only.
    @MainActor
    func test_realtime_AC21_burstsDuringSyncDoNotStarveIt() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"])])
        let passA = RTGate(target: rt7)
        let listOfPassB = RTGate(target: "buckets", skip: 1)
        mock.timelineGate = { key in
            await passA.pass(key)
            await listOfPassB.pass(key)
        }
        let first = Task { await self.deliver(["on_asset_update"], to: vm) }
        await rtWaitUntil { passA.isWaiting }
        rtServe(mock, [(rt7, ["n1", "a1", "a2"])])

        await deliver(["on_asset_update"], to: vm)
        await deliver(["on_asset_trash"], to: vm)
        passA.open()
        await rtWaitUntil { listOfPassB.isWaiting }

        XCTAssertEqual(vm.realtimeRevision, 1, "pass A is applied before pass B starts")
        XCTAssertEqual(vm.items.map(\.id), ["n1", "a1", "a2"])
        rtServe(mock, [(rt7, ["n2", "n1", "a1", "a2"])])
        listOfPassB.open()
        await first.value

        XCTAssertEqual(vm.realtimeRevision, 2)
        XCTAssertEqual(vm.items.map(\.id), ["n2", "n1", "a1", "a2"])
        XCTAssertEqual(passA.seen.filter { $0 == "buckets" }.count, 2, "two passes in all")
    }

    // MARK: Edge relaunch

    // AC-22: a month appears just under the range while a loadMore is in flight: it is loaded, not skipped.
    @MainActor
    func test_realtime_AC22_inFlightLoadMoreLoadsMonthAppearedBelow() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1", "a2"]), (rt5, ["c1"])])
        let gate = RTGate(target: rt5)
        mock.timelineGate = { await gate.pass($0) }
        let scroll = Task { await vm.loadMore() }
        await rtWaitUntil { gate.isWaiting }
        rtServe(mock, [(rt7, ["a1", "a2"]), (rt6, ["b1"]), (rt5, ["c1"])])
        let callsBefore = mock.timeBucketCalls.count

        await deliver(["on_upload_success"], to: vm)
        gate.open()
        await scroll.value

        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "b1"])
        XCTAssertEqual(vm.buckets[vm.bucketIndex].timeBucket, rt5)
        await vm.loadMore()
        XCTAssertEqual(vm.items.map(\.id), ["a1", "a2", "b1", "c1"])
        let keys = mock.timeBucketCalls.dropFirst(callsBefore).map(\.timeBucket)
        XCTAssertEqual(keys, [rt7, rt6, rt5], "05 was dropped once, then loaded after 06")
        XCTAssertEqual(mock.timeBucketCalls.filter { $0.timeBucket == rt5 }.count, 2)
    }

    // AC-22: a month appears just above the range while a loadNewer is in flight.
    @MainActor
    func test_realtime_AC22_inFlightLoadNewerLoadsMonthAppearedAbove() async {
        let mock = MockImmichClient()
        rtServe(mock, [(rt8, ["h1"]), (rt7, ["a1"]), (rt5, ["c1"])])
        let vm = TimelineViewModel(client: mock)
        await vm.jump(toDay: rt5)
        let gate = RTGate(target: rt7)
        mock.timelineGate = { await gate.pass($0) }
        let scroll = Task { await vm.loadNewer() }
        await rtWaitUntil { gate.isWaiting }
        rtServe(mock, [(rt8, ["h1"]), (rt7, ["a1"]), (rt6, ["b1"]), (rt5, ["c1"])])

        await deliver(["on_upload_success"], to: vm)
        gate.open()
        await scroll.value

        XCTAssertEqual(vm.items.map(\.id), ["b1", "c1"])
        XCTAssertEqual(vm.buckets[vm.upperBucketIndex].timeBucket, rt7)
    }

    // AC-22: the last photo of the last month is deleted: the next month is loaded.
    @MainActor
    func test_realtime_AC22_lastPhotoDeletedLoadsNextMonth() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1"]), (rt6, ["b1", "b2"]), (rt5, ["c1"])], scrolled: 1)
        XCTAssertEqual(vm.bucketIndex, 2)
        rtServe(mock, [(rt7, ["a1"]), (rt6, ["b1"]), (rt5, ["c1"])])

        await deliver(["on_asset_delete"], to: vm)

        XCTAssertEqual(vm.items.map(\.id), ["a1", "b1", "c1"])
        XCTAssertEqual(vm.bucketIndex, 3)
    }

    // AC-22: a month appears under an end that was already fully loaded.
    @MainActor
    func test_realtime_AC22_monthAppearedBelowExhaustedEndIsLoaded() async {
        let mock = MockImmichClient()
        let vm = await rtLoadedVM(mock, [(rt7, ["a1"])])
        XCTAssertFalse(vm.canLoadMore)
        rtServe(mock, [(rt7, ["a1"]), (rt3, ["z1"])])

        await deliver(["on_upload_success"], to: vm)

        XCTAssertEqual(vm.items.map(\.id), ["a1", "z1"])
        XCTAssertEqual(vm.bucketIndex, 2)
    }

    // AC-22: the first photo after a jump is deleted: the newer month is loaded in front.
    @MainActor
    func test_realtime_AC22_firstPhotoDeletedAfterJumpLoadsNewer() async {
        let mock = MockImmichClient()
        rtServe(mock, [(rt7, ["a1"]), (rt5, ["c1", "c2"])])
        let vm = TimelineViewModel(client: mock)
        await vm.jump(toDay: rt5)
        rtServe(mock, [(rt7, ["a1"]), (rt5, ["c2"])])

        await deliver(["on_asset_delete"], to: vm)

        XCTAssertEqual(vm.items.map(\.id), ["a1", "c2"])
        XCTAssertEqual(vm.upperBucketIndex, -1)
        XCTAssertEqual(vm.realtimeRevision, 2, "the pass, then the edge load")
    }
}
