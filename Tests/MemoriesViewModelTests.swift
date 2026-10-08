import XCTest
@testable import ImmichSwiftUI

final class MemoriesViewModelTests: XCTestCase {

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

    private func searchPage(ids: [String], nextPage: String?) -> SearchResponseDto {
        SearchResponseDto(
            assets: SearchAssetResponseDto(count: ids.count, items: ids.map(asset), nextPage: nextPage)
        )
    }

    private func makeMemory(id: String, year: Int, assetCount: Int = 2, isSaved: Bool = false) -> MemoryResponseDto {
        let assets = (0..<assetCount).map { i in
            AssetResponseDto(
                id: "\(id)-a\(i)", type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
                duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2024-07-01T00:00:00.000Z",
                ownerId: "owner", originalPath: "/x\(i).jpg", originalFileName: "x\(i).jpg",
                fileCreatedAt: "2024-07-01T00:00:00.000Z", fileModifiedAt: "2024-07-01T00:00:00.000Z",
                updatedAt: "2024-07-01T00:00:00.000Z", isFavorite: false, isArchived: false,
                isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false
            )
        }
        return MemoryResponseDto(
            id: id, createdAt: "2024-07-01T00:00:00.000Z", updatedAt: "2024-07-01T00:00:00.000Z",
            memoryAt: "\(year)-07-01T00:00:00.000Z", ownerId: "owner", type: .on_this_day,
            data: OnThisDayDto(year: year), assets: assets, isSaved: isSaved,
            showAt: nil, hideAt: nil, seenAt: nil, deletedAt: nil
        )
    }

    private func makeMemory(
        id: String,
        year: Int,
        memoryAt: String,
        assetTypes: [String],
        durations: [Int?],
        favorites: [Bool],
        exifs: [ExifResponseDto?]
    ) -> MemoryResponseDto {
        let assets = assetTypes.indices.map { i in
            AssetResponseDto(
                id: "\(id)-a\(i)", type: assetTypes[i], thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
                duration: durations[i], hasMetadata: true, width: 100, height: 100, createdAt: "2024-07-01T00:00:00.000Z",
                ownerId: "owner", originalPath: "/x\(i).jpg", originalFileName: "x\(i).jpg",
                fileCreatedAt: "2024-07-01T00:00:00.000Z", fileModifiedAt: "2024-07-01T00:00:00.000Z",
                updatedAt: "2024-07-01T00:00:00.000Z", isFavorite: favorites[i], isArchived: false,
                isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false,
                exifInfo: exifs[i]
            )
        }
        return MemoryResponseDto(
            id: id, createdAt: "2024-07-01T00:00:00.000Z", updatedAt: "2024-07-01T00:00:00.000Z",
            memoryAt: memoryAt, ownerId: "owner", type: .on_this_day,
            data: OnThisDayDto(year: year), assets: assets, isSaved: false,
            showAt: nil, hideAt: nil, seenAt: nil, deletedAt: nil
        )
    }

    @MainActor
    func test_load_mapsServerList() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022), makeMemory(id: "m2", year: 2023)]
        let vm = MemoriesViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.memories.count, 2)
        XCTAssertEqual(vm.memories.map(\.id), ["m2", "m1"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func test_load_failure_setsError() async {
        let mock = MockImmichClient()
        let vm = MemoriesViewModel(client: mock)

        mock.globalError = APIError.serverError(500, "boom")
        await vm.load()

        XCTAssertTrue(vm.memories.isEmpty)
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
    }

    @MainActor
    func test_load_emptyKeepsEmptyList() async {
        let mock = MockImmichClient()
        let vm = MemoriesViewModel(client: mock)

        await vm.load()

        XCTAssertTrue(vm.memories.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_load_failureKeepsPreviousList() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022)]
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        mock.memoriesResponse = nil
        mock.globalError = APIError.serverError(500, "boom")
        await vm.load()

        XCTAssertEqual(vm.memories.map(\.id), ["m1"])
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
    }

    @MainActor
    func test_load_failure_usesDedicatedMemoriesErrorChannel() async {
        let mock = MockImmichClient()
        mock.memoriesError = APIError.serverError(500, "memories boom")
        let vm = MemoriesViewModel(client: mock)

        await vm.load()

        XCTAssertTrue(vm.memories.isEmpty)
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
    }

    // MARK: - Save / unsave

    @MainActor
    func test_saveMemory_sendsIsSavedTrueAndUpdatesTheRow() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022), makeMemory(id: "m2", year: 2023)]
        mock.updateMemoryResponse = makeMemory(id: "m1", year: 2022, isSaved: true)
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        await vm.saveMemory(id: "m1")

        XCTAssertEqual(mock.lastUpdateMemoryId, "m1")
        XCTAssertEqual(mock.lastUpdateMemoryDto?.isSaved, true)
        XCTAssertEqual(vm.memories.first { $0.id == "m1" }?.isSaved, true)
        XCTAssertEqual(vm.memories.map(\.id), ["m2", "m1"], "saving must not reorder the list")
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_unsaveMemory_sendsIsSavedFalse() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022, isSaved: true)]
        mock.updateMemoryResponse = makeMemory(id: "m1", year: 2022)
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        await vm.unsaveMemory(id: "m1")

        XCTAssertEqual(mock.lastUpdateMemoryDto?.isSaved, false)
        XCTAssertEqual(vm.memories.first?.isSaved, false)
    }

    /// A failed save must not leave the bookmark claiming the server accepted
    /// it — the flag is only ever taken from the server's response.
    @MainActor
    func test_saveMemory_failureKeepsTheRowAndReportsIt() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022)]
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        mock.memoriesError = APIError.serverError(500, "nope")
        await vm.saveMemory(id: "m1")

        XCTAssertEqual(vm.memories.first?.isSaved, false)
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
    }

    // MARK: - Create

    /// The create payload is the whole contract: `data.year` and `memoryAt`
    /// must agree (both required server-side), the type is the enum's only
    /// value, and the memory is born saved — the server's cleanup job deletes
    /// unsaved memories older than 30 days.
    @MainActor
    func test_createMemory_sendsYearTimestampAndSavedFlag() async {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = searchPage(ids: ["a1", "a2", "a3"], nextPage: nil)
        let vm = MemoriesViewModel(client: mock)
        await vm.beginPicking()
        vm.toggleSelection(id: "a3")
        vm.toggleSelection(id: "a1")
        vm.memoryDate = Calendar.current.date(from: DateComponents(year: 2019, month: 5, day: 4))!

        await vm.createMemory()

        let dto = try? XCTUnwrap(mock.lastCreateMemoryDto)
        XCTAssertEqual(dto?.assetIds, ["a1", "a3"], "the grid order is what the payload carries")
        XCTAssertEqual(dto?.data.year, 2019)
        XCTAssertEqual(dto?.type, .on_this_day)
        XCTAssertEqual(dto?.isSaved, true, "an unsaved memory is deleted by the server after 30 days")
        XCTAssertEqual(dto?.memoryAt.hasPrefix("2019-05-04T"), true, "memoryAt carries the picked day")
        XCTAssertFalse(vm.showCreate, "a successful create closes the sheet")
        XCTAssertTrue(vm.selectedIds.isEmpty, "the picker does not keep the selection")
    }

    /// The picked day must survive the round trip, whatever the device's UTC
    /// offset: the anchor is that day's UTC midnight and the card reads it back
    /// in UTC, so "May 4" picked in Tokyo must still read "May 4". Formatting the
    /// picker's instant directly shifted the day west by one for every positive
    /// offset (the create test caught it; this one pins the reason).
    func test_memoryAtString_anchorsThePickedDayAtUTCMidnight() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let pickedInTokyo = tokyo.date(from: DateComponents(year: 2019, month: 5, day: 4, hour: 9))!

        XCTAssertEqual(
            MemoriesViewModel.memoryAtString(for: pickedInTokyo, calendar: tokyo),
            "2019-05-04T00:00:00.000Z"
        )
        XCTAssertEqual(MemoriesViewModel.dayComponents(of: pickedInTokyo, calendar: tokyo).year, 2019)

        let memory = MemoryResponseDto(
            id: "m1", createdAt: "2019-05-04T00:00:00.000Z", updatedAt: "2019-05-04T00:00:00.000Z",
            memoryAt: MemoriesViewModel.memoryAtString(for: pickedInTokyo, calendar: tokyo),
            ownerId: "owner", type: .on_this_day, data: OnThisDayDto(year: 2019), assets: [],
            isSaved: true, showAt: nil, hideAt: nil, seenAt: nil, deletedAt: nil
        )
        XCTAssertEqual(MemoryCardPresentation.dayLabel(for: memory, locale: enUS), "May 4")
    }

    @MainActor
    func test_createMemory_withoutSelectionSendsNothing() async {
        let mock = MockImmichClient()
        let vm = MemoriesViewModel(client: mock)

        await vm.createMemory()

        XCTAssertNil(mock.lastCreateMemoryDto)
    }

    @MainActor
    func test_createMemory_failureKeepsSheetOpenAndTheSelection() async {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = searchPage(ids: ["a1"], nextPage: nil)
        let vm = MemoriesViewModel(client: mock)
        await vm.beginPicking()
        vm.toggleSelection(id: "a1")
        vm.showCreate = true
        mock.memoriesError = APIError.serverError(400, "bad year")

        await vm.createMemory()

        XCTAssertTrue(vm.showCreate, "a failed create must leave the sheet up for a retry")
        XCTAssertEqual(vm.selectedIds, ["a1"])
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
    }

    // MARK: - Delete

    @MainActor
    func test_deleteMemory_dropsTheRow() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022), makeMemory(id: "m2", year: 2023)]
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        await vm.deleteMemory(id: "m1")

        XCTAssertEqual(mock.lastDeleteMemoryId, "m1")
        XCTAssertEqual(vm.memories.map(\.id), ["m2"])
    }

    @MainActor
    func test_deleteMemory_failureKeepsTheRowAndReportsIt() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022)]
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        mock.memoriesError = APIError.serverError(403, "forbidden")
        await vm.deleteMemory(id: "m1")

        XCTAssertEqual(vm.memories.map(\.id), ["m1"])
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
    }

    // MARK: - Assets

    /// `PUT /api/memories/{id}/assets` answers per-asset results, not the
    /// memory — so the member list has to come back from the server.
    @MainActor
    func test_addAssets_sendsIdsAndRefreshesTheMemberList() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022, assetCount: 2)]
        mock.memoryDetailResponses["m1"] = makeMemory(id: "m1", year: 2022, assetCount: 3)
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        let added = await vm.addAssets(toMemoryId: "m1", assetIds: ["new1"])

        XCTAssertTrue(added)
        XCTAssertEqual(mock.lastAddAssetsMemoryId, "m1")
        XCTAssertEqual(mock.lastAddAssetsMemoryIds, ["new1"])
        XCTAssertEqual(vm.memories.first?.assets.count, 3)
    }

    @MainActor
    func test_addAssets_failureReportsItAndKeepsTheSheetOpen() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022, assetCount: 2)]
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        mock.memoriesError = APIError.serverError(400, "not yours")
        let added = await vm.addAssets(toMemoryId: "m1", assetIds: ["new1"])

        XCTAssertFalse(added)
        XCTAssertEqual(vm.memories.first?.assets.count, 2)
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
    }

    /// Dropping the last photo deletes the memory from the client's point of
    /// view: `GET /api/memories` filters out memories with no asset, so the
    /// screen showing it must close instead of holding a memory that no longer
    /// exists.
    @MainActor
    func test_removeAssets_lastPhotoDropsTheMemoryAndClosesTheScreen() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022, assetCount: 1)]
        mock.memoryDetailResponses["m1"] = makeMemory(id: "m1", year: 2022, assetCount: 0)
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        let stillExists = await vm.removeAssets(fromMemoryId: "m1", assetIds: ["m1-a0"])

        XCTAssertFalse(stillExists, "the caller must be told to dismiss")
        XCTAssertTrue(vm.memories.isEmpty)
    }

    @MainActor
    func test_removeAssets_keepsTheMemoryWhilePhotosRemain() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022, assetCount: 3)]
        mock.memoryDetailResponses["m1"] = makeMemory(id: "m1", year: 2022, assetCount: 2)
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        let stillExists = await vm.removeAssets(fromMemoryId: "m1", assetIds: ["m1-a0"])

        XCTAssertTrue(stillExists)
        XCTAssertEqual(mock.lastRemoveAssetsMemoryIds, ["m1-a0"])
        XCTAssertEqual(vm.memories.first?.assets.count, 2)
    }

    @MainActor
    func test_removeAssets_failureKeepsTheScreenAndReportsIt() async {
        let mock = MockImmichClient()
        mock.memoriesResponse = [makeMemory(id: "m1", year: 2022, assetCount: 1)]
        let vm = MemoriesViewModel(client: mock)
        await vm.load()

        mock.memoriesError = APIError.serverError(500, "nope")
        let stillExists = await vm.removeAssets(fromMemoryId: "m1", assetIds: ["m1-a0"])

        XCTAssertTrue(stillExists, "a failed removal must not dismiss the screen")
        XCTAssertEqual(vm.memories.first?.assets.count, 1)
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
    }

    // MARK: - Picker

    @MainActor
    func test_beginPicking_loadsFirstPageAndClearsSelection() async {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = searchPage(ids: ["a1", "a2"], nextPage: nil)
        let vm = MemoriesViewModel(client: mock)

        await vm.beginPicking()
        vm.toggleSelection(id: "a1")
        await vm.beginPicking()

        XCTAssertEqual(vm.recentAssets.map(\.id), ["a1", "a2"])
        XCTAssertTrue(vm.selectedIds.isEmpty, "reopening the picker must not resurrect an old selection")
        XCTAssertEqual(mock.lastMetadataSearchDto?.order, "desc", "newest first")
    }

    @MainActor
    func test_orderedSelection_followsGridOrderNotSetOrder() async {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = searchPage(ids: ["newest", "middle", "oldest"], nextPage: nil)
        let vm = MemoriesViewModel(client: mock)
        await vm.beginPicking()

        vm.toggleSelection(id: "oldest")
        vm.toggleSelection(id: "newest")

        XCTAssertEqual(vm.orderedSelection, ["newest", "oldest"])
    }

    // MARK: - MemoryCardPresentation

    private func now(year: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: 6, day: 15))!
    }

    private let enUS = Locale(identifier: "en_US")

    func test_presentation_yearsAgoCount() {
        let now = now(year: 2026)
        XCTAssertEqual(MemoryCardPresentation.yearsAgoCount(year: 2023, now: now), 3)
        XCTAssertEqual(MemoryCardPresentation.yearsAgoCount(year: 2025, now: now), 1)
        XCTAssertNil(MemoryCardPresentation.yearsAgoCount(year: 2026, now: now))
        XCTAssertNil(MemoryCardPresentation.yearsAgoCount(year: 2027, now: now))
    }

    func test_presentation_yearsAgoText_guardsNonPastCount() {
        XCTAssertNil(MemoryCardPresentation.yearsAgoText(count: 0, locale: enUS))
        XCTAssertNil(MemoryCardPresentation.yearsAgoText(count: -2, locale: enUS))
    }

    func test_presentation_dayLabel_usesMemoryDay() {
        let memory = makeMemory(id: "m", year: 2023, memoryAt: "2023-07-01T00:00:00.000Z",
                                assetTypes: ["IMAGE"], durations: [nil], favorites: [false], exifs: [nil])
        let date = MemoryCardPresentation.parseMemoryAt("2023-07-01T00:00:00.000Z")!
        let expectedDay = MemoryCardPresentation.monthDayLabel(from: date, locale: enUS)
        XCTAssertEqual(MemoryCardPresentation.dayLabel(for: memory, locale: enUS), expectedDay)
    }

    func test_presentation_dayLabel_plainSecondsTimestampParses() {
        let memory = makeMemory(id: "m", year: 2023, memoryAt: "2023-07-01T00:00:00Z",
                                assetTypes: ["IMAGE"], durations: [nil], favorites: [false], exifs: [nil])
        let date = MemoryCardPresentation.parseMemoryAt("2023-07-01T00:00:00Z")!
        let expectedDay = MemoryCardPresentation.monthDayLabel(from: date, locale: enUS)
        XCTAssertEqual(MemoryCardPresentation.dayLabel(for: memory, locale: enUS), expectedDay)
    }

    func test_presentation_dayLabel_malformedMemoryAt_returnsNil() {
        let memory = makeMemory(id: "m", year: 2023, memoryAt: "not-a-date",
                                assetTypes: ["IMAGE"], durations: [nil], favorites: [false], exifs: [nil])
        XCTAssertNil(MemoryCardPresentation.dayLabel(for: memory))
    }

    func test_presentation_monthDayLabel_usesRequestedLocale() {
        let date = MemoryCardPresentation.parseMemoryAt("2023-07-01T00:00:00.000Z")!
        XCTAssertEqual(MemoryCardPresentation.monthDayLabel(from: date, locale: enUS), "July 1")
        XCTAssertEqual(MemoryCardPresentation.monthDayLabel(from: date, locale: Locale(identifier: "fr_FR")), "1 juillet")
    }

    func test_presentation_mediaCount_mixed() {
        let memory = makeMemory(id: "m", year: 2023, memoryAt: "2023-07-01T00:00:00.000Z",
                                assetTypes: ["IMAGE", "IMAGE", "VIDEO", "VIDEO", "IMAGE"],
                                durations: [nil, nil, 500, 61, nil], favorites: [false, true, false, false, false],
                                exifs: [nil, nil, nil, nil, nil])
        let (photos, videos) = MemoryCardPresentation.mediaCount(for: memory)
        XCTAssertEqual(photos, 3)
        XCTAssertEqual(videos, 2)
    }

    func test_presentation_mediaCount_allVideos() {
        let memory = makeMemory(id: "v", year: 2023, memoryAt: "2023-07-01T00:00:00.000Z",
                                assetTypes: ["VIDEO", "VIDEO"], durations: [nil, nil],
                                favorites: [false, false], exifs: [nil, nil])
        let (photos, videos) = MemoryCardPresentation.mediaCount(for: memory)
        XCTAssertEqual(photos, 0)
        XCTAssertEqual(videos, 2)
    }

    func test_presentation_mediaCount_empty_isZeroZero() {
        let memory = makeMemory(id: "m", year: 2023, memoryAt: "2023-07-01T00:00:00.000Z",
                                assetTypes: [], durations: [], favorites: [], exifs: [])
        let (photos, videos) = MemoryCardPresentation.mediaCount(for: memory)
        XCTAssertEqual(photos, 0)
        XCTAssertEqual(videos, 0)
        XCTAssertNil(MemoryCardPresentation.mediaCountLabel(for: memory))
    }

    func test_presentation_mediaCount_empty_isNil() {
        let memory = makeMemory(id: "m", year: 2023, memoryAt: "2023-07-01T00:00:00.000Z",
                                assetTypes: [], durations: [], favorites: [], exifs: [])
        XCTAssertNil(MemoryCardPresentation.mediaCountLabel(for: memory))
    }

    func test_presentation_location_prefersCityAndCountry() {
        let exif = ExifResponseDto(city: "Paris", country: "France")
        let memory = makeMemory(id: "m", year: 2023, memoryAt: "2023-07-01T00:00:00.000Z",
                                assetTypes: ["IMAGE"], durations: [nil], favorites: [false], exifs: [exif])
        XCTAssertEqual(MemoryCardPresentation.locationLabel(for: memory), "Paris, France")
    }

    func test_presentation_location_fallsBackAcrossAssets() {
        let countryOnly = ExifResponseDto(city: nil, country: "Japan")
        let memory = makeMemory(id: "m", year: 2023, memoryAt: "2023-07-01T00:00:00.000Z",
                                assetTypes: ["IMAGE", "IMAGE"], durations: [nil, nil],
                                favorites: [false, false], exifs: [nil, countryOnly])
        XCTAssertEqual(MemoryCardPresentation.locationLabel(for: memory), "Japan")
    }

    func test_presentation_location_trimsWhitespace() {
        let exif = ExifResponseDto(city: "  Paris  ", country: " ")
        let memory = makeMemory(id: "m", year: 2023, memoryAt: "2023-07-01T00:00:00.000Z",
                                assetTypes: ["IMAGE"], durations: [nil], favorites: [false], exifs: [exif])
        XCTAssertEqual(MemoryCardPresentation.locationLabel(for: memory), "Paris")
    }

    func test_presentation_location_noExif_isNil() {
        let memory = makeMemory(id: "m", year: 2023, memoryAt: "2023-07-01T00:00:00.000Z",
                                assetTypes: ["IMAGE"], durations: [nil], favorites: [false], exifs: [nil])
        XCTAssertNil(MemoryCardPresentation.locationLabel(for: memory))
    }
}
