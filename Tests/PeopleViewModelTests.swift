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
}