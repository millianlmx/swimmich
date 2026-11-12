import XCTest
@testable import ImmichSwiftUI

/// Creating tags under a parent, and what the tree shows afterwards (L-03).
final class TagsViewModelTests: XCTestCase {

    private struct BoomError: Error {}

    private let voyages = TagResponseDto(id: "voyages", name: "Voyages", value: "Voyages")
    private let famille = TagResponseDto(id: "famille", name: "Famille", value: "Famille")

    @MainActor
    private func loadedViewModel(_ mock: MockImmichClient) async -> TagsViewModel {
        mock.tagsResponse = [voyages, famille]
        let vm = TagsViewModel(client: mock)
        await vm.load()
        return vm
    }

    @MainActor
    private func shape(_ vm: TagsViewModel) -> [String] {
        vm.rows.map { "\($0.tag.id)@\($0.depth)" }
    }

    @MainActor
    func test_AC_13_createUnderParentSendsParentIdAndInsertsRow() async {
        let mock = MockImmichClient()
        let vm = await loadedViewModel(mock)
        mock.createTagResponse = TagResponseDto(id: "italie", name: "Italie", value: "Voyages/Italie", parentId: "voyages")
        let loads = mock.getAllTagsCallCount

        let created = await vm.create(name: "Italie", parentId: "voyages")

        XCTAssertTrue(created)
        XCTAssertEqual(mock.createTagCalls.last?.parentId, "voyages")
        XCTAssertEqual(mock.createTagCalls.last?.name, "Italie")
        XCTAssertEqual(shape(vm), ["famille@0", "voyages@0", "italie@1"])
        XCTAssertEqual(mock.getAllTagsCallCount, loads, "no reload: the answer is inserted in place")
    }

    @MainActor
    func test_AC_77_createAtRootSendsNoParent() async {
        let mock = MockImmichClient()
        let vm = await loadedViewModel(mock)

        let created = await vm.create(name: "  Animaux ", parentId: nil)

        XCTAssertTrue(created)
        XCTAssertEqual(mock.createTagCalls.count, 1)
        XCTAssertEqual(mock.createTagCalls.last?.name, "Animaux")
        XCTAssertNil(mock.createTagCalls.last?.parentId)
        XCTAssertEqual(shape(vm), ["tag-new@0", "famille@0", "voyages@0"])
    }

    @MainActor
    func test_AC_77_blankNameSendsNothing() async {
        let mock = MockImmichClient()
        let vm = await loadedViewModel(mock)
        let before = shape(vm)

        for blank in ["", "   ", "\n\t "] {
            let created = await vm.create(name: blank, parentId: "voyages")
            XCTAssertFalse(created)
        }

        XCTAssertTrue(mock.createTagCalls.isEmpty)
        XCTAssertEqual(shape(vm), before)
        XCTAssertNil(vm.createErrorMessage)
    }

    @MainActor
    func test_AC_78_readOnlyRefusesBeforeWire() async {
        let mock = MockImmichClient()
        mock.tagsResponse = [voyages, famille]
        let vm = TagsViewModel(client: ReadOnlyGuardClient(inner: mock, isEnabled: { true }))
        await vm.load()
        let before = vm.rows

        let created = await vm.create(name: "Italie", parentId: "voyages")

        XCTAssertFalse(created)
        XCTAssertTrue(mock.createTagCalls.isEmpty)
        XCTAssertEqual(vm.createErrorMessage, APIError.readOnlyMode.userFacingMessage)
        XCTAssertEqual(vm.rows, before)
    }

    @MainActor
    func test_AC_78_serverErrorKeepsTree() async {
        let mock = MockImmichClient()
        let vm = await loadedViewModel(mock)
        let before = vm.rows
        mock.createTagError = BoomError()

        let created = await vm.create(name: "Italie", parentId: "voyages")

        XCTAssertFalse(created)
        XCTAssertEqual(mock.createTagCalls.count, 1, "the call is attempted, then refused")
        XCTAssertNotNil(vm.createErrorMessage)
        XCTAssertEqual(vm.rows, before)

        vm.clearCreateError()
        XCTAssertNil(vm.createErrorMessage)
    }

    @MainActor
    func test_parentChoices_listedByFullPath() async {
        let mock = MockImmichClient()
        mock.tagsResponse = [
            TagResponseDto(id: "j", name: "Japon", value: "Voyages/Japon", parentId: "voyages"),
            voyages,
            TagResponseDto(id: "c", name: "Cuisine", value: "Cuisine"),
        ]
        let vm = TagsViewModel(client: mock)
        await vm.load()

        XCTAssertEqual(vm.parentChoices.map(\.path), ["Cuisine", "Voyages", "Voyages/Japon"])
    }

    // MARK: - List states (L-16)

    private let serverError = APIError.serverError(500, "x")

    /// A gate whose first call waits for `latch`; the following ones pass.
    private func holdingFirstCall(_ latch: TestLatch) -> (() async throws -> Void) {
        let calls = TestBox(0)
        return {
            calls.value += 1
            if calls.value == 1 { try await latch.wait() }
        }
    }

    @MainActor
    func test_AC_142_tags_loadingUntilFirstAnswer() async {
        let mock = MockImmichClient()
        mock.tagsResponse = [voyages]
        let latch = TestLatch()
        mock.tagsGate = { try await latch.wait() }
        let vm = TagsViewModel(client: mock)
        XCTAssertEqual(vm.renderState, .loading)

        let read = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_147_tags_successfulEmptyReadIsEmptyState() async {
        let vm = TagsViewModel(client: MockImmichClient())

        await vm.load()

        XCTAssertEqual(vm.renderState, .empty)
        XCTAssertTrue(vm.hasLoaded)
    }

    @MainActor
    func test_AC_149_tags_firstReadFailsShowsErrorNotEmpty() async {
        let mock = MockImmichClient()
        mock.tagsError = serverError
        let vm = TagsViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.rows.isEmpty)
        XCTAssertNil(vm.errorMessage, "the read never writes the delete error")
    }

    @MainActor
    func test_AC_149_tags_retryShowsLoadingThenData() async {
        let mock = MockImmichClient()
        mock.tagsError = serverError
        let vm = TagsViewModel(client: mock)
        await vm.load()
        mock.tagsError = nil
        mock.tagsResponse = [voyages]
        let latch = TestLatch()
        mock.tagsGate = { try await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.load(force: true) }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(shape(vm), ["voyages@0"])
    }

    @MainActor
    func test_AC_152_tags_refreshFailureKeepsDataThenRetryClears() async {
        let mock = MockImmichClient()
        let vm = await loadedViewModel(mock)

        mock.tagsError = serverError
        await vm.refresh()

        XCTAssertEqual(vm.renderState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(shape(vm), ["famille@0", "voyages@0"])

        mock.tagsError = nil
        await vm.load(force: true)
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_tags_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        let vm = TagsViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.renderState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        mock.tagsGate = { try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 1 }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .empty)
        mock.tagsResponse = [voyages]
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .data(.idle))

        // From the error state.
        mock.tagsGate = nil
        mock.tagsResponse = nil
        let failing = TagsViewModel(client: mock)
        mock.tagsError = serverError
        await failing.load()
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        mock.tagsGate = { try await errorLatch.wait() }
        mock.tagsResponse = [voyages]
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refresh() }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 1 }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        mock.tagsError = nil
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_tags_refreshDuringReadIsNotIgnored() async {
        let mock = MockImmichClient()
        mock.tagsResponse = [voyages]
        let latch = TestLatch()
        mock.tagsGate = holdingFirstCall(latch)
        let vm = TagsViewModel(client: mock)

        let first = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }
        await vm.refresh()
        XCTAssertEqual(mock.requestCount, 2, "a pull during a read is a request of its own")
        XCTAssertEqual(vm.renderState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.tagsError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func test_AC_149_tags_deleteFailureDoesNotSetTheReadError() async {
        let mock = MockImmichClient()
        let vm = await loadedViewModel(mock)

        mock.tagsError = serverError
        await vm.delete(voyages)

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertEqual(vm.renderState, .data(.idle))
    }
}
