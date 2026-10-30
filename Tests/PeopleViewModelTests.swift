import XCTest
@testable import ImmichSwiftUI

final class PeopleViewModelTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeVM(_ mock: MockImmichClient) -> PeopleViewModel {
        PeopleViewModel(client: mock)
    }

    private func makePerson(id: String, name: String = "Person", isHidden: Bool = false, isFavorite: Bool? = nil) -> PersonResponseDto {
        PersonResponseDto(
            id: id, name: name, birthDate: "1990-01-01", thumbnailPath: "",
            isHidden: isHidden, color: nil, isFavorite: isFavorite, updatedAt: nil
        )
    }

    private func makeAssetDTO(id: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2024-07-01T00:00:00.000Z",
            ownerId: "owner", originalPath: "/\(id).jpg", originalFileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", fileModifiedAt: "2024-07-01T00:00:00.000Z",
            updatedAt: "2024-07-01T00:00:00.000Z", isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    // MARK: - List

    @MainActor
    func test_people_load_mapsListAndCounts() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(
            people: [makePerson(id: "p1"), makePerson(id: "p2")], hidden: 3, total: 5, hasNextPage: nil
        )
        let vm = makeVM(mock)
        await vm.load()

        XCTAssertEqual(vm.people.count, 2)
        XCTAssertEqual(vm.hiddenCount, 3)
        XCTAssertEqual(vm.total, 5)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_people_load_failure_setsError() async {
        let mock = MockImmichClient()
        mock.peopleError = APIError.serverError(500, "boom")
        let vm = makeVM(mock)
        await vm.load()

        XCTAssertTrue(vm.people.isEmpty)
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
    }

    @MainActor
    func test_people_showHidden_togglesAndReloads() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1")], hidden: 0, total: 1, hasNextPage: nil)
        let vm = makeVM(mock)
        await vm.load()
        XCTAssertEqual(mock.lastPeopleWithHidden, false)

        await vm.toggleShowHidden()
        XCTAssertTrue(vm.showingHidden)
        XCTAssertEqual(mock.lastPeopleWithHidden, true)

        await vm.toggleShowHidden()
        XCTAssertFalse(vm.showingHidden)
        XCTAssertEqual(mock.lastPeopleWithHidden, false)
    }

    // MARK: - Person actions

    @MainActor
    func test_people_rename_updatesRow() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1", name: "Old")], hidden: 0, total: 1, hasNextPage: nil)
        let vm = makeVM(mock)
        await vm.load()

        await vm.rename(vm.people[0], to: "New Name")
        XCTAssertEqual(mock.lastUpdatePersonId, "p1")
        XCTAssertEqual(mock.lastUpdatePersonDto?.name, "New Name")
        XCTAssertEqual(vm.people[0].name, "New Name")
    }

    @MainActor
    func test_people_toggleFavorite_sendsIsFavorite() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1", isFavorite: false)], hidden: 0, total: 1, hasNextPage: nil)
        let vm = makeVM(mock)
        await vm.load()

        await vm.toggleFavorite(vm.people[0])
        XCTAssertEqual(mock.lastUpdatePersonDto?.isFavorite, true)
        XCTAssertEqual(vm.people[0].isFavorite, true)
    }

    @MainActor
    func test_people_toggleHidden_sendsIsHidden() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1", isHidden: false)], hidden: 0, total: 1, hasNextPage: nil)
        let vm = makeVM(mock)
        await vm.load()

        await vm.toggleHidden(vm.people[0])
        XCTAssertEqual(mock.lastUpdatePersonDto?.isHidden, true)
        XCTAssertTrue(vm.people[0].isHidden)
    }

    // MARK: - Birthday (gap G15)

    /// The invariant of the feature: posing a date must not carry any other
    /// field, or editing a birthday silently rewrites the person's name or
    /// cover photo.
    @MainActor
    func test_people_setBirthday_sendsBirthDateOnly() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1")], hidden: 0, total: 1, hasNextPage: nil)
        let vm = makeVM(mock)
        await vm.load()

        await vm.setBirthday(vm.people[0], to: "1990-05-12")
        XCTAssertEqual(mock.lastUpdatePersonId, "p1")
        XCTAssertEqual(mock.lastUpdatePersonDto?.birthDate, "1990-05-12")
        XCTAssertNil(mock.lastUpdatePersonDto?.name)
        XCTAssertNil(mock.lastUpdatePersonDto?.color)
        XCTAssertNil(mock.lastUpdatePersonDto?.featureFaceAssetId)
        XCTAssertNil(mock.lastUpdatePersonDto?.isFavorite)
        XCTAssertNil(mock.lastUpdatePersonDto?.isHidden)
        XCTAssertEqual(vm.people[0].birthDate, "1990-05-12")
    }

    /// Clearing must not go through `PersonUpdateDto`: its synthesized encoder
    /// omits a nil `birthDate`, so that route would leave the birthday in place
    /// while looking successful.
    @MainActor
    func test_people_setBirthday_clearsViaDedicatedRoute() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1")], hidden: 0, total: 1, hasNextPage: nil)
        let vm = makeVM(mock)
        await vm.load()

        await vm.setBirthday(vm.people[0], to: nil)
        XCTAssertEqual(mock.lastClearedPersonBirthdayId, "p1")
        XCTAssertNil(mock.lastUpdatePersonDto)
        XCTAssertNil(vm.people[0].birthDate)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_people_setBirthday_failure_setsError() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1")], hidden: 0, total: 1, hasNextPage: nil)
        let vm = makeVM(mock)
        await vm.load()
        let before = vm.people

        mock.peopleError = APIError.serverError(500, "boom")
        await vm.setBirthday(vm.people[0], to: "1990-05-12")
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
        XCTAssertEqual(vm.people, before)
    }

    // MARK: - Statistics

    @MainActor
    func test_people_stats_fanout_fillsCounts() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(
            people: [makePerson(id: "p1"), makePerson(id: "p2")], hidden: 0, total: 2, hasNextPage: nil
        )
        mock.personStatisticsResponse = [
            "p1": PersonStatisticsResponseDto(assets: 12),
            "p2": PersonStatisticsResponseDto(assets: 7),
        ]
        let vm = makeVM(mock)
        await vm.load()

        await vm.loadStatistics()
        XCTAssertEqual(vm.assetCount(for: "p1"), 12)
        XCTAssertEqual(vm.assetCount(for: "p2"), 7)
        XCTAssertEqual(vm.assetCount(for: "missing"), 0)
    }

    @MainActor
    func test_people_stats_failure_keepsZeroCounts() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1")], hidden: 0, total: 1, hasNextPage: nil)
        mock.peopleError = APIError.serverError(500, "boom")
        let vm = makeVM(mock)

        await vm.loadStatistics()
        XCTAssertEqual(vm.assetCount(for: "p1"), 0)
    }

    // MARK: - Merge

    @MainActor
    func test_people_merge_callsMergeAndReloads() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(
            people: [makePerson(id: "p1"), makePerson(id: "p2")], hidden: 0, total: 2, hasNextPage: nil
        )
        let vm = makeVM(mock)
        await vm.load()
        let target = vm.people[0]

        await vm.merge([vm.people[1].id], into: target)
        XCTAssertEqual(mock.lastMergePersonIds, ["p2"])
        XCTAssertEqual(mock.lastMergeTargetId, "p1")
        XCTAssertEqual(vm.lastMergeIds, ["p2"])
        XCTAssertEqual(vm.lastMergeTarget, "p1")
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_people_merge_failure_setsError() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1")], hidden: 0, total: 1, hasNextPage: nil)
        let vm = makeVM(mock)
        await vm.load()
        let target = vm.people[0]

        mock.peopleError = APIError.serverError(500, "boom")
        await vm.merge(["pX"], into: target)
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
    }

    // MARK: - Faces drill-down

    @MainActor
    func test_people_select_loadsAssetsViaPersonIDs() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1")], hidden: 0, total: 1, hasNextPage: nil)
        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(count: 2, items: [makeAssetDTO(id: "a1"), makeAssetDTO(id: "a2")], nextPage: nil)
        )
        let vm = makeVM(mock)
        await vm.load()

        await vm.select(vm.people[0])
        XCTAssertEqual(mock.lastMetadataSearchDto?.personIds, ["p1"])
        XCTAssertEqual(vm.personAssets.map(\.id), ["a1", "a2"])
        XCTAssertEqual(vm.selectedPersonID, "p1")
        XCTAssertNil(vm.assetsError)
    }

    @MainActor
    func test_people_assets_failure_setsAssetsError() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1")], hidden: 0, total: 1, hasNextPage: nil)
        mock.searchMetadataError = APIError.serverError(500, "boom")
        let vm = makeVM(mock)
        await vm.load()

        await vm.select(vm.people[0])
        XCTAssertEqual(vm.assetsError, UserFacingError.serverErrorMessage)
        XCTAssertTrue(vm.personAssets.isEmpty)
    }

    /// AC-3: a technical failure (decoding or a raw 500 body) must surface as the
    /// localized copy of its family, never as its transport or server text.
    @MainActor
    func test_AC3_technicalErrorShowsLocalizedCopyWithoutRawText() async {
        let cases: [(error: Error, expected: String)] = [
            (APIError.decoding("Decoding failed: unexpected key"), UserFacingError.genericMessage),
            (APIError.serverError(500, "HTTP 500 <html>boom</html>"), UserFacingError.serverErrorMessage),
        ]
        let forbidden = ["Decoding failed", "Network error", "HTTP", "boom", "<html>", "The operation couldn't be completed"]
        for (error, expected) in cases {
            let mock = MockImmichClient()
            mock.peopleError = error
            let vm = makeVM(mock)
            await vm.load()

            XCTAssertEqual(vm.errorMessage, expected)
            for fragment in forbidden {
                XCTAssertFalse(vm.errorMessage?.contains(fragment) == true, "leaked \"\(fragment)\"")
            }
        }
    }

    @MainActor
    func test_people_refreshAssets_reloadsEvenWhenLoaded() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1")], hidden: 0, total: 1, hasNextPage: nil)
        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(count: 1, items: [makeAssetDTO(id: "a1")], nextPage: nil)
        )
        let vm = makeVM(mock)
        await vm.load()
        await vm.select(vm.people[0])
        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(count: 1, items: [makeAssetDTO(id: "a2")], nextPage: nil)
        )

        await vm.refreshAssets()
        XCTAssertEqual(vm.personAssets.map(\.id), ["a2"])
    }

    @MainActor
    func test_people_clearSelection_resetsDrillDown() async {
        let mock = MockImmichClient()
        mock.peopleResponse = PeopleResponseDto(people: [makePerson(id: "p1")], hidden: 0, total: 1, hasNextPage: nil)
        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(count: 1, items: [makeAssetDTO(id: "a1")], nextPage: nil)
        )
        let vm = makeVM(mock)
        await vm.load()
        await vm.select(vm.people[0])

        vm.clearSelection()
        XCTAssertNil(vm.selectedPersonID)
        XCTAssertTrue(vm.personAssets.isEmpty)
    }

    // MARK: - Pagination, refresh after merge (test_People_AC_<n>_…)

    private func peoplePage(_ ids: [String], hasNext: Bool?, favorites: Set<String> = []) -> PeopleResponseDto {
        PeopleResponseDto(
            people: ids.map { makePerson(id: $0, name: $0, isFavorite: favorites.contains($0) ? true : nil) },
            hidden: 0, total: ids.count, hasNextPage: hasNext
        )
    }

    private func assetPage(_ ids: [String], next: String?) -> SearchResponseDto {
        SearchResponseDto(assets: SearchAssetResponseDto(count: ids.count, items: ids.map { makeAssetDTO(id: $0) }, nextPage: next))
    }

    private func statsCalls(_ mock: MockImmichClient, _ id: String) -> Int {
        mock.personStatisticsCalls.filter { $0 == id }.count
    }

    /// p1, p2 on page 1 (hasNextPage), p3 on page 2 (last), loaded by `appear`.
    @MainActor
    private func pagedPeople() -> (MockImmichClient, PeopleViewModel) {
        let mock = MockImmichClient()
        mock.peopleResponsesByPage = [
            1: peoplePage(["p1", "p2"], hasNext: true),
            2: peoplePage(["p3"], hasNext: false),
        ]
        return (mock, makeVM(mock))
    }

    /// p1 with a grid of two pages: [a1, a2] (next "2") then [a3] (last).
    @MainActor
    private func pagedGrid() async -> (MockImmichClient, PeopleViewModel, PersonResponseDto) {
        let mock = MockImmichClient()
        mock.searchMetadataResponsesByPage = [
            1: assetPage(["a1", "a2"], next: "2"),
            2: assetPage(["a3"], next: nil),
        ]
        let vm = makeVM(mock)
        let p1 = makePerson(id: "p1")
        await vm.select(p1)
        return (mock, vm, p1)
    }

    @MainActor
    func test_People_AC_1_firstPageShownWithoutWaitingForTheNext() async {
        let (mock, vm) = pagedPeople()
        await vm.appear(visit: UUID())

        XCTAssertEqual(mock.getPeopleCalls.count, 1)
        XCTAssertTrue([nil, 1].contains(mock.getPeopleCalls[0].page))
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2"])
    }

    @MainActor
    func test_People_AC_2_lastRowRequestsPageTwoOnceAndDeduplicates() async {
        let (mock, vm) = pagedPeople()
        await vm.appear(visit: UUID())
        let latch = TestLatch()
        mock.peopleGate = { call in if call.page == 2 { try await latch.wait() } }

        let first = Task { await vm.personRowAppeared("p2") }
        await pollUntil("page 2 requested") { mock.getPeopleCalls.count == 2 }
        await vm.personRowAppeared("p2")
        latch.open()
        await first.value

        XCTAssertEqual(mock.getPeopleCalls.last, PeopleCall(page: 2, withHidden: false))
        XCTAssertEqual(mock.getPeopleCalls.count, 2)
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2", "p3"])
    }

    @MainActor
    func test_People_AC_3_noRequestWhenLastPageHasNoNext() async {
        let (mock, vm) = pagedPeople()
        await vm.appear(visit: UUID())
        await vm.personRowAppeared("p2")
        XCTAssertEqual(mock.getPeopleCalls.count, 2)
        await vm.personRowAppeared("p3")
        XCTAssertEqual(mock.getPeopleCalls.count, 2)

        // An older server omits `hasNextPage`: that is the last page.
        let old = MockImmichClient()
        old.peopleResponse = peoplePage(["p1", "p2"], hasNext: nil)
        let oldVM = makeVM(old)
        await oldVM.appear(visit: UUID())
        await oldVM.personRowAppeared("p2")
        XCTAssertEqual(old.getPeopleCalls.count, 1)
    }

    @MainActor
    func test_People_AC_4_gridShowsFirstPageOfTwo() async {
        let mock = MockImmichClient()
        let first = (0..<250).map { "a\($0)" }
        mock.searchMetadataResponsesByPage = [
            1: assetPage(first, next: "2"),
            2: assetPage((250..<260).map { "a\($0)" }, next: nil),
        ]
        let vm = makeVM(mock)
        await vm.select(makePerson(id: "p1"))

        XCTAssertEqual(mock.searchMetadataCalls.count, 1)
        XCTAssertEqual(mock.searchMetadataCalls[0].personIds, ["p1"])
        XCTAssertEqual(vm.personAssets.map(\.id), first)
    }

    @MainActor
    func test_People_AC_5_lastCellRequestsPageTwoOnceWithoutDuplicates() async {
        let (mock, vm, _) = await pagedGrid()
        // The server repeats a2 on page 2: the grid keeps one cell for it.
        mock.searchMetadataResponsesByPage[2] = assetPage(["a2", "a3"], next: nil)
        let latch = TestLatch()
        mock.searchMetadataGate = { dto in if dto.page == 2 { try await latch.wait() } }

        let first = Task { await vm.assetCellAppeared("a2") }
        await pollUntil("page 2 requested") { mock.searchMetadataCalls.count == 2 }
        await vm.assetCellAppeared("a2")
        latch.open()
        await first.value

        XCTAssertEqual(mock.searchMetadataCalls.count, 2)
        XCTAssertEqual(mock.searchMetadataCalls[1].personIds, ["p1"])
        XCTAssertEqual(mock.searchMetadataCalls[1].page, 2)
        XCTAssertEqual(vm.personAssets.map(\.id), ["a1", "a2", "a3"])
    }

    @MainActor
    func test_People_AC_6_noRequestAfterLastGridPage() async {
        let (mock, vm, _) = await pagedGrid()
        await vm.assetCellAppeared("a2")
        XCTAssertEqual(mock.searchMetadataCalls.count, 2)

        await vm.assetCellAppeared("a3")
        XCTAssertEqual(mock.searchMetadataCalls.count, 2)
    }

    /// p1's page 2 is held in flight; `leave` moves away from p1 meanwhile.
    @MainActor
    private func gridPageInFlightThenLeave(_ leave: (PeopleViewModel) async -> Void) async -> PeopleViewModel {
        let mock = MockImmichClient()
        let p1Page1 = assetPage(["a1", "a2"], next: "2")
        let p1Page2 = assetPage(["a3"], next: nil)
        let p2Page1 = assetPage(["b1"], next: nil)
        mock.searchMetadataHandler = { dto in
            if dto.personIds == ["p2"] { return p2Page1 }
            return dto.page == 2 ? p1Page2 : p1Page1
        }
        let latch = TestLatch()
        mock.searchMetadataGate = { dto in
            if dto.personIds == ["p1"], dto.page == 2 { try await latch.wait() }
        }
        let vm = makeVM(mock)
        await vm.select(makePerson(id: "p1"))

        let stale = Task { await vm.assetCellAppeared("a2") }
        await pollUntil("p1 page 2 requested") { mock.searchMetadataCalls.count == 2 }
        await leave(vm)
        latch.open()
        await stale.value
        return vm
    }

    @MainActor
    func test_People_AC_7_stalePageDoesNotLandInAnotherPersonsGrid() async {
        let vm = await gridPageInFlightThenLeave { vm in await vm.select(self.makePerson(id: "p2")) }
        XCTAssertEqual(vm.personAssets.map(\.id), ["b1"])
    }

    @MainActor
    func test_People_AC_7_stalePageDoesNotLandInAClearedGrid() async {
        let vm = await gridPageInFlightThenLeave { vm in vm.clearSelection() }
        XCTAssertTrue(vm.personAssets.isEmpty)
        XCTAssertFalse(vm.assetsLoading)
    }

    @MainActor
    func test_People_AC_8_mergeRefreshesTheTargetsGrid() async {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = assetPage(["a"], next: nil)
        let vm = makeVM(mock)
        let p1 = makePerson(id: "p1")
        await vm.select(p1)
        XCTAssertEqual(vm.personAssets.map(\.id), ["a"])
        mock.searchMetadataResponse = assetPage(["a", "b"], next: nil)

        await vm.merge(["p2"], into: p1)

        XCTAssertEqual(mock.lastMergePersonIds, ["p2"])
        XCTAssertEqual(mock.searchMetadataCalls.count, 2)
        XCTAssertEqual(mock.searchMetadataCalls[1].personIds, ["p1"])
        XCTAssertEqual(mock.searchMetadataCalls[1].page, 1)
        XCTAssertEqual(vm.personAssets.map(\.id), ["a", "b"])
    }

    @MainActor
    func test_People_AC_9_mergeRestartsGridPaginationFromPageOne() async {
        let (mock, vm, p1) = await pagedGrid()
        await vm.assetCellAppeared("a2")
        XCTAssertEqual(vm.personAssets.map(\.id), ["a1", "a2", "a3"])
        mock.searchMetadataResponsesByPage[1] = assetPage(["a1", "a4"], next: "2")

        await vm.merge(["p2"], into: p1)
        XCTAssertEqual(vm.personAssets.map(\.id), ["a1", "a4"])

        await vm.assetCellAppeared("a4")
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 2)
        XCTAssertEqual(vm.personAssets.map(\.id), ["a1", "a4", "a3"])
    }

    @MainActor
    func test_People_AC_10_mergeReloadsListAndTargetCount() async {
        let mock = MockImmichClient()
        mock.peopleResponse = peoplePage(["p1", "p2"], hasNext: nil)
        mock.personStatisticsResponse = ["p1": PersonStatisticsResponseDto(assets: 5)]
        let vm = makeVM(mock)
        await vm.appear(visit: UUID())
        XCTAssertEqual(vm.assetCount(for: "p1"), 5)
        XCTAssertEqual(statsCalls(mock, "p1"), 1)

        mock.peopleResponse = peoplePage(["p1"], hasNext: nil)
        mock.personStatisticsResponse["p1"] = PersonStatisticsResponseDto(assets: 8)
        await vm.merge(["p2"], into: vm.people[0])

        XCTAssertEqual(mock.getPeopleCalls.last?.page, 1)
        XCTAssertEqual(mock.getPeopleCalls.count, 2)
        XCTAssertEqual(vm.people.map(\.id), ["p1"])
        XCTAssertEqual(statsCalls(mock, "p1"), 2)
        XCTAssertEqual(vm.assetCount(for: "p1"), 8)
    }

    @MainActor
    func test_People_AC_11_failedMergeLeavesListAndGridUntouched() async {
        let (mock, vm, p1) = await pagedGrid()
        mock.peopleResponse = peoplePage(["p1", "p2"], hasNext: nil)
        await vm.load()
        let people = vm.people
        let assets = vm.personAssets
        let peopleCalls = mock.getPeopleCalls.count
        let searches = mock.searchMetadataCalls.count
        let stats = mock.personStatisticsCalls.count

        mock.peopleError = APIError.serverError(500, "boom")
        await vm.merge(["p2"], into: p1)

        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
        XCTAssertEqual(vm.people, people)
        XCTAssertEqual(vm.personAssets, assets)
        XCTAssertEqual(mock.getPeopleCalls.count, peopleCalls)
        XCTAssertEqual(mock.searchMetadataCalls.count, searches)
        XCTAssertEqual(mock.personStatisticsCalls.count, stats)
    }

    @MainActor
    func test_People_AC_19_nextPageAsksOnlyNewCounts() async {
        let (mock, vm) = pagedPeople()
        mock.personStatisticsResponse = [
            "p1": PersonStatisticsResponseDto(assets: 5),
            "p2": PersonStatisticsResponseDto(assets: 6),
            "p3": PersonStatisticsResponseDto(assets: 42),
        ]
        await vm.appear(visit: UUID())
        await vm.personRowAppeared("p1")
        await vm.personRowAppeared("p2")

        XCTAssertEqual(vm.assetCount(for: "p3"), 42)
        XCTAssertEqual(statsCalls(mock, "p1"), 1)
        XCTAssertEqual(statsCalls(mock, "p2"), 1)
        XCTAssertEqual(statsCalls(mock, "p3"), 1)
    }

    @MainActor
    func test_People_AC_21_refreshReloadsPageOneAndCounts() async {
        let (mock, vm) = pagedPeople()
        mock.personStatisticsResponse = ["p1": PersonStatisticsResponseDto(assets: 5)]
        await vm.appear(visit: UUID())
        await vm.personRowAppeared("p2")
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(vm.assetCount(for: "p1"), 5)

        mock.personStatisticsResponse["p1"] = PersonStatisticsResponseDto(assets: 8)
        await vm.refresh()

        XCTAssertEqual(mock.getPeopleCalls.last?.page, 1)
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2"])
        XCTAssertEqual(vm.assetCount(for: "p1"), 8)
        await vm.personRowAppeared("p2")
        XCTAssertEqual(mock.getPeopleCalls.last?.page, 2)
    }

    @MainActor
    func test_People_AC_21_toggleHiddenReloadsPageOne() async {
        let (mock, vm) = pagedPeople()
        await vm.appear(visit: UUID())
        await vm.personRowAppeared("p2")

        await vm.toggleShowHidden()

        XCTAssertEqual(mock.getPeopleCalls.last, PeopleCall(page: 1, withHidden: true))
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2"])
        await vm.personRowAppeared("p2")
        XCTAssertEqual(mock.getPeopleCalls.last, PeopleCall(page: 2, withHidden: true))
    }

    @MainActor
    func test_People_AC_22_stalePageTwoIsDroppedAfterReload() async {
        let (mock, vm) = pagedPeople()
        await vm.appear(visit: UUID())
        let latch = TestLatch()
        mock.peopleGate = { call in if call.page == 2 { try await latch.wait() } }

        let stale = Task { await vm.personRowAppeared("p2") }
        await pollUntil("page 2 requested") { mock.getPeopleCalls.count == 2 }
        await vm.load(force: true)
        latch.open()
        await stale.value

        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2"])
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isLoadingMorePeople)
    }

    @MainActor
    func test_People_AC_23_refreshAssetsRestartsGridPagination() async {
        let (mock, vm, _) = await pagedGrid()
        await vm.assetCellAppeared("a2")
        mock.searchMetadataResponsesByPage[1] = assetPage(["a1", "a5"], next: "2")

        await vm.refreshAssets()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)
        XCTAssertEqual(vm.personAssets.map(\.id), ["a1", "a5"])

        await vm.assetCellAppeared("a5")
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 2)
    }

    @MainActor
    func test_People_AC_24_failedListPageKeepsRowsAndRetries() async {
        let (mock, vm) = pagedPeople()
        await vm.appear(visit: UUID())
        mock.peopleGate = { call in
            if call.page == 2 { throw APIError.serverError(500, "boom") }
        }

        await vm.personRowAppeared("p2")
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2"])
        XCTAssertEqual(vm.peopleFooter, .error(UserFacingError.serverErrorMessage))

        mock.peopleGate = nil
        await vm.personRowAppeared("p2")
        XCTAssertEqual(mock.getPeopleCalls.filter { $0.page == 2 }.count, 2)
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2", "p3"])
        XCTAssertNil(vm.peopleLoadMoreError)
        XCTAssertEqual(vm.peopleFooter, .none)
    }

    @MainActor
    func test_People_AC_24_failedGridPageKeepsCellsAndRetries() async {
        let (mock, vm, _) = await pagedGrid()
        mock.searchMetadataGate = { dto in
            if dto.page == 2 { throw APIError.serverError(500, "boom") }
        }

        await vm.assetCellAppeared("a2")
        XCTAssertEqual(vm.personAssets.map(\.id), ["a1", "a2"])
        XCTAssertEqual(vm.assetsFooter, .error(UserFacingError.serverErrorMessage))

        mock.searchMetadataGate = nil
        await vm.assetCellAppeared("a2")
        XCTAssertEqual(mock.searchMetadataCalls.filter { $0.page == 2 }.count, 2)
        XCTAssertEqual(vm.personAssets.map(\.id), ["a1", "a2", "a3"])
        XCTAssertNil(vm.assetsLoadMoreError)
        XCTAssertEqual(vm.assetsFooter, .none)
    }

    @MainActor
    func test_People_AC_25_nextPageFollowsTheLastDisplayedRow() async {
        let mock = MockImmichClient()
        mock.peopleResponsesByPage = [1: peoplePage(["p1", "p2", "p3"], hasNext: true, favorites: ["p1"])]
        mock.personStatisticsResponse = [
            "p2": PersonStatisticsResponseDto(assets: 3),
            "p3": PersonStatisticsResponseDto(assets: 9),
        ]
        let vm = makeVM(mock)
        await vm.appear(visit: UUID())

        XCTAssertEqual(vm.featuredPeople.map(\.id), ["p1"])
        XCTAssertEqual(vm.otherPeople.map(\.id), ["p3", "p2"])
        await vm.personRowAppeared("p1")
        await vm.personRowAppeared("p3")
        XCTAssertEqual(mock.getPeopleCalls.count, 1)

        await vm.personRowAppeared("p2")
        XCTAssertEqual(mock.getPeopleCalls.count, 2)
        XCTAssertEqual(mock.getPeopleCalls.last?.page, 2)
    }

    @MainActor
    func test_People_AC_26_staleGridPageTwoIsDroppedAfterRefreshOrMerge() async {
        for viaMerge in [false, true] {
            let (mock, vm, p1) = await pagedGrid()
            let latch = TestLatch()
            mock.searchMetadataGate = { dto in if dto.page == 2 { try await latch.wait() } }
            let stale = Task { await vm.assetCellAppeared("a2") }
            await pollUntil("page 2 requested") { mock.searchMetadataCalls.count == 2 }
            mock.searchMetadataResponsesByPage[1] = assetPage(["a1", "a9"], next: "2")

            if viaMerge { await vm.merge(["p2"], into: p1) } else { await vm.refreshAssets() }
            latch.open()
            await stale.value

            XCTAssertEqual(vm.personAssets.map(\.id), ["a1", "a9"], "viaMerge=\(viaMerge)")
            await vm.assetCellAppeared("a9")
            XCTAssertEqual(mock.searchMetadataCalls.last?.page, 2, "viaMerge=\(viaMerge)")
            XCTAssertEqual(mock.searchMetadataCalls.last?.personIds, ["p1"], "viaMerge=\(viaMerge)")
        }
    }

    @MainActor
    func test_People_AC_28_toggleHiddenAsksOnlyUnknownCounts() async {
        let mock = MockImmichClient()
        mock.peopleResponsesByPage = [1: peoplePage(["p1"], hasNext: nil)]
        mock.personStatisticsResponse = [
            "p1": PersonStatisticsResponseDto(assets: 5),
            "h1": PersonStatisticsResponseDto(assets: 4),
        ]
        let vm = makeVM(mock)
        await vm.appear(visit: UUID())

        mock.peopleResponsesByPage = [1: peoplePage(["p1", "h1"], hasNext: nil)]
        await vm.toggleShowHidden()

        XCTAssertEqual(statsCalls(mock, "p1"), 1)
        XCTAssertEqual(statsCalls(mock, "h1"), 1)
        XCTAssertEqual(vm.assetCount(for: "h1"), 4)
        XCTAssertEqual(vm.assetCount(for: "p1"), 5)
    }

    @MainActor
    func test_People_AC_30_sameVisitKeepsPaginationNewVisitReloads() async {
        let (mock, vm) = pagedPeople()
        mock.personStatisticsResponse = ["p1": PersonStatisticsResponseDto(assets: 5)]
        let a = UUID()
        await vm.appear(visit: a)
        await vm.personRowAppeared("p2")
        let peopleCalls = mock.getPeopleCalls.count
        let statCalls = mock.personStatisticsCalls.count

        await vm.appear(visit: a)
        XCTAssertEqual(mock.getPeopleCalls.count, peopleCalls)
        XCTAssertEqual(mock.personStatisticsCalls.count, statCalls)
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2", "p3"])

        mock.personStatisticsResponse["p1"] = PersonStatisticsResponseDto(assets: 8)
        await vm.appear(visit: UUID())
        XCTAssertEqual(mock.getPeopleCalls.last?.page, 1)
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2"])
        XCTAssertEqual(statsCalls(mock, "p1"), 2)
        XCTAssertEqual(statsCalls(mock, "p2"), 2)
        XCTAssertEqual(vm.assetCount(for: "p1"), 8)
    }

    @MainActor
    func test_People_AC_31_orderingEditsReloadPageOneWhenPagesRemain() async {
        let edits: [(String, (PeopleViewModel, PersonResponseDto) async -> Void)] = [
            ("toggleHidden", { vm, p in await vm.toggleHidden(p) }),
            ("toggleFavorite", { vm, p in await vm.toggleFavorite(p) }),
            ("rename", { vm, p in await vm.rename(p, to: "X") }),
        ]
        for (name, edit) in edits {
            let (mock, vm) = pagedPeople()
            await vm.appear(visit: UUID())
            let before = mock.getPeopleCalls.count

            await edit(vm, vm.people[0])

            XCTAssertNotNil(mock.lastUpdatePersonId, name)
            XCTAssertEqual(mock.getPeopleCalls.count, before + 1, name)
            XCTAssertEqual(mock.getPeopleCalls.last, PeopleCall(page: 1, withHidden: false), name)
            XCTAssertEqual(vm.people.map(\.id), ["p1", "p2"], name)
            await vm.personRowAppeared("p2")
            XCTAssertEqual(mock.getPeopleCalls.last?.page, 2, name)
        }
    }

    @MainActor
    func test_People_AC_31_noReloadWhenAllPagesLoadedOrEditFailsOrFieldIsNotOrdering() async {
        // Last page: no hole is possible.
        let last = MockImmichClient()
        last.peopleResponse = peoplePage(["p1", "p2"], hasNext: nil)
        let lastVM = makeVM(last)
        await lastVM.appear(visit: UUID())
        await lastVM.toggleFavorite(lastVM.people[0])
        XCTAssertNotNil(last.lastUpdatePersonId)
        XCTAssertEqual(last.getPeopleCalls.count, 1)

        // Failed edit.
        let (failing, failingVM) = pagedPeople()
        await failingVM.appear(visit: UUID())
        failing.peopleError = APIError.serverError(500, "boom")
        await failingVM.toggleFavorite(failingVM.people[0])
        XCTAssertEqual(failingVM.errorMessage, UserFacingError.serverErrorMessage)
        XCTAssertEqual(failing.getPeopleCalls.count, 1)

        // Birthday and cover do not enter the server order.
        let (mock, vm) = pagedPeople()
        await vm.appear(visit: UUID())
        await vm.setBirthday(vm.people[0], to: "1990-05-12")
        await vm.setFeatureFace(vm.people[0], assetId: "a1")
        XCTAssertNotNil(mock.lastUpdatePersonDto?.featureFaceAssetId)
        XCTAssertEqual(mock.getPeopleCalls.count, 1)
    }

    @MainActor
    func test_People_AC_32_detailKeepsEditsOfAPersonThatLeftTheLoadedPages() async {
        let (mock, vm) = pagedPeople()
        await vm.appear(visit: UUID())
        await vm.personRowAppeared("p2")
        let p3 = vm.people[2]
        XCTAssertEqual(p3.id, "p3")
        await vm.select(p3)

        await vm.rename(p3, to: "X")
        mock.peopleResponsesByPage[1] = peoplePage(["p1"], hasNext: true)
        await vm.merge(["p2"], into: vm.livePerson(p3))

        XCTAssertEqual(vm.people.map(\.id), ["p1"])
        XCTAssertEqual(vm.livePerson(p3).name, "X")

        await vm.toggleFavorite(vm.livePerson(p3))
        XCTAssertEqual(mock.lastUpdatePersonDto?.isFavorite, true)
        await vm.toggleFavorite(vm.livePerson(p3))
        XCTAssertEqual(mock.lastUpdatePersonDto?.isFavorite, false)
    }
}