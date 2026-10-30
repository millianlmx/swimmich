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

    // MARK: - Search by name (test_People_AC_<n>_…)

    /// Holds a `searchPerson` answer until the test opens it. Unlike
    /// `TestLatch`, it ignores task cancellation: the held request belongs to a
    /// task that the next keystroke cancels.
    private final class SearchGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { c in
                lock.lock()
                if opened { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
            }
        }
        func open() {
            lock.lock(); opened = true
            let c = continuation; continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    /// A VM whose debounce wait is empty: a keystroke's task runs at once.
    @MainActor
    private func makeSearchVM(_ mock: MockImmichClient) -> PeopleViewModel {
        let vm = makeVM(mock)
        vm.debounceWait = {}
        return vm
    }

    /// One keystroke, then the search task it started.
    @MainActor
    private func enterSearch(_ vm: PeopleViewModel, _ text: String) async {
        vm.searchQuery = text
        vm.searchQueryDidChange()
        await vm.searchTask?.value
    }

    @MainActor
    func test_People_AC_12_typingSearchesWithHiddenFalseInServerOrder() async {
        let mock = MockImmichClient()
        let r1 = makePerson(id: "r1", name: "Alice")
        let r2 = makePerson(id: "r2", name: "Alicia")
        mock.searchPersonResponse = [r2, r1]
        let vm = makeSearchVM(mock)
        XCTAssertFalse(vm.showingHidden)

        await enterSearch(vm, " ali ")

        XCTAssertEqual(mock.searchPersonCalls, [PersonSearchCall(name: "ali", withHidden: false)])
        XCTAssertEqual(vm.searchState, .results([r2, r1]))
        XCTAssertTrue(vm.isSearchActive)
        XCTAssertTrue(mock.getPeopleCalls.isEmpty)
    }

    @MainActor
    func test_People_AC_13_clearingFieldRestoresListWithoutRequests() async {
        let (mock, vm) = pagedPeople()
        vm.debounceWait = {}
        await vm.appear(visit: UUID())
        mock.searchPersonResponse = [makePerson(id: "r1", name: "Alice")]
        let people = vm.people
        let getCalls = mock.getPeopleCalls.count

        for cleared in ["", "   "] {
            await enterSearch(vm, "ali")
            XCTAssertEqual(vm.searchState, .results([makePerson(id: "r1", name: "Alice")]), "cleared with \(cleared.debugDescription)")
            let searches = mock.searchPersonCalls.count

            await enterSearch(vm, cleared)

            XCTAssertEqual(mock.searchPersonCalls.count, searches, "cleared with \(cleared.debugDescription)")
            XCTAssertEqual(vm.searchState, .inactive)
            XCTAssertFalse(vm.isSearchActive)
            XCTAssertEqual(vm.people, people)
            XCTAssertTrue(vm.hasMorePeople)
            XCTAssertEqual(mock.getPeopleCalls.count, getCalls)
        }
    }

    @MainActor
    func test_People_AC_14_staleResponseIsDropped() async {
        let mock = MockImmichClient()
        let old = makePerson(id: "old", name: "Al")
        let fresh = makePerson(id: "fresh", name: "Alice")
        let gate = SearchGate()
        mock.searchPersonHandler = { call in
            if call.name == "al" {
                await gate.wait()
                return [old]
            }
            return [fresh]
        }
        let vm = makeSearchVM(mock)

        vm.searchQuery = "al"
        vm.searchQueryDidChange()
        let alTask = vm.searchTask
        await pollUntil("al requested") { mock.searchPersonCalls.count == 1 }
        await enterSearch(vm, "ali")
        XCTAssertEqual(vm.searchState, .results([fresh]))

        gate.open()
        await alTask?.value

        XCTAssertEqual(vm.searchState, .results([fresh]))
        XCTAssertEqual(statsCalls(mock, "old"), 0)
        XCTAssertEqual(statsCalls(mock, "fresh"), 1)
    }

    @MainActor
    func test_People_AC_15_emptyAndFailedSearchStates() async {
        // No result: its own state, with a list that is empty too.
        let empty = MockImmichClient()
        empty.searchPersonResponse = []
        let emptyVM = makeSearchVM(empty)
        await enterSearch(emptyVM, "zzz")
        XCTAssertEqual(emptyVM.searchState, .empty)
        XCTAssertNotEqual(emptyVM.searchState, .inactive)
        XCTAssertTrue(emptyVM.isSearchActive)
        XCTAssertTrue(emptyVM.people.isEmpty)
        XCTAssertNil(emptyVM.errorMessage)

        // Failure: its own message; the paged list and its error stay as they were.
        let (mock, vm) = pagedPeople()
        vm.debounceWait = {}
        await vm.appear(visit: UUID())
        mock.searchPersonError = APIError.serverError(500, "boom")
        await enterSearch(vm, "ali")
        XCTAssertEqual(vm.searchState, .failed(UserFacingError.serverErrorMessage))
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2"])

        await enterSearch(vm, "")
        XCTAssertEqual(vm.searchState, .inactive)
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2"])
        XCTAssertEqual(mock.getPeopleCalls.count, 1)
    }

    @MainActor
    func test_People_AC_16_toggleHiddenRelaunchesSearchAndReloadsList() async {
        let (mock, vm) = pagedPeople()
        vm.debounceWait = {}
        await vm.appear(visit: UUID())
        mock.searchPersonResponse = [makePerson(id: "r1", name: "Alice")]
        await enterSearch(vm, "ali")
        mock.peopleResponsesByPage[1] = peoplePage(["p1", "h1"], hasNext: false)
        let getCalls = mock.getPeopleCalls.count

        await vm.toggleShowHidden()

        XCTAssertEqual(mock.searchPersonCalls, [
            PersonSearchCall(name: "ali", withHidden: false),
            PersonSearchCall(name: "ali", withHidden: true),
        ])
        XCTAssertEqual(mock.getPeopleCalls.count, getCalls + 1)
        XCTAssertEqual(mock.getPeopleCalls.last, PeopleCall(page: 1, withHidden: true))

        await enterSearch(vm, "")
        XCTAssertTrue(vm.showingHidden)
        XCTAssertEqual(vm.people.map(\.id), ["p1", "h1"])
        XCTAssertEqual(mock.getPeopleCalls.count, getCalls + 1)
    }

    @MainActor
    func test_People_AC_18_resultOutsidePagesOpensAndRenamesInPlace() async {
        let (mock, vm) = pagedPeople()
        vm.debounceWait = {}
        await vm.appear(visit: UUID())
        let first = makePerson(id: "r0", name: "Rita")
        let r = makePerson(id: "r", name: "Rick")
        mock.searchPersonResponse = [first, r]
        mock.searchMetadataResponse = assetPage(["a1"], next: nil)
        await enterSearch(vm, "ri")
        XCTAssertFalse(vm.people.contains { $0.id == "r" })

        await vm.select(vm.livePerson(r))
        XCTAssertEqual(mock.searchMetadataCalls.last?.personIds, ["r"])
        XCTAssertEqual(vm.personAssets.map(\.id), ["a1"])

        let searches = mock.searchPersonCalls.count
        await vm.rename(vm.livePerson(r), to: "X")
        XCTAssertEqual(vm.livePerson(r).name, "X")
        XCTAssertEqual(vm.searchResults.map(\.id), ["r0", "r"])
        XCTAssertEqual(vm.searchResults.map(\.name), ["Rita", "X"])
        XCTAssertEqual(mock.searchPersonCalls.count, searches)

        await vm.toggleFavorite(vm.livePerson(r))
        XCTAssertEqual(mock.lastUpdatePersonDto?.isFavorite, true)
        await vm.toggleFavorite(vm.livePerson(r))
        XCTAssertEqual(mock.lastUpdatePersonDto?.isFavorite, false)
        XCTAssertEqual(mock.searchPersonCalls.count, searches)
    }

    @MainActor
    func test_People_AC_20_resultShowsItsRealCount() async {
        let mock = MockImmichClient()
        mock.searchPersonResponse = [makePerson(id: "r", name: "Rick")]
        mock.personStatisticsResponse = ["r": PersonStatisticsResponseDto(assets: 7)]
        let vm = makeSearchVM(mock)
        XCTAssertNil(vm.statsByID["r"])

        await enterSearch(vm, "ri")

        XCTAssertEqual(vm.assetCount(for: "r"), 7)
    }

    @MainActor
    func test_People_AC_27_mergeDuringSearchRelaunchesSearch() async {
        let (mock, vm) = pagedPeople()
        vm.debounceWait = {}
        await vm.appear(visit: UUID())
        let r1 = makePerson(id: "p1", name: "Alice")
        let r2 = makePerson(id: "p2", name: "Alicia")
        mock.searchPersonHandler = { _ in mock.searchPersonCalls.count == 1 ? [r1, r2] : [r1] }
        await enterSearch(vm, "ali")
        XCTAssertEqual(vm.searchState, .results([r1, r2]))
        let getCalls = mock.getPeopleCalls.count

        // A refused merge relaunches nothing.
        mock.peopleError = APIError.serverError(500, "boom")
        await vm.merge(["p2"], into: r1)
        mock.peopleError = nil
        XCTAssertEqual(mock.searchPersonCalls.count, 1)
        XCTAssertEqual(vm.searchState, .results([r1, r2]))

        await vm.merge(["p2"], into: r1)

        XCTAssertEqual(mock.searchPersonCalls, [
            PersonSearchCall(name: "ali", withHidden: false),
            PersonSearchCall(name: "ali", withHidden: false),
        ])
        XCTAssertEqual(vm.searchState, .results([r1]))
        XCTAssertEqual(mock.getPeopleCalls.count, getCalls + 1)
        XCTAssertEqual(mock.getPeopleCalls.last, PeopleCall(page: 1, withHidden: false))
    }

    @MainActor
    func test_People_AC_29_refreshInSearchModeRelaunchesWithoutList() async {
        let (mock, vm) = pagedPeople()
        vm.debounceWait = {}
        await vm.appear(visit: UUID())
        mock.searchPersonResponse = [makePerson(id: "r1", name: "Alice"), makePerson(id: "r2", name: "Alicia")]
        mock.personStatisticsResponse = ["r1": PersonStatisticsResponseDto(assets: 5), "r2": PersonStatisticsResponseDto(assets: 3)]
        await enterSearch(vm, "ali")
        await vm.toggleShowHidden()
        XCTAssertEqual(mock.searchPersonCalls.last, PersonSearchCall(name: "ali", withHidden: true))
        let searches = mock.searchPersonCalls.count
        let getCalls = mock.getPeopleCalls.count
        XCTAssertEqual(statsCalls(mock, "r1"), 1)
        XCTAssertEqual(statsCalls(mock, "r2"), 1)

        mock.personStatisticsResponse["r1"] = PersonStatisticsResponseDto(assets: 6)
        await vm.refresh()

        XCTAssertEqual(mock.searchPersonCalls.count, searches + 1)
        XCTAssertEqual(mock.searchPersonCalls.last, PersonSearchCall(name: "ali", withHidden: true))
        XCTAssertEqual(statsCalls(mock, "r1"), 2)
        XCTAssertEqual(statsCalls(mock, "r2"), 2)
        XCTAssertEqual(vm.assetCount(for: "r1"), 6)
        XCTAssertEqual(mock.getPeopleCalls.count, getCalls)
    }

    @MainActor
    func test_People_AC_41_searchAsksOnlyUnknownCounts() async {
        let mock = MockImmichClient()
        mock.searchPersonResponse = [makePerson(id: "r1", name: "Alice"), makePerson(id: "r2", name: "Alicia")]
        mock.personStatisticsResponse = ["r1": PersonStatisticsResponseDto(assets: 99), "r2": PersonStatisticsResponseDto(assets: 2)]
        let vm = makeSearchVM(mock)
        vm.statsByID["r1"] = 5

        await enterSearch(vm, "ali")

        XCTAssertEqual(statsCalls(mock, "r1"), 0)
        XCTAssertEqual(statsCalls(mock, "r2"), 1)
        XCTAssertEqual(vm.assetCount(for: "r1"), 5)
        XCTAssertEqual(vm.assetCount(for: "r2"), 2)
    }

    @MainActor
    func test_People_AC_42_debounceSendsOneRequest() async {
        let mock = MockImmichClient()
        let r = makePerson(id: "r", name: "Alice")
        mock.searchPersonResponse = [r]
        let vm = makeVM(mock)
        let latch = TestLatch()
        let entered = TestBox(0)
        vm.debounceWait = { @MainActor in
            entered.value += 1
            try await latch.wait()
        }

        for (index, text) in ["a", "al", "ali"].enumerated() {
            vm.searchQuery = text
            vm.searchQueryDidChange()
            await pollUntil("debounce wait \(index + 1) entered") { entered.value == index + 1 }
            XCTAssertTrue(mock.searchPersonCalls.isEmpty)
        }
        latch.open()
        await vm.searchTask?.value

        XCTAssertEqual(mock.searchPersonCalls, [PersonSearchCall(name: "ali", withHidden: false)])
        XCTAssertEqual(vm.searchState, .results([r]))
    }

    @MainActor
    func test_People_AC_43_resultsKeepServerOrderInOneList() async {
        let mock = MockImmichClient()
        let r1 = makePerson(id: "r1", name: "Alice")
        let r2 = makePerson(id: "r2", name: "Alicia", isFavorite: true)
        mock.searchPersonResponse = [r1, r2]
        mock.personStatisticsResponse = ["r1": PersonStatisticsResponseDto(assets: 2), "r2": PersonStatisticsResponseDto(assets: 9)]
        let vm = makeSearchVM(mock)

        await enterSearch(vm, "ali")

        XCTAssertEqual(vm.searchState, .results([r1, r2]))
        XCTAssertEqual(vm.searchResults.map(\.id), ["r1", "r2"])
    }

    @MainActor
    func test_People_AC_44_resultRowNeverRequestsNextPage() async {
        let (mock, vm) = pagedPeople()
        vm.debounceWait = {}
        await vm.appear(visit: UUID())
        XCTAssertEqual(vm.lastDisplayedPersonID, "p2")
        XCTAssertTrue(vm.hasMorePeople)
        mock.searchPersonResponse = [makePerson(id: "p2", name: "p2")]
        await enterSearch(vm, "p")
        let getCalls = mock.getPeopleCalls.count

        await vm.personRowAppeared("p2")
        XCTAssertEqual(mock.getPeopleCalls.count, getCalls)

        // The same row asks for page 2 once the search is left.
        await enterSearch(vm, "")
        await vm.personRowAppeared("p2")
        XCTAssertEqual(mock.getPeopleCalls.last?.page, 2)
    }

    @MainActor
    func test_People_AC_45_sameVisitKeepsSearchNewVisitClearsIt() async {
        let (mock, vm) = pagedPeople()
        vm.debounceWait = {}
        mock.personStatisticsResponse = ["p1": PersonStatisticsResponseDto(assets: 5)]
        let r1 = makePerson(id: "r1", name: "Alice")
        mock.searchPersonResponse = [r1]
        let visit = UUID()
        await vm.appear(visit: visit)
        await enterSearch(vm, "ali")
        let searches = mock.searchPersonCalls.count
        let getCalls = mock.getPeopleCalls.count
        let stats = mock.personStatisticsCalls.count

        await vm.appear(visit: visit)
        XCTAssertEqual(vm.searchQuery, "ali")
        XCTAssertEqual(vm.searchState, .results([r1]))
        XCTAssertEqual(mock.searchPersonCalls.count, searches)
        XCTAssertEqual(mock.getPeopleCalls.count, getCalls)
        XCTAssertEqual(mock.personStatisticsCalls.count, stats)

        await vm.appear(visit: UUID())
        XCTAssertEqual(vm.searchQuery, "")
        XCTAssertEqual(vm.searchState, .inactive)
        XCTAssertEqual(mock.getPeopleCalls.count, getCalls + 1)
        XCTAssertEqual(mock.getPeopleCalls.last, PeopleCall(page: 1, withHidden: false))
        XCTAssertEqual(statsCalls(mock, "p1"), 2)
        XCTAssertEqual(statsCalls(mock, "p2"), 2)
        XCTAssertEqual(mock.searchPersonCalls.count, searches)
    }

    @MainActor
    func test_People_AC_46_searchWorksInReadOnlyMode() async {
        let mock = MockImmichClient()
        let r = makePerson(id: "r", name: "Alice")
        mock.searchPersonResponse = [r]
        let vm = PeopleViewModel(client: ReadOnlyGuardClient(inner: mock, isEnabled: { true }))
        vm.debounceWait = {}

        await enterSearch(vm, "ali")

        XCTAssertEqual(mock.searchPersonCalls, [PersonSearchCall(name: "ali", withHidden: false)])
        XCTAssertEqual(vm.searchState, .results([r]))
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_People_AC_47_clearingDropsInFlightResponse() async {
        let (mock, vm) = pagedPeople()
        vm.debounceWait = {}
        await vm.appear(visit: UUID())
        let gate = SearchGate()
        let r = makePerson(id: "r", name: "Alice")
        mock.searchPersonHandler = { _ in
            await gate.wait()
            return [r]
        }
        vm.searchQuery = "ali"
        vm.searchQueryDidChange()
        let task = vm.searchTask
        await pollUntil("ali requested") { mock.searchPersonCalls.count == 1 }
        let getCalls = mock.getPeopleCalls.count

        vm.searchQuery = ""
        vm.searchQueryDidChange()
        gate.open()
        await task?.value

        XCTAssertEqual(vm.searchState, .inactive)
        XCTAssertEqual(vm.people.map(\.id), ["p1", "p2"])
        XCTAssertEqual(mock.getPeopleCalls.count, getCalls)
        XCTAssertEqual(mock.searchPersonCalls.count, 1)
        XCTAssertEqual(statsCalls(mock, "r"), 0)
    }

    @MainActor
    func test_People_AC_48_staleRelaunchIsDroppedByGeneration() async {
        let mock = MockImmichClient()
        let a1 = makePerson(id: "a1", name: "Alice")
        let s1 = makePerson(id: "s1", name: "Stale one")
        let b1 = makePerson(id: "b1", name: "Bob")
        let s2 = makePerson(id: "s2", name: "Stale two")
        let gate1 = SearchGate()
        let gate2 = SearchGate()
        let calls = TestBox(0)
        mock.searchPersonHandler = { call in
            calls.value += 1
            if calls.value == 2 {
                await gate1.wait()
                return [a1, s1]
            }
            if calls.value == 4 {
                await gate2.wait()
                return [b1, s2]
            }
            return call.name == "ali" ? [a1] : [b1]
        }
        let vm = makeSearchVM(mock)
        await enterSearch(vm, "ali")
        XCTAssertEqual(vm.searchState, .results([a1]))

        // A relaunch runs in its caller's task, not in `searchTask`: a new
        // name is the only thing that can drop it, and the generation does.
        let relaunch1 = Task { await vm.refresh() }
        await pollUntil("first relaunch requested") { mock.searchPersonCalls.count == 2 }
        await enterSearch(vm, "bob")
        XCTAssertEqual(vm.searchState, .results([b1]))
        gate1.open()
        await relaunch1.value
        XCTAssertEqual(vm.searchState, .results([b1]))
        XCTAssertEqual(statsCalls(mock, "s1"), 0)
        XCTAssertEqual(statsCalls(mock, "a1"), 1)

        // Clearing the field drops a relaunch in flight too.
        let relaunch2 = Task { await vm.refresh() }
        await pollUntil("second relaunch requested") { mock.searchPersonCalls.count == 4 }
        await enterSearch(vm, "")
        gate2.open()
        await relaunch2.value
        XCTAssertEqual(vm.searchState, .inactive)
        XCTAssertEqual(statsCalls(mock, "s2"), 0)
        XCTAssertEqual(statsCalls(mock, "b1"), 1)
        XCTAssertEqual(mock.searchPersonCalls.count, 4)
    }
}