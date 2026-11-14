import XCTest
@testable import ImmichSwiftUI

/// L-23b — the multi-selection of the search results and the batch actions it
/// reuses from the timeline: what stays selected across pages, which requests
/// leave for each action, what the grid shows afterwards, and the read-only
/// refusal. Assertions read what the mock captured, not the view model's wiring.
@MainActor
final class SearchSelectionTests: XCTestCase {

    // MARK: - Helpers

    private func asset(
        _ id: String,
        favorite: Bool = false,
        visibility: String = "timeline",
        owner: String = "me"
    ) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T00:00:00.000Z", ownerId: owner,
            originalPath: "/\(id).jpg", originalFileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            updatedAt: "2024-07-01T00:00:00.000Z",
            isFavorite: favorite, isArchived: visibility == "archive", isTrashed: false,
            isOffline: false, visibility: visibility, checksum: "x", isEdited: false,
            exifInfo: nil
        )
    }

    private func page(_ items: [AssetResponseDto], nextPage: String? = nil) -> SearchResponseDto {
        SearchResponseDto(assets: SearchAssetResponseDto(count: items.count, items: items, nextPage: nextPage))
    }

    /// A search view model that has already run a search whose answer is `items`.
    private func searched(
        _ items: [AssetResponseDto],
        nextPage: String? = nil,
        client: ((MockImmichClient) -> any ImmichClient)? = nil
    ) async -> (vm: SearchViewModel, mock: MockImmichClient) {
        let mock = MockImmichClient()
        mock.smartSearchResponse = page(items, nextPage: nextPage)
        mock.searchMetadataResponse = page(items, nextPage: nextPage)
        let vm = SearchViewModel(client: client?(mock) ?? mock)
        vm.query = "plage"
        await vm.search()
        return (vm, mock)
    }

    private func selectAll(_ vm: SearchViewModel, _ ids: [String]) {
        vm.enterSelectionMode()
        ids.forEach { vm.toggleSelection(id: $0) }
    }

    // MARK: - AC-216: selecting

    func test_AC_216_selectionSurvivesNextPageAndCancelClears() async {
        let (vm, mock) = await searched([asset("p1"), asset("p2")], nextPage: "2")
        vm.enterSelectionMode()
        vm.toggleSelection(id: "p1")
        XCTAssertEqual(vm.selectedIds, ["p1"])

        mock.smartSearchResponse = page([asset("p3"), asset("p4")])
        await vm.loadMore()
        vm.toggleSelection(id: "p3")

        XCTAssertEqual(vm.results.map(\.id), ["p1", "p2", "p3", "p4"])
        XCTAssertEqual(vm.selectedIds, ["p1", "p3"], "the first page's selection survives the next page")
        XCTAssertTrue(vm.selectionMode)

        vm.exitSelectionMode()
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    func test_AC_216_toggleUnchecksAndANewSearchLeavesSelection() async {
        let (vm, _) = await searched([asset("p1"), asset("p2")])
        selectAll(vm, ["p1", "p2"])
        vm.toggleSelection(id: "p2")
        XCTAssertEqual(vm.selectedIds, ["p1"], "a second touch unchecks")

        vm.query = "montagne"
        await vm.search()

        XCTAssertFalse(vm.selectionMode, "rows that are gone cannot stay selected")
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    func test_AC_216_selectedItemsFollowGridOrder() async {
        let (vm, _) = await searched([asset("p1"), asset("p2"), asset("p3")])
        selectAll(vm, ["p3", "p1"])
        XCTAssertEqual(vm.selectedItems.map(\.id), ["p1", "p3"])
    }

    // MARK: - AC-44 / AC-219: favourites

    func test_AC_219_favouriteSendsOneRequestPerPhotoThatChanges() async {
        let (vm, mock) = await searched([asset("p1"), asset("p2"), asset("p3")])
        selectAll(vm, ["p1", "p2", "p3"])
        XCTAssertEqual(vm.selectedIds.count, 3)

        await vm.favoriteSelected(currentUserId: "me")

        XCTAssertEqual(Set(mock.updateAssetCalls.map(\.id)), ["p1", "p2", "p3"])
        XCTAssertEqual(mock.updateAssetCalls.count, 3, "one request per photo, as the timeline does")
        XCTAssertTrue(mock.updateAssetCalls.allSatisfy { $0.dto.isFavorite == true })
        XCTAssertTrue(vm.results.allSatisfy(\.isFavorite))
        XCTAssertFalse(vm.selectionMode, "the heart closes the selection, as on the timeline")
    }

    func test_AC_219_alreadyFavouritePhotosAreNotSentAgain() async {
        let (vm, mock) = await searched([asset("p1", favorite: true), asset("p2", favorite: true), asset("p3")])
        selectAll(vm, ["p1", "p2", "p3"])

        await vm.favoriteSelected(currentUserId: "me")

        XCTAssertEqual(mock.updateAssetCalls.map(\.id), ["p3"])
    }

    func test_AC_44_threeSelectedKeepTheirIdsForTheAlbumStep() async {
        let (vm, mock) = await searched([asset("p1"), asset("p2"), asset("p3"), asset("p4")])
        selectAll(vm, ["p1", "p2", "p3"])
        XCTAssertEqual(vm.selectedIds.count, 3, "the title reads the count of this set")

        await vm.favoriteSelected(currentUserId: "me")
        XCTAssertEqual(mock.updateAssetCalls.count, 3)

        // The album sheet receives `selectedIds`: select the same three again.
        selectAll(vm, ["p1", "p2", "p3"])
        XCTAssertEqual(vm.selectedIds, ["p1", "p2", "p3"])
    }

    func test_AC_219_favouritesFilterDropsRowsThatNoLongerMatch() async {
        let (vm, _) = await searched([asset("p1", favorite: true), asset("p2", favorite: true)])
        vm.filter.isFavorite = true
        selectAll(vm, ["p1", "p2"])

        await vm.favoriteSelected(currentUserId: "me")

        XCTAssertTrue(vm.results.isEmpty, "un-favourited rows leave a grid filtered on favourites")
    }

    // MARK: - AC-217: archive, trash, locked folder, stack

    func test_AC_217_archiveSendsOneBatchAndRowsLeave() async {
        let (vm, mock) = await searched([asset("p1"), asset("p2"), asset("p3")])
        selectAll(vm, ["p1", "p2"])
        XCTAssertFalse(vm.selectionOffersUnarchive)

        await vm.archiveSelected(currentUserId: "me")

        let dto = mock.lastBulkUpdateDto
        XCTAssertEqual(Set(dto?.ids ?? []), ["p1", "p2"])
        XCTAssertEqual(dto?.visibility, .archive)
        XCTAssertEqual(vm.results.map(\.id), ["p3"])
        XCTAssertFalse(vm.selectionMode)
    }

    func test_AC_217_archiveOptionOffersUnarchiveAndRowsLeave() async {
        let (vm, mock) = await searched([asset("a1", visibility: "archive"), asset("a2", visibility: "archive"), asset("a3", visibility: "archive")])
        vm.filter.isArchived = true
        selectAll(vm, ["a1", "a2"])
        XCTAssertTrue(vm.selectionOffersUnarchive)

        await vm.unarchiveSelected()

        let dto = mock.lastBulkUpdateDto
        XCTAssertEqual(Set(dto?.ids ?? []), ["a1", "a2"])
        XCTAssertEqual(dto?.visibility, .timeline)
        XCTAssertEqual(vm.results.map(\.id), ["a3"], "unarchived photos leave a grid of archived ones")
    }

    func test_AC_217_onlyArchivedSelectionOffersUnarchive() async {
        let (vm, _) = await searched([asset("a1", visibility: "archive"), asset("p2")])
        selectAll(vm, ["a1"])
        XCTAssertTrue(vm.selectionOffersUnarchive)
        vm.toggleSelection(id: "p2")
        XCTAssertFalse(vm.selectionOffersUnarchive, "one live photo brings Archive back")
    }

    func test_AC_217_trashSendsTheTimelineRequestAndRowsLeave() async {
        let (vm, mock) = await searched([asset("p1"), asset("p2"), asset("p3")])
        selectAll(vm, ["p1", "p2"])

        await vm.deleteSelected(currentUserId: "me")

        XCTAssertEqual(Set(mock.lastDeleteBody?.ids ?? []), ["p1", "p2"])
        XCTAssertEqual(mock.lastDeleteBody?.force, false, "the bin, not a permanent delete")
        XCTAssertEqual(vm.results.map(\.id), ["p3"])
    }

    func test_AC_217_lockedFolderSendsLockedVisibilityAndRowsLeave() async {
        let (vm, mock) = await searched([asset("p1"), asset("p2")])
        selectAll(vm, ["p1"])

        await vm.moveSelectedToLockedFolder(currentUserId: "me")

        XCTAssertEqual(mock.lastBulkUpdateDto?.ids, ["p1"])
        XCTAssertEqual(mock.lastBulkUpdateDto?.visibility, .locked)
        XCTAssertEqual(vm.results.map(\.id), ["p2"])
    }

    func test_AC_217_stackSendsGridOrderAndRereadsTheSearchNotTheTimeline() async {
        let (vm, mock) = await searched([asset("p1"), asset("p2"), asset("p3")])
        let searchesBefore = mock.searchSmartCalls.count
        selectAll(vm, ["p3", "p1"])

        await vm.stackSelected(currentUserId: "me")

        XCTAssertEqual(mock.lastCreateStackIds, ["p1", "p3"], "the cover is the first of the grid order")
        XCTAssertFalse(vm.selectionMode)
        XCTAssertEqual(vm.results.map(\.id), ["p1", "p2", "p3"], "the grid still shows search results")
        XCTAssertEqual(mock.searchSmartCalls.count, searchesBefore + 1, "the search ran again, not the timeline")
    }

    func test_AC_217_partnerPhotosAreNotSentAndAreReported() async {
        let (vm, mock) = await searched([asset("p1"), asset("x1", owner: "partner")])
        selectAll(vm, ["p1", "x1"])

        await vm.archiveSelected(currentUserId: "me")

        XCTAssertEqual(mock.lastBulkUpdateDto?.ids, ["p1"])
        XCTAssertEqual(vm.skippedPartnerCount, 1)
        XCTAssertEqual(vm.results.map(\.id), ["x1"])
    }

    func test_AC_217_serverRefusalKeepsRowsAndSelection() async {
        let (vm, mock) = await searched([asset("p1"), asset("p2")])
        selectAll(vm, ["p1"])
        mock.globalError = APIError.serverError(500, "boom")

        await vm.archiveSelected(currentUserId: "me")

        XCTAssertNotNil(vm.actionErrorMessage)
        XCTAssertEqual(vm.results.map(\.id), ["p1", "p2"])
        XCTAssertEqual(vm.selectedIds, ["p1"])
        XCTAssertTrue(vm.selectionMode)
    }

    func test_AC_217_readOnlyModeSendsNothingAndShowsTheTimelineRefusal() async {
        // Reads pass the guard (the search itself ran); every write is refused.
        let (vm, mock) = await searched(
            [asset("p1"), asset("p2")],
            client: { ReadOnlyGuardClient(inner: $0, isEnabled: { true }) }
        )
        selectAll(vm, ["p1", "p2"])

        await vm.archiveSelected(currentUserId: "me")
        XCTAssertEqual(vm.actionErrorMessage, UserFacingError.readOnlyModeMessage)
        vm.actionErrorMessage = nil
        await vm.deleteSelected(currentUserId: "me")
        XCTAssertEqual(vm.actionErrorMessage, UserFacingError.readOnlyModeMessage)
        vm.actionErrorMessage = nil
        await vm.favoriteSelected(currentUserId: "me")
        XCTAssertEqual(vm.actionErrorMessage, UserFacingError.readOnlyModeMessage)

        XCTAssertNil(mock.lastBulkUpdateDto)
        XCTAssertNil(mock.lastDeleteBody)
        XCTAssertTrue(mock.updateAssetCalls.isEmpty)
        XCTAssertEqual(vm.results.map(\.id), ["p1", "p2"])
        XCTAssertTrue(vm.selectionMode, "a refused action keeps the selection")
    }
}
