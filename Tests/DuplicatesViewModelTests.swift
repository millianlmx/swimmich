import XCTest
@testable import ImmichSwiftUI

final class DuplicatesViewModelTests: XCTestCase {

    private func makeGroup(id: String, ids: [String], suggested: [String]) -> DuplicateResponseDto {
        let assets = ids.map { assetID in
            AssetResponseDto(
                id: assetID, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
                duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2024-07-01T00:00:00.000Z",
                ownerId: "owner", originalPath: "/\(assetID).jpg", originalFileName: "\(assetID).jpg",
                fileCreatedAt: "2024-07-01T00:00:00.000Z", fileModifiedAt: "2024-07-01T00:00:00.000Z",
                updatedAt: "2024-07-01T00:00:00.000Z", isFavorite: false, isArchived: false,
                isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false
            )
        }
        return DuplicateResponseDto(duplicateId: id, assets: assets, suggestedKeepAssetIds: suggested)
    }

    @MainActor
    func test_load_mapsServerGroups() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        let vm = DuplicatesViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.groups.count, 1)
        XCTAssertEqual(vm.groups.first?.duplicateId, "g1")
        XCTAssertNil(vm.loadErrorMessage)
    }

    @MainActor
    func test_load_failure_setsError() async {
        let mock = MockImmichClient()
        let vm = DuplicatesViewModel(client: mock)

        mock.globalError = APIError.serverError(500, "boom")
        await vm.load()

        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertEqual(vm.loadErrorMessage, UserFacingError.serverErrorMessage)
    }

    @MainActor
    func test_load_emptyKeepsEmpty() async {
        let mock = MockImmichClient()
        let vm = DuplicatesViewModel(client: mock)

        await vm.load()

        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertNil(vm.loadErrorMessage)
    }

    @MainActor
    func test_deletableIds_excludesSuggestedKeep() async {
        let mock = MockImmichClient()
        let vm = DuplicatesViewModel(client: mock)
        let group = makeGroup(id: "g1", ids: ["a1", "a2", "a3"], suggested: ["a2"])

        XCTAssertEqual(vm.deletableIds(for: group), ["a1", "a3"])
    }

    @MainActor
    func test_deleteGroup_sendsOnlyNonKeepIds() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2", "a3"], suggested: ["a2"])]
        let vm = DuplicatesViewModel(client: mock)
        await vm.load()

        await vm.deleteGroup(id: "g1")

        let deleted = Set(mock.lastDeleteBody?.ids ?? [])
        XCTAssertEqual(deleted, ["a1", "a3"])
        XCTAssertEqual(mock.lastDeleteBody?.force, false)
        XCTAssertTrue(vm.groups.isEmpty)
    }

    @MainActor
    func test_deleteGroup_failureKeepsGroup() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        let vm = DuplicatesViewModel(client: mock)
        await vm.load()

        mock.globalError = APIError.serverError(500, "boom")
        await vm.deleteGroup(id: "g1")

        XCTAssertEqual(vm.groups.count, 1)
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
    }

    @MainActor
    func test_deleteGroup_allSuggestedIsLocalNoOp() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1"], suggested: ["a1"])]
        let vm = DuplicatesViewModel(client: mock)
        await vm.load()

        await vm.deleteGroup(id: "g1")

        XCTAssertNil(mock.lastDeleteBody)
        XCTAssertTrue(vm.groups.isEmpty)
    }

    @MainActor
    func test_deleteGroup_unknownIdIsNoOp() async {
        let mock = MockImmichClient()
        let vm = DuplicatesViewModel(client: mock)

        await vm.deleteGroup(id: "ghost")

        XCTAssertNil(mock.lastDeleteBody)
        XCTAssertTrue(vm.groups.isEmpty)
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
    func test_AC_142_duplicates_loadingUntilFirstAnswer() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        let latch = TestLatch()
        mock.duplicatesGate = { try await latch.wait() }
        let vm = DuplicatesViewModel(client: mock)
        XCTAssertEqual(vm.renderState, .loading)

        let read = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_149_duplicates_firstReadFailsShowsErrorNotEmpty() async {
        let mock = MockImmichClient()
        mock.duplicatesError = serverError
        let vm = DuplicatesViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertNil(vm.errorMessage, "the read never writes the action error")
    }

    @MainActor
    func test_AC_149_duplicates_successfulEmptyReadIsEmpty() async {
        let vm = DuplicatesViewModel(client: MockImmichClient())

        await vm.load()

        XCTAssertEqual(vm.renderState, .empty)
        XCTAssertTrue(vm.hasLoaded)
    }

    @MainActor
    func test_AC_149_duplicates_retryShowsLoadingThenData() async {
        let mock = MockImmichClient()
        mock.duplicatesError = serverError
        let vm = DuplicatesViewModel(client: mock)
        await vm.load()
        mock.duplicatesError = nil
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        let latch = TestLatch()
        mock.duplicatesGate = { try await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.load() }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(vm.groups.map(\.duplicateId), ["g1"])
    }

    @MainActor
    func test_AC_152_duplicates_refreshFailureKeepsDataThenRetryClears() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        let vm = DuplicatesViewModel(client: mock)
        await vm.load()

        mock.duplicatesError = serverError
        await vm.refresh()

        XCTAssertEqual(vm.renderState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.groups.map(\.duplicateId), ["g1"])

        mock.duplicatesError = nil
        await vm.load()
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_duplicates_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        let vm = DuplicatesViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.renderState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        mock.duplicatesGate = { try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 1 }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .empty)
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .data(.idle))

        // From the error state.
        mock.duplicatesGate = nil
        mock.duplicatesResponse = nil
        let failing = DuplicatesViewModel(client: mock)
        mock.duplicatesError = serverError
        await failing.load()
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        mock.duplicatesGate = { try await errorLatch.wait() }
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refresh() }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 1 }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        mock.duplicatesError = nil
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_duplicates_refreshDuringReadIsNotIgnored() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        let latch = TestLatch()
        mock.duplicatesGate = holdingFirstCall(latch)
        let vm = DuplicatesViewModel(client: mock)

        let first = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }
        await vm.refresh()
        XCTAssertEqual(mock.requestCount, 2, "a pull during a read is a request of its own")
        XCTAssertEqual(vm.renderState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.duplicatesError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func test_AC_149_duplicates_actionErrorDoesNotSetTheReadError() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        let vm = DuplicatesViewModel(client: mock)
        await vm.load()

        mock.globalError = serverError
        await vm.deleteGroup(id: "g1")

        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertEqual(vm.renderState, .data(.idle))
    }
}
