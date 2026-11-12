import XCTest
@testable import ImmichSwiftUI

final class StacksViewModelTests: XCTestCase {

    private func asset(_ id: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2024-07-01T00:00:00.000Z",
            ownerId: "owner", originalPath: "/\(id).jpg", originalFileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", fileModifiedAt: "2024-07-01T00:00:00.000Z",
            updatedAt: "2024-07-01T00:00:00.000Z", isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    private func stack(id: String, primary: String, members: [String]) -> StackResponseDto {
        StackResponseDto(id: id, primaryAssetId: primary, assets: members.map(asset))
    }

    private func searchPage(ids: [String], nextPage: String?) -> SearchResponseDto {
        SearchResponseDto(
            assets: SearchAssetResponseDto(count: ids.count, items: ids.map(asset), nextPage: nextPage)
        )
    }

    @MainActor
    func test_loadStacks_mapsServerStacks() async {
        let mock = MockImmichClient()
        mock.stacksResponse = [stack(id: "s1", primary: "a1", members: ["a1", "a2"])]
        let vm = StacksViewModel(client: mock)

        await vm.loadStacks()

        XCTAssertEqual(vm.stacks.map(\.id), ["s1"])
        XCTAssertEqual(vm.stacks.first?.assets.count, 2)
        XCTAssertNil(vm.stacksLoadError)
    }

    @MainActor
    func test_loadStacks_failureSurfacesError() async {
        let mock = MockImmichClient()
        mock.stacksError = APIError.serverError(500, "boom")
        let vm = StacksViewModel(client: mock)

        await vm.loadStacks()

        XCTAssertTrue(vm.stacks.isEmpty)
        XCTAssertEqual(vm.stacksLoadError, UserFacingError.serverErrorMessage)
    }

    @MainActor
    func test_createStack_sendsIdsAndReloads() async {
        let mock = MockImmichClient()
        mock.stacksResponse = [stack(id: "s9", primary: "x", members: ["x", "y"])]
        let vm = StacksViewModel(client: mock)

        await vm.createStack(assetIds: ["x", "y"])

        XCTAssertEqual(mock.lastCreateStackIds, ["x", "y"])
        XCTAssertEqual(vm.stacks.map(\.id), ["s9"], "the hub list must show the new stack")
    }

    /// The server rejects fewer than 2 ids (`StackCreateDto.assetIds` has
    /// `.min(2)`) — the VM must not spend a round trip on a doomed request.
    @MainActor
    func test_createStack_singleIdIsRejectedLocally() async {
        let mock = MockImmichClient()
        let vm = StacksViewModel(client: mock)

        await vm.createStack(assetIds: ["only-one"])

        XCTAssertNil(mock.lastCreateStackIds)
        XCTAssertEqual(mock.requestCount, 0)
    }

    @MainActor
    func test_createStack_failureKeepsFlowOpen() async {
        let mock = MockImmichClient()
        mock.stacksError = APIError.serverError(400, "nope")
        let vm = StacksViewModel(client: mock)
        vm.showCreate = true
        vm.selectedIds = ["x", "y"]

        await vm.createStack(assetIds: ["x", "y"])

        XCTAssertTrue(vm.showCreate, "a failed create must leave the picker up")
        XCTAssertEqual(vm.selectedIds, ["x", "y"], "and keep the selection")
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
    }

    @MainActor
    func test_deleteStack_removesItFromTheList() async {
        let mock = MockImmichClient()
        mock.stacksResponse = [
            stack(id: "s1", primary: "a1", members: ["a1", "a2"]),
            stack(id: "s2", primary: "b1", members: ["b1", "b2"])
        ]
        let vm = StacksViewModel(client: mock)
        await vm.loadStacks()

        await vm.deleteStack(id: "s1")

        XCTAssertEqual(mock.lastDeleteStackId, "s1")
        XCTAssertEqual(vm.stacks.map(\.id), ["s2"])
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_updatePrimary_sendsAssetIdAndRefreshesCover() async {
        let mock = MockImmichClient()
        mock.stacksResponse = [stack(id: "s1", primary: "a1", members: ["a1", "a2"])]
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a2", members: ["a2", "a1"])
        mock.updateStackResponse = stack(id: "s1", primary: "a2", members: ["a2", "a1"])
        let vm = StacksViewModel(client: mock)
        await vm.loadStacks()

        await vm.updatePrimary(stackId: "s1", assetId: "a2")

        XCTAssertEqual(mock.lastUpdateStackId, "s1")
        XCTAssertEqual(mock.lastUpdateStackPrimaryId, "a2")
        XCTAssertEqual(vm.selectedStack?.primaryAssetId, "a2")
        XCTAssertEqual(vm.stacks.first?.primaryAssetId, "a2", "the hub row shows the new cover")
    }

    @MainActor
    func test_removeAssetFromStack_sendsIdsAndReloadsStack() async {
        let mock = MockImmichClient()
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1"])
        let vm = StacksViewModel(client: mock)

        await vm.removeAssetFromStack(stackId: "s1", assetId: "a2")

        XCTAssertEqual(mock.lastRemoveFromStackId, "s1")
        XCTAssertEqual(mock.lastRemoveFromStackAssetId, "a2")
        XCTAssertEqual(vm.selectedStack?.assets.count, 1)
    }

    @MainActor
    func test_loadStack_keepsSelectedStack() async {
        let mock = MockImmichClient()
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2", "a3"])
        let vm = StacksViewModel(client: mock)

        await vm.loadStack(id: "s1")

        XCTAssertEqual(vm.selectedStack?.id, "s1")
        XCTAssertEqual(vm.selectedStack?.assets.count, 3)
    }

    @MainActor
    func test_loadStack_failureLeavesNothingToShow() async {
        let mock = MockImmichClient()
        mock.stacksError = APIError.serverError(404, "gone")
        let vm = StacksViewModel(client: mock)

        await vm.loadStack(id: "s1")

        XCTAssertNil(vm.selectedStack, "the detail screen renders its error state")
        XCTAssertEqual(vm.stackLoadError, UserFacingError.genericMessage)
    }

    // MARK: - Create picker

    @MainActor
    func test_beginPicking_loadsFirstPageAndClearsSelection() async {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = searchPage(ids: ["a1", "a2", "a3"], nextPage: nil)
        let vm = StacksViewModel(client: mock)
        vm.selectedIds = ["stale"]

        await vm.beginPicking()

        XCTAssertEqual(vm.recentAssets.map(\.id), ["a1", "a2", "a3"])
        XCTAssertTrue(vm.selectedIds.isEmpty, "reopening the picker must not resurrect an old selection")
        XCTAssertEqual(mock.lastMetadataSearchDto?.order, "desc", "newest first")
    }

    @MainActor
    func test_loadMoreAssets_pagesAndDedupes() async {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = searchPage(ids: ["a1", "a2"], nextPage: "2")
        let vm = StacksViewModel(client: mock)
        await vm.beginPicking()
        XCTAssertTrue(vm.canLoadMoreAssets)

        // Second page repeats a1 (the library can shift between pages).
        mock.searchMetadataResponse = searchPage(ids: ["a1", "a3"], nextPage: nil)
        await vm.loadMoreAssets()

        XCTAssertEqual(vm.recentAssets.map(\.id), ["a1", "a2", "a3"])
        XCTAssertFalse(vm.canLoadMoreAssets, "no next page left")
    }

    @MainActor
    func test_toggleSelection_isSymmetric() async {
        let mock = MockImmichClient()
        let vm = StacksViewModel(client: mock)

        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")
        XCTAssertEqual(vm.selectedIds, ["a1", "a2"])

        vm.toggleSelection(id: "a1")
        XCTAssertEqual(vm.selectedIds, ["a2"])
    }

    /// The selection must reach the wire in grid order: `POST /api/stacks` makes
    /// the first id the cover, and `Set` iteration order is not stable.
    @MainActor
    func test_orderedSelection_followsGridOrderNotSetOrder() async {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = searchPage(ids: ["newest", "middle", "oldest"], nextPage: nil)
        let vm = StacksViewModel(client: mock)
        await vm.beginPicking()

        vm.toggleSelection(id: "oldest")
        vm.toggleSelection(id: "newest")

        XCTAssertEqual(vm.orderedSelection, ["newest", "oldest"])
    }

    // MARK: - Adding photos to an existing stack

    /// No "add asset to stack" route exists, so extending a stack re-posts
    /// `POST /api/stacks`. The stack's **current cover must lead the payload**:
    /// the server makes `assetIds[0]` the primary, so putting the new photos
    /// first would silently steal the cover.
    @MainActor
    func test_addPhotos_postsCurrentCoverFirst() async {
        let mock = MockImmichClient()
        let vm = StacksViewModel(client: mock)

        _ = await vm.addPhotos(toStackId: "s1", primaryAssetId: "cover", assetIds: ["x", "y"])

        XCTAssertEqual(mock.lastCreateStackIds, ["cover", "x", "y"])
    }

    /// `StackRepository.create` deletes the old stack and inserts a new one, so
    /// the id always changes — the caller has to follow it, and the hub must stop
    /// showing the dead row.
    @MainActor
    func test_addPhotos_returnsNewIdAndDropsDeadRow() async {
        let mock = MockImmichClient()
        mock.stacksResponse = [stack(id: "old", primary: "cover", members: ["cover", "a2"])]
        let vm = StacksViewModel(client: mock)
        await vm.loadStacks()

        // What the server holds once the merge landed: `old` deleted, `new` in
        // its place with the extra member.
        mock.createStackResponse = stack(id: "new", primary: "cover", members: ["cover", "a2", "x"])
        mock.stacksResponse = [stack(id: "new", primary: "cover", members: ["cover", "a2", "x"])]

        let newID = await vm.addPhotos(toStackId: "old", primaryAssetId: "cover", assetIds: ["x"])

        XCTAssertEqual(newID, "new")
        XCTAssertEqual(vm.selectedStack?.id, "new", "the detail screen follows the new id")
        XCTAssertEqual(vm.selectedStack?.assets.count, 3)
        XCTAssertEqual(vm.selectedStack?.primaryAssetId, "cover", "the cover is untouched")
        XCTAssertEqual(vm.stacks.map(\.id), ["new"], "the stale row is gone")
    }

    /// Re-posting a photo the stack already holds would re-create it for
    /// nothing; the cover alone is a 1-id payload the server rejects.
    @MainActor
    func test_addPhotos_onlyTheCoverIsNotSent() async {
        let mock = MockImmichClient()
        let vm = StacksViewModel(client: mock)

        let result = await vm.addPhotos(toStackId: "s1", primaryAssetId: "cover", assetIds: ["cover"])

        XCTAssertNil(result)
        XCTAssertNil(mock.lastCreateStackIds)
        XCTAssertEqual(mock.requestCount, 0)
    }

    @MainActor
    func test_addPhotos_failureKeepsStackAndReportsError() async {
        let mock = MockImmichClient()
        mock.stacksError = APIError.serverError(400, "nope")
        let vm = StacksViewModel(client: mock)
        vm.selectedStack = stack(id: "old", primary: "cover", members: ["cover", "a2"])

        let result = await vm.addPhotos(toStackId: "old", primaryAssetId: "cover", assetIds: ["x"])

        XCTAssertNil(result, "the sheet stays open on failure")
        XCTAssertEqual(vm.selectedStack?.id, "old", "and the screen still shows the stack")
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
    }

    // MARK: - List states (L-16)

    private let serverError = APIError.serverError(500, "x")

    /// Holds the first request of a route on `latch`; later ones pass.
    private func holdingFirstCall(_ latch: TestLatch) -> (() async throws -> Void) {
        let calls = TestBox(0)
        return {
            calls.value += 1
            if calls.value == 1 { try await latch.wait() }
        }
    }

    @MainActor
    func test_AC_142_stacks_loadingUntilFirstAnswer() async {
        let mock = MockImmichClient()
        mock.stacksResponse = [stack(id: "s1", primary: "a1", members: ["a1", "a2"])]
        let latch = TestLatch()
        mock.stacksGate = { try await latch.wait() }
        let vm = StacksViewModel(client: mock)
        XCTAssertEqual(vm.stacksState, .loading)

        let read = Task { @MainActor in await vm.loadStacks() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.stacksState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.stacksState, .data(.idle))
    }

    @MainActor
    func test_AC_149_stacks_firstReadFailsShowsErrorNotEmpty() async {
        let mock = MockImmichClient()
        mock.stacksError = serverError
        let vm = StacksViewModel(client: mock)

        await vm.loadStacks()

        XCTAssertEqual(vm.stacksState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.stacksHasLoaded)
        XCTAssertTrue(vm.stacks.isEmpty)
        XCTAssertNil(vm.errorMessage, "the read never writes the action error")
    }

    @MainActor
    func test_AC_149_stacks_successfulEmptyReadIsEmpty() async {
        let vm = StacksViewModel(client: MockImmichClient())

        await vm.loadStacks()

        XCTAssertEqual(vm.stacksState, .empty)
        XCTAssertTrue(vm.stacksHasLoaded)
    }

    @MainActor
    func test_AC_149_stacks_retryShowsLoadingThenData() async {
        let mock = MockImmichClient()
        mock.stacksError = serverError
        let vm = StacksViewModel(client: mock)
        await vm.loadStacks()
        mock.stacksError = nil
        mock.stacksResponse = [stack(id: "s1", primary: "a1", members: ["a1", "a2"])]
        let latch = TestLatch()
        mock.stacksGate = { try await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.loadStacks(force: true) }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isLoadingStacks)
        XCTAssertFalse(vm.isRefreshingStacks)
        XCTAssertEqual(vm.stacksState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.stacksState, .data(.idle))
        XCTAssertEqual(vm.stacks.map(\.id), ["s1"])
    }

    @MainActor
    func test_AC_152_stacks_refreshFailureKeepsDataThenRetryClears() async {
        let mock = MockImmichClient()
        mock.stacksResponse = [stack(id: "s1", primary: "a1", members: ["a1", "a2"])]
        let vm = StacksViewModel(client: mock)
        await vm.loadStacks()

        mock.stacksError = serverError
        await vm.refreshStacks()

        XCTAssertEqual(vm.stacksState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.stacks.map(\.id), ["s1"])

        mock.stacksError = nil
        await vm.loadStacks(force: true)
        XCTAssertEqual(vm.stacksState, .data(.idle))
    }

    @MainActor
    func test_AC_154_stacks_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        let vm = StacksViewModel(client: mock)
        await vm.loadStacks()
        XCTAssertEqual(vm.stacksState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        mock.stacksGate = { try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refreshStacks() }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 1 }
        XCTAssertTrue(vm.isRefreshingStacks)
        XCTAssertEqual(vm.stacksState, .empty)
        mock.stacksResponse = [stack(id: "s1", primary: "a1", members: ["a1", "a2"])]
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshingStacks)
        XCTAssertEqual(vm.stacksState, .data(.idle))

        // From the error state.
        mock.stacksGate = nil
        mock.stacksResponse = nil
        let failing = StacksViewModel(client: mock)
        mock.stacksError = serverError
        await failing.loadStacks()
        XCTAssertEqual(failing.stacksState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        mock.stacksGate = { try await errorLatch.wait() }
        mock.stacksResponse = [stack(id: "s1", primary: "a1", members: ["a1", "a2"])]
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refreshStacks() }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 1 }
        XCTAssertTrue(failing.isRefreshingStacks)
        XCTAssertEqual(failing.stacksState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        mock.stacksError = nil
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.stacksState, .data(.idle))
    }

    @MainActor
    func test_AC_154_stacks_refreshDuringReadIsNotIgnored() async {
        let mock = MockImmichClient()
        mock.stacksResponse = [stack(id: "s1", primary: "a1", members: ["a1", "a2"])]
        let latch = TestLatch()
        mock.stacksGate = holdingFirstCall(latch)
        let vm = StacksViewModel(client: mock)

        let first = Task { @MainActor in await vm.loadStacks() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }
        await vm.refreshStacks()
        XCTAssertEqual(mock.requestCount, 2, "a pull during a read is a request of its own")
        XCTAssertEqual(vm.stacksState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.stacksError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.stacksState, .data(.idle))
        XCTAssertFalse(vm.isLoadingStacks)
    }

    @MainActor
    func test_AC_149_stacks_actionErrorDoesNotSetTheReadError() async {
        let mock = MockImmichClient()
        mock.stacksResponse = [stack(id: "s1", primary: "a1", members: ["a1", "a2"])]
        let vm = StacksViewModel(client: mock)
        await vm.loadStacks()

        mock.stacksError = serverError
        await vm.updatePrimary(stackId: "s1", assetId: "a2")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.stacksLoadError)
        XCTAssertEqual(vm.stacksState, .data(.idle))
    }

    @MainActor
    func test_AC_160_stacks_failureIsErrorAndRefreshFailureKeepsStacks() async {
        let mock = MockImmichClient()
        mock.stacksError = serverError
        let vm = StacksViewModel(client: mock)

        await vm.loadStacks()
        XCTAssertEqual(vm.stacksState, .error(UserFacingError.serverErrorMessage), "never the empty state")

        mock.stacksError = nil
        mock.stacksResponse = [stack(id: "s1", primary: "a1", members: ["a1", "a2"])]
        await vm.loadStacks(force: true)
        XCTAssertEqual(vm.stacksState, .data(.idle))

        mock.stacksError = serverError
        await vm.refreshStacks()
        XCTAssertEqual(vm.stacksState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.stacks.map(\.id), ["s1"])
    }

    // MARK: - Detail states (L-16)

    @MainActor
    func test_AC_142_stackDetail_loadingUntilFirstAnswer() async {
        let mock = MockImmichClient()
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2"])
        let latch = TestLatch()
        mock.stackGate = { try await latch.wait() }
        let vm = StacksViewModel(client: mock)
        XCTAssertEqual(vm.stackState, .loading)

        let read = Task { @MainActor in await vm.loadStack(id: "s1") }
        await pollUntil("first read in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.stackState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.stackState, .data(.idle))
        XCTAssertEqual(vm.selectedStack?.id, "s1")
    }

    @MainActor
    func test_AC_154_stackDetail_otherStackIsLoadingNotTheStaleOne() async {
        let mock = MockImmichClient()
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2"])
        let vm = StacksViewModel(client: mock)
        await vm.loadStack(id: "s1")
        let latch = TestLatch()
        mock.stackGate = { try await latch.wait() }
        let before = mock.requestCount

        let read = Task { @MainActor in await vm.loadStack(id: "s2") }
        await pollUntil("second stack read in flight") { mock.requestCount == before + 1 }

        XCTAssertEqual(vm.stackState, .loading, "s1 is not the stack asked for")
        latch.open()
        await read.value
        XCTAssertEqual(vm.stackState, .data(.idle))
        XCTAssertEqual(vm.selectedStack?.id, "s2")
    }

    @MainActor
    func test_AC_154_stackDetail_firstReadFailsShowsErrorNotEmpty() async {
        let mock = MockImmichClient()
        mock.stacksError = serverError
        let vm = StacksViewModel(client: mock)

        await vm.loadStack(id: "s1")

        XCTAssertEqual(vm.stackState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.stackHasLoaded)
        XCTAssertNil(vm.selectedStack)
        XCTAssertNil(vm.errorMessage, "the read never writes the action error")
    }

    @MainActor
    func test_AC_154_stackDetail_unstackedStackIsEmpty() async {
        let mock = MockImmichClient()
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2"])
        let vm = StacksViewModel(client: mock)
        await vm.loadStack(id: "s1")

        await vm.deleteStack(id: "s1")

        XCTAssertNil(vm.selectedStack)
        XCTAssertEqual(vm.stackState, .empty)
    }

    @MainActor
    func test_AC_154_stackDetail_retryShowsLoadingThenData() async {
        let mock = MockImmichClient()
        mock.stacksError = serverError
        let vm = StacksViewModel(client: mock)
        await vm.loadStack(id: "s1")
        mock.stacksError = nil
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2"])
        let latch = TestLatch()
        mock.stackGate = { try await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.loadStack(id: "s1", force: true) }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isLoadingStack)
        XCTAssertFalse(vm.isRefreshingStack)
        XCTAssertEqual(vm.stackState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.stackState, .data(.idle))
    }

    @MainActor
    func test_AC_154_stackDetail_refreshFailureKeepsStackThenRetryClears() async {
        let mock = MockImmichClient()
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2"])
        let vm = StacksViewModel(client: mock)
        await vm.loadStack(id: "s1")

        mock.stacksError = serverError
        await vm.refreshStack(id: "s1")

        XCTAssertEqual(vm.stackState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.selectedStack?.assets.count, 2)

        mock.stacksError = nil
        await vm.loadStack(id: "s1", force: true)
        XCTAssertEqual(vm.stackState, .data(.idle))
    }

    @MainActor
    func test_AC_154_stackDetail_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2"])
        let vm = StacksViewModel(client: mock)
        await vm.loadStack(id: "s1")
        await vm.deleteStack(id: "s1")
        XCTAssertEqual(vm.stackState, .empty)

        // From the empty state (the stack is gone, then back).
        let emptyLatch = TestLatch()
        mock.stackGate = { try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refreshStack(id: "s1") }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 1 }
        XCTAssertTrue(vm.isRefreshingStack)
        XCTAssertEqual(vm.stackState, .empty)
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshingStack)
        XCTAssertEqual(vm.stackState, .data(.idle))

        // From the error state.
        mock.stackGate = nil
        let failing = StacksViewModel(client: mock)
        mock.stacksError = serverError
        await failing.loadStack(id: "s1")
        XCTAssertEqual(failing.stackState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        mock.stackGate = { try await errorLatch.wait() }
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refreshStack(id: "s1") }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 1 }
        XCTAssertTrue(failing.isRefreshingStack)
        XCTAssertEqual(failing.stackState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        mock.stacksError = nil
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.stackState, .data(.idle))
    }

    @MainActor
    func test_AC_154_stackDetail_refreshDuringReadIsNotIgnored() async {
        let mock = MockImmichClient()
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2"])
        let latch = TestLatch()
        mock.stackGate = holdingFirstCall(latch)
        let vm = StacksViewModel(client: mock)

        let first = Task { @MainActor in await vm.loadStack(id: "s1") }
        await pollUntil("first read in flight") { mock.requestCount == 1 }
        await vm.refreshStack(id: "s1")
        XCTAssertEqual(mock.requestCount, 2, "a pull during a read is a request of its own")
        XCTAssertEqual(vm.stackState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.stacksError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.stackState, .data(.idle))
        XCTAssertFalse(vm.isLoadingStack)
    }

    @MainActor
    func test_AC_156_stackDetail_refreshReloadsStack() async {
        let mock = MockImmichClient()
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2"])
        let vm = StacksViewModel(client: mock)
        await vm.loadStack(id: "s1")
        XCTAssertEqual(vm.selectedStack?.assets.count, 2)
        let before = mock.requestCount

        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2", "a3"])
        await vm.refreshStack(id: "s1")

        XCTAssertEqual(mock.requestCount, before + 1)
        XCTAssertEqual(vm.selectedStack?.assets.count, 3)
        XCTAssertEqual(vm.stackState, .data(.idle))
        XCTAssertFalse(vm.isRefreshingStack)
    }

    @MainActor
    func test_AC_154_stackDetail_actionErrorDoesNotSetTheReadError() async {
        let mock = MockImmichClient()
        mock.stackDetailResponses["s1"] = stack(id: "s1", primary: "a1", members: ["a1", "a2"])
        let vm = StacksViewModel(client: mock)
        await vm.loadStack(id: "s1")

        mock.stacksError = serverError
        await vm.updatePrimary(stackId: "s1", assetId: "a2")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.stackLoadError)
        XCTAssertEqual(vm.stackState, .data(.idle))
    }
}
