import XCTest
@testable import ImmichSwiftUI

@MainActor
final class SearchViewModelTests: XCTestCase {

    /// Builds an `AssetResponseDto` suitable for search results.
    private func makeAsset(id: String, city: String? = nil) -> AssetResponseDto {
        var exif: ExifResponseDto? = nil
        if let city {
            exif = ExifResponseDto()
            exif?.city = city
        }
        return AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T00:00:00.000Z", ownerId: "owner",
            originalPath: "/\(id).jpg", originalFileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            updatedAt: "2024-07-01T00:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false,
            isOffline: false, visibility: "timeline", checksum: "x", isEdited: false,
            exifInfo: exif
        )
    }

    /// Builds an `AssetResponseDto` with full location EXIF for the cities flow.
    private func makeCityAsset(
        id: String, city: String, state: String? = nil, country: String? = nil,
        dateTimeOriginal: String? = nil
    ) -> AssetResponseDto {
        var exif = ExifResponseDto()
        exif.city = city
        exif.state = state
        exif.country = country
        exif.dateTimeOriginal = dateTimeOriginal
        return AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: dateTimeOriginal ?? "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: dateTimeOriginal ?? "2024-07-01T00:00:00.000Z", ownerId: "owner",
            originalPath: "/\(id).jpg", originalFileName: "\(id).jpg",
            fileCreatedAt: dateTimeOriginal ?? "2024-07-01T00:00:00.000Z",
            fileModifiedAt: dateTimeOriginal ?? "2024-07-01T00:00:00.000Z",
            updatedAt: dateTimeOriginal ?? "2024-07-01T00:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false,
            isOffline: false, visibility: "timeline", checksum: "x", isEdited: false,
            exifInfo: exif
        )
    }

    private func makeMock(items: [AssetResponseDto] = [], nextPage: String? = nil) -> MockImmichClient {
        let mock = MockImmichClient()
        let resp = SearchResponseDto(
            assets: SearchAssetResponseDto(count: items.count, items: items, nextPage: nextPage)
        )
        mock.searchMetadataResponse = resp
        mock.smartSearchResponse = resp
        return mock
    }

    // MARK: - AC-401: searchMetadata success + error path

    func test_AC_401_searchMetadata_success() async {
        let mock = makeMock(items: [makeAsset(id: "a1"), makeAsset(id: "a2")])
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.query = "Canon"

        await vm.search()

        XCTAssertEqual(mock.lastMetadataSearchDto?.query, "Canon")
        XCTAssertEqual(vm.results.count, 2)
        XCTAssertEqual(vm.results.map(\.id), ["a1", "a2"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.canLoadMore) // nextPage nil
        XCTAssertTrue(vm.hasSearched)
    }

    func test_AC_401_searchMetadata_error() async {
        let mock = makeMock()
        struct Boom: Error {}
        mock.searchMetadataError = Boom()
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.query = "Canon"

        await vm.search()

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - AC-401b: searchSmart success + error path

    func test_AC_401b_searchSmart_success() async {
        let mock = makeMock(items: [makeAsset(id: "s1"), makeAsset(id: "s2")])
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .smart
        vm.query = "chien sur une plage"

        await vm.search()

        XCTAssertEqual(mock.lastSmartSearchDto?.query, "chien sur une plage")
        XCTAssertEqual(vm.results.count, 2)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(mock.requestCount, 1)
    }

    func test_AC_401b_searchSmart_error() async {
        let mock = makeMock()
        struct Boom: Error {}
        mock.smartSearchError = Boom()
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .smart
        vm.query = "dog"

        await vm.search()

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Cancellation must not surface as a user-visible error

    /// A `URLError(.cancelled)` (what `URLSession.data(for:)` throws when the
    /// enclosing debounced Task is cancelled mid-flight) must be swallowed —
    /// it is a normal outcome of typing/clearing/recents, never an error.
    func test_searchCancelled_doesNotSurfaceError_urlError() async {
        let mock = makeMock()
        mock.smartSearchError = URLError(.cancelled)
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .smart
        vm.query = "beach"

        await vm.search()

        XCTAssertNil(vm.errorMessage, "URLError(.cancelled) must not surface as an error")
        XCTAssertTrue(vm.hasSearched, "the search attempt was registered")
    }

    /// A cooperative `CancellationError` (e.g. `Task.cancel()` propagating into
    /// a non-URLSession await) must likewise be swallowed.
    func test_searchCancelled_doesNotSurfaceError_cancellationError() async {
        let mock = makeMock()
        mock.smartSearchError = CancellationError()
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .smart
        vm.query = "beach"

        await vm.search()

        XCTAssertNil(vm.errorMessage, "CancellationError must not surface as an error")
    }

    // MARK: - AC-402: dto dispatched selon mode

    func test_AC_402_metadata_dto_dispatched() async {
        let mock = makeMock(items: [makeAsset(id: "m1")])
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.query = "Canon"

        await vm.search()

        XCTAssertEqual(mock.lastMetadataSearchDto?.query, "Canon")
        XCTAssertNil(mock.lastSmartSearchDto)
        XCTAssertEqual(mock.requestCount, 1)
    }

    func test_AC_402_smart_dto_dispatched() async {
        let mock = makeMock(items: [makeAsset(id: "s1")])
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .smart
        vm.query = "chien sur une plage"

        await vm.search()

        XCTAssertEqual(mock.lastSmartSearchDto?.query, "chien sur une plage")
        XCTAssertNil(mock.lastMetadataSearchDto)
        XCTAssertEqual(mock.requestCount, 1)
    }

    // MARK: - AC-404a: loadExplore success path (Places via /search/cities)

    func test_AC_404a_loadExplore() async {
        let mock = MockImmichClient()
        mock.citiesResponse = [
            makeCityAsset(id: "t1", city: "Paris", country: "France")
        ]
        let vm = SearchViewModel(client: mock)

        await vm.loadExplore()

        XCTAssertEqual(mock.requestCount, 2, "1 cities call + 1 statistics call")
        XCTAssertEqual(vm.explorePlaces.count, 1)
        XCTAssertEqual(vm.explorePlaces.first?.city, "Paris")
        XCTAssertEqual(vm.explorePlaces.first?.country, "France")
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - AC-404b: searchByExplore resets state + dispatches the right EXIF field

    func test_AC_404b_cityTapDispatchesCity() async {
        let mock = makeMock(items: [makeAsset(id: "p1"), makeAsset(id: "p2")])
        let vm = SearchViewModel(client: mock)

        await vm.searchByExplore(field: .city, value: "Paris")

        XCTAssertEqual(mock.lastMetadataSearchDto?.city, "Paris")
        XCTAssertNil(mock.lastMetadataSearchDto?.query, "free-text query must be nil when city filter active")
        XCTAssertEqual(vm.searchMode, .metadata)
        XCTAssertEqual(vm.viewMode, .results)
        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(vm.selectedCity, "Paris")
        XCTAssertEqual(vm.results.count, 2)
        XCTAssertEqual(vm.loadedIds.count, 2)
        XCTAssertEqual(vm.currentPage, 1, "currentPage reset to 1 (not accumulated)")
        XCTAssertNil(vm.nextPage)
    }

    /// P0 regression: a card tap for each non-city EXIF field must route the
    /// value into the matching DTO field, NOT into `city` (the old bug).
    func test_exploreTap_camera_setsMake_notCity() async {
        let mock = makeMock(items: [makeAsset(id: "c1")])
        let vm = SearchViewModel(client: mock)

        await vm.searchByExplore(field: .make, value: "Canon")

        XCTAssertEqual(mock.lastMetadataSearchDto?.make, "Canon")
        XCTAssertNil(mock.lastMetadataSearchDto?.city, "make tap must not misuse city field")
        XCTAssertNil(mock.lastMetadataSearchDto?.query)
    }

    func test_exploreTap_model_setsModel() async {
        let mock = makeMock(items: [makeAsset(id: "m1")])
        let vm = SearchViewModel(client: mock)

        await vm.searchByExplore(field: .model, value: "EOS R6")

        XCTAssertEqual(mock.lastMetadataSearchDto?.model, "EOS R6")
        XCTAssertNil(mock.lastMetadataSearchDto?.city)
        XCTAssertNil(mock.lastMetadataSearchDto?.query)
    }

    func test_exploreTap_country_setsCountry() async {
        let mock = makeMock(items: [makeAsset(id: "co1")])
        let vm = SearchViewModel(client: mock)

        await vm.searchByExplore(field: .country, value: "France")

        XCTAssertEqual(mock.lastMetadataSearchDto?.country, "France")
        XCTAssertNil(mock.lastMetadataSearchDto?.city)
        XCTAssertNil(mock.lastMetadataSearchDto?.query)
    }

    func test_exploreTap_state_setsState() async {
        let mock = makeMock(items: [makeAsset(id: "st1")])
        let vm = SearchViewModel(client: mock)

        await vm.searchByExplore(field: .state, value: "California")

        XCTAssertEqual(mock.lastMetadataSearchDto?.state, "California")
        XCTAssertNil(mock.lastMetadataSearchDto?.city)
        XCTAssertNil(mock.lastMetadataSearchDto?.query)
    }

    func test_exploreTap_lensModel_setsLensModel() async {
        let mock = makeMock(items: [makeAsset(id: "l1")])
        let vm = SearchViewModel(client: mock)

        await vm.searchByExplore(field: .lensModel, value: "RF 24-70")

        XCTAssertEqual(mock.lastMetadataSearchDto?.lensModel, "RF 24-70")
        XCTAssertNil(mock.lastMetadataSearchDto?.city)
        XCTAssertNil(mock.lastMetadataSearchDto?.query)
    }

    /// `ExploreField(rawFieldName:)` parses the server's "exifInfo.x" keys.
    func test_exploreField_parsesRawFieldNames() {
        XCTAssertEqual(SearchViewModel.ExploreField(rawFieldName: "exifInfo.city"), .city)
        XCTAssertEqual(SearchViewModel.ExploreField(rawFieldName: "exifInfo.make"), .make)
        XCTAssertEqual(SearchViewModel.ExploreField(rawFieldName: "exifInfo.lensModel"), .lensModel)
        XCTAssertNil(SearchViewModel.ExploreField(rawFieldName: "exifInfo.unknown"))
    }

    // MARK: - AC-404c: loadExplore idempotency within freshness window

    func test_AC_404c_loadExplore_idempotent() async {
        let mock = MockImmichClient()
        mock.citiesResponse = [
            makeCityAsset(id: "t1", city: "Paris", country: "France")
        ]
        let vm = SearchViewModel(client: mock)

        await vm.loadExplore()
        let firstCount = mock.requestCount
        await vm.loadExplore()

        XCTAssertEqual(mock.requestCount, firstCount, "second call within freshness window must no-op")
        XCTAssertFalse(vm.explorePlaces.isEmpty)
    }

    /// `refreshExplore` bypasses the freshness guard and forces a re-fetch.
    func test_refreshExplore_forcesRefetch() async {
        let mock = MockImmichClient()
        mock.exploreResponse = [
            SearchExploreResponseDto(
                fieldName: "exifInfo.city",
                items: [SearchExploreItem(value: "Paris", data: makeAsset(id: "t1"))]
            )
        ]
        let vm = SearchViewModel(client: mock)

        await vm.loadExplore()
        XCTAssertEqual(mock.requestCount, 1)

        await vm.refreshExplore()
        XCTAssertEqual(mock.requestCount, 2, "refreshExplore must force a second fetch")
    }

    // MARK: - Explore Places (Option B: /search/cities + per-place counts)

    /// buildPlaces maps assets → ExplorePlace, dedups by city, sorts by date desc.
    func test_buildPlaces_mapsDedupsAndSortsByDate() {
        let assets = [
            makeCityAsset(id: "a1", city: "Lyon", state: "Rhône", country: "France",
                          dateTimeOriginal: "2023-03-15T10:00:00.000Z"),
            makeCityAsset(id: "a2", city: "Paris", state: "Île-de-France", country: "France",
                          dateTimeOriginal: "2024-07-14T10:00:00.000Z"),
            // Duplicate Paris — must be dropped.
            makeCityAsset(id: "a3", city: "Paris", country: "France",
                          dateTimeOriginal: "2022-01-01T10:00:00.000Z"),
            // No city — dropped.
            makeCityAsset(id: "a4", city: "", country: "France"),
        ]
        let places = SearchViewModel.buildPlaces(from: assets)

        XCTAssertEqual(places.count, 2, "dedup by city + drop empty city")
        XCTAssertEqual(places.map(\.city), ["Paris", "Lyon"], "most-recent date first")
        XCTAssertEqual(places.first?.state, "Île-de-France")
        XCTAssertEqual(places.first?.country, "France")
        XCTAssertNotNil(places.first?.date, "dateTimeOriginal parsed")
    }

    /// loadExplore fetches all cities + enriches per-place counts, sorted desc.
    func test_loadExplore_fetchesAllCitiesAndCounts() async {
        let mock = MockImmichClient()
        mock.citiesResponse = [
            makeCityAsset(id: "p1", city: "Paris", country: "France",
                          dateTimeOriginal: "2024-07-14T10:00:00.000Z"),
            makeCityAsset(id: "l1", city: "Lyon", country: "France",
                          dateTimeOriginal: "2024-03-14T10:00:00.000Z"),
            makeCityAsset(id: "t1", city: "Tokyo", country: "Japan",
                          dateTimeOriginal: "2024-09-01T10:00:00.000Z"),
        ]
        mock.statisticsByCity = ["Paris": 247, "Lyon": 12, "Tokyo": 89]
        let vm = SearchViewModel(client: mock)

        await vm.loadExplore()

        XCTAssertEqual(mock.requestCount, 4, "1 cities call + 3 statistics calls")
        XCTAssertEqual(vm.explorePlaces.count, 3)
        // Sorted by count desc: Paris(247) > Tokyo(89) > Lyon(12).
        XCTAssertEqual(vm.explorePlaces.map(\.city), ["Paris", "Tokyo", "Lyon"])
        XCTAssertEqual(vm.explorePlaces.first?.photoCount, 247)
        XCTAssertEqual(vm.explorePlaces.last?.photoCount, 12)
    }

    /// ExplorePlace.flag derives the emoji from the country name.
    func test_explorePlace_flagFromCountry() {
        let place = ExplorePlace(
            id: "Paris", city: "Paris", state: nil, country: "France",
            date: nil, assetId: "a", thumbhash: nil, photoCount: nil
        )
        XCTAssertEqual(place.flag, "🇫🇷")
        XCTAssertEqual(place.subtitle, "France")
    }

    // MARK: - CountryFlag mapper

    func test_countryFlag_knownCountries() {
        XCTAssertEqual(CountryFlag.emoji(forCountryName: "France"), "🇫🇷")
        XCTAssertEqual(CountryFlag.emoji(forCountryName: "Japan"), "🇯🇵")
        XCTAssertEqual(CountryFlag.emoji(forCountryName: "United States"), "🇺🇸")
        XCTAssertEqual(CountryFlag.emoji(forCountryName: "GERMANY"), "🇩🇪", "case-insensitive")
    }

    func test_countryFlag_unknownAndNil() {
        XCTAssertNil(CountryFlag.emoji(forCountryName: nil))
        XCTAssertNil(CountryFlag.emoji(forCountryName: ""))
        XCTAssertNil(CountryFlag.emoji(forCountryName: "Atlantis"))
    }

    func test_countryFlag_fromRegionCode() {
        XCTAssertEqual(CountryFlag.flagEmoji(forRegionCode: "FR"), "🇫🇷")
        XCTAssertNil(CountryFlag.flagEmoji(forRegionCode: "X1"), "invalid code → nil")
    }

    // MARK: - AC-405: empty state after search() returns 0 results

    func test_AC_405_empty_state() async {
        let mock = makeMock(items: []) // 0 results
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .smart
        vm.query = "obscure term"

        await vm.search()

        XCTAssertTrue(vm.hasSearched)
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.errorMessage, "empty results != error")
    }

    // MARK: - AC-406: pagination loads next page, dedup, canLoadMore

    func test_AC_406_pagination_loads_next_page() async {
        // Two distinct responses: page 1 (nextPage "2") + page 2 (nextPage nil).
        let mock = MockImmichClient()
        mock.smartSearchResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(
                count: 2, items: [makeAsset(id: "p1a"), makeAsset(id: "p1b")], nextPage: "2"
            )
        )
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .smart
        vm.query = "beach"
        await vm.search()
        XCTAssertEqual(mock.requestCount, 1)
        XCTAssertEqual(vm.results.count, 2)
        XCTAssertTrue(vm.canLoadMore)

        // Swap mock response to page 2 (nextPage nil).
        mock.smartSearchResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(
                count: 2, items: [makeAsset(id: "p2a"), makeAsset(id: "p2b")], nextPage: nil
            )
        )
        await vm.loadMore()

        XCTAssertEqual(mock.requestCount, 2)
        XCTAssertEqual(vm.results.count, 4, "page 2 appended")
        XCTAssertEqual(Set(vm.results.map(\.id)).count, 4, "no duplicate IDs")
        XCTAssertEqual(vm.currentPage, 2)
        XCTAssertNil(vm.nextPage)
        XCTAssertFalse(vm.canLoadMore)
    }

    func test_AC_406b_loadMore_noop_when_no_nextPage() async {
        let mock = makeMock(items: [makeAsset(id: "a1")], nextPage: nil)
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .smart
        vm.query = "x"
        await vm.search()
        XCTAssertEqual(mock.requestCount, 1)
        XCTAssertFalse(vm.canLoadMore)

        await vm.loadMore()
        XCTAssertEqual(mock.requestCount, 1, "loadMore no-op when canLoadMore false")
    }

    // MARK: - AC-406c: loadMore persists the Explore field filter

    func test_AC_406c_loadMore_persists_city_filter() async {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(
                count: 1, items: [makeAsset(id: "p1", city: "Paris")], nextPage: "2"
            )
        )
        let vm = SearchViewModel(client: mock)

        await vm.searchByExplore(field: .city, value: "Paris")
        XCTAssertEqual(mock.requestCount, 1)

        // Page 2 response (nextPage nil).
        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(
                count: 1, items: [makeAsset(id: "p2", city: "Paris")], nextPage: nil
            )
        )
        await vm.loadMore()

        XCTAssertEqual(mock.requestCount, 2)
        XCTAssertEqual(mock.lastMetadataSearchDto?.city, "Paris", "city filter persists across pages")
        XCTAssertNil(mock.lastMetadataSearchDto?.query)
        XCTAssertEqual(mock.lastMetadataSearchDto?.page, 2)
        XCTAssertEqual(vm.results.count, 2)
    }

    /// P0 regression: loadMore must persist a NON-city field filter too.
    func test_AC_406c_loadMore_persists_make_filter() async {
        let mock = MockImmichClient()
        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(
                count: 1, items: [makeAsset(id: "c1")], nextPage: "2"
            )
        )
        let vm = SearchViewModel(client: mock)

        await vm.searchByExplore(field: .make, value: "Canon")
        XCTAssertEqual(mock.requestCount, 1)
        XCTAssertEqual(mock.lastMetadataSearchDto?.make, "Canon")

        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(
                count: 1, items: [makeAsset(id: "c2")], nextPage: nil
            )
        )
        await vm.loadMore()

        XCTAssertEqual(mock.requestCount, 2)
        XCTAssertEqual(mock.lastMetadataSearchDto?.make, "Canon", "make filter persists across pages")
        XCTAssertNil(mock.lastMetadataSearchDto?.city)
        XCTAssertNil(mock.lastMetadataSearchDto?.query)
        XCTAssertEqual(mock.lastMetadataSearchDto?.page, 2)
    }

    // MARK: - ocr-text: detected-text filter (v3.2.0 `filter.ocr`)

    /// The filter goes out as `filter.ocr.matches` (a similarity filter) and
    /// replaces the free-text query — the deprecated scalar `ocr` field is
    /// never sent.
    func test_ocrFilter_dispatchesSimilarityFilter() async {
        let mock = makeMock(items: [makeAsset(id: "r1")])
        // `filter.ocr` only exists from v3.2.0 on: an older server has no field
        // for a text criterion at all (the ViewModel sends the flat route then).
        mock.serverVersionResponse = ServerVersionResponseDto(major: 3, minor: 2, patch: 0, prerelease: nil)
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.query = "receipt"
        vm.ocrFilterEnabled = true

        await vm.search()

        XCTAssertEqual(mock.lastMetadataSearchDto?.filter?.ocr?.matches, "receipt")
        XCTAssertNil(mock.lastMetadataSearchDto?.query, "the filter replaces the free-text query")
    }

    /// Typed-in whitespace must not reach the filter: the server requires
    /// `matches` to have at least one character.
    func test_ocrFilter_trimsTheQuery() async {
        let mock = makeMock()
        mock.serverVersionResponse = ServerVersionResponseDto(major: 3, minor: 2, patch: 0, prerelease: nil)
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.query = "  receipt  "
        vm.ocrFilterEnabled = true

        await vm.search()

        XCTAssertEqual(mock.lastMetadataSearchDto?.filter?.ocr?.matches, "receipt")
    }

    /// Toggle off (or nothing typed) → the payload is exactly what it was
    /// before the feature: a plain free-text metadata search.
    func test_ocrFilter_offLeavesQueryAlone() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.query = "receipt"

        await vm.search()

        XCTAssertEqual(mock.lastMetadataSearchDto?.query, "receipt")
        XCTAssertNil(mock.lastMetadataSearchDto?.filter)
    }

    func test_ocrFilter_emptyQuery_doesNotSendFilter() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.query = "   "
        vm.ocrFilterEnabled = true

        await vm.search()

        XCTAssertNil(mock.lastMetadataSearchDto?.filter, "minLength 1 — an empty match is invalid")
    }

    // MARK: - Live search (debounced) + clear + recents

    func test_liveSearch_debounced_dispatches_after_idle() async {
        let mock = makeMock(items: [makeAsset(id: "a1")])
        let vm = SearchViewModel(client: mock)
        vm.debounceInterval = .zero
        vm.query = "beach"
        XCTAssertEqual(mock.requestCount, 0, "no request before debounce fires")
        vm.queryDidChange()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(mock.requestCount, 1)
        XCTAssertEqual(mock.lastSmartSearchDto?.query, "beach")
        XCTAssertTrue(vm.hasSearched)
        XCTAssertEqual(vm.results.count, 1)
    }

    func test_liveSearch_empty_query_resets_to_idle() async {
        let mock = makeMock(items: [makeAsset(id: "a1")])
        let vm = SearchViewModel(client: mock)
        vm.debounceInterval = .zero
        vm.query = "beach"
        await vm.search()
        XCTAssertEqual(vm.results.count, 1)

        vm.query = ""
        vm.queryDidChange()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(vm.results.isEmpty, "clearing the field must drop stale results")
        XCTAssertFalse(vm.hasSearched)
        XCTAssertEqual(mock.requestCount, 1, "empty query must not dispatch")
    }

    func test_clearSearch_resets_results_and_query() async {
        let mock = makeMock(items: [makeAsset(id: "a1")])
        let vm = SearchViewModel(client: mock)
        vm.query = "beach"
        await vm.search()
        XCTAssertEqual(vm.results.count, 1)

        vm.clearSearch()

        XCTAssertEqual(vm.query, "")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.hasSearched)
        XCTAssertNil(vm.errorMessage)
    }

    func test_searchRecent_dispatches_without_second_search() async {
        let mock = makeMock(items: [makeAsset(id: "a1")])
        let vm = SearchViewModel(client: mock)
        vm.debounceInterval = .zero

        await vm.searchRecent("paris")

        XCTAssertEqual(mock.lastSmartSearchDto?.query, "paris")
        XCTAssertEqual(vm.query, "paris")
        XCTAssertEqual(vm.results.count, 1)

        // The View's onChange fires after the programmatic write; it must no-op.
        vm.queryDidChange()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(mock.requestCount, 1, "programmatic query write must not double-search")
    }

    func test_recents_recorded_deduped_and_capped() async {
        let suite = "SearchRecentsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentSearchesStore(defaults: defaults)

        let mock = makeMock(items: [makeAsset(id: "a1")])
        let vm = SearchViewModel(client: mock, recents: store)

        for i in 0..<10 {
            vm.query = "term\(i)"
            await vm.search()
        }
        XCTAssertEqual(vm.recentSearches.count, 8, "capped at capacity")
        XCTAssertEqual(vm.recentSearches.first, "term9", "newest first")

        vm.query = "term5"
        await vm.search()
        XCTAssertEqual(vm.recentSearches.first, "term5", "reused term moves to front")
        XCTAssertEqual(vm.recentSearches.filter { $0 == "term5" }.count, 1, "no duplicates")
        XCTAssertEqual(store.load(), vm.recentSearches, "persisted")
    }

    func test_recents_skip_empty_and_city_flows() async {
        let suite = "SearchRecentsEmptyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentSearchesStore(defaults: defaults)
        let mock = MockImmichClient()
        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(count: 0, items: [], nextPage: nil)
        )
        let vm = SearchViewModel(client: mock, recents: store)

        // City flow: query stays empty → nothing recorded.
        await vm.searchByExplore(field: .city, value: "Paris")
        XCTAssertTrue(vm.recentSearches.isEmpty, "city filter must not be recorded as a text search")
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: - Star-rating filter (star-ratings, AC-5067)

    func test_setRatingFilter_sendsFlatRatingField() async {
        let mock = makeMock(items: [makeAsset(id: "a1")])
        let vm = SearchViewModel(client: mock)

        await vm.setRatingFilter(4)

        XCTAssertEqual(vm.ratingFilter, 4)
        XCTAssertEqual(mock.lastMetadataSearchDto?.rating, 4)
        XCTAssertNil(mock.lastSmartSearchDto, "SmartSearchDto carries no rating field")
    }

    func test_setRatingFilter_forcesMetadataMode() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .smart

        await vm.setRatingFilter(2)

        XCTAssertEqual(vm.searchMode, .metadata)
        XCTAssertEqual(mock.lastMetadataSearchDto?.rating, 2)
        XCTAssertNil(mock.lastSmartSearchDto)
    }

    func test_setRatingFilter_anyClearsField() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)

        await vm.setRatingFilter(3)
        XCTAssertEqual(vm.ratingFilter, 3)

        await vm.setRatingFilter(nil)

        XCTAssertNil(vm.ratingFilter)
        XCTAssertNil(mock.lastMetadataSearchDto?.rating, "the filter must leave the request body")
    }

    /// search-filters (AC-5132) changed this contract: a rating is a *filter*,
    /// and emptying the query no longer erases filters — `clearFilters()` is the
    /// only way out (see `SearchFilterTests.test_clearSearch_doesNotClearFilters`).
    func test_clearSearch_keepsRatingFilter() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        await vm.setRatingFilter(3)

        vm.clearSearch()

        XCTAssertEqual(vm.ratingFilter, 3, "clearing the query is not clearing the filters")
        await vm.search()
        XCTAssertEqual(mock.lastMetadataSearchDto?.rating, 3, "and the filter still runs")
    }

    // MARK: - List states (L-16)

    private let serverError = APIError.serverError(500, "x")

    private func response(_ ids: [String], nextPage: String? = nil) -> SearchResponseDto {
        SearchResponseDto(
            assets: SearchAssetResponseDto(
                count: ids.count, items: ids.map { makeAsset(id: $0) }, nextPage: nextPage
            )
        )
    }

    /// A metadata-mode VM with a typed query, the shape the results tests share.
    private func makeSearchVM(_ mock: MockImmichClient) -> SearchViewModel {
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.query = "beach"
        return vm
    }

    /// A metadata gate whose first call waits for `latch`; the following ones pass.
    private func holdingFirstSearch(_ latch: TestLatch) -> ((MetadataSearchDto) async throws -> Void) {
        let calls = TestBox(0)
        return { _ in
            calls.value += 1
            if calls.value == 1 { try await latch.wait() }
        }
    }

    /// A cities gate whose first call waits for `latch`; the following ones pass.
    private func holdingFirstCities(_ latch: TestLatch) -> (() async throws -> Void) {
        let calls = TestBox(0)
        return {
            calls.value += 1
            if calls.value == 1 { try await latch.wait() }
        }
    }

    func test_AC_142_search_loadingUntilFirstAnswer() async {
        let mock = makeMock(items: [makeAsset(id: "a")])
        let latch = TestLatch()
        mock.searchMetadataGate = { _ in try await latch.wait() }
        let vm = makeSearchVM(mock)

        let read = Task { @MainActor in await vm.search() }
        await pollUntil("first search in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.resultsState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.resultsState, .data(.idle))
    }

    func test_AC_147_search_emptyAnswerIsEmptyState() async {
        let vm = makeSearchVM(makeMock())

        await vm.search()

        XCTAssertEqual(vm.resultsState, .empty)
        XCTAssertTrue(vm.hasSearched)
    }

    func test_AC_149_search_firstReadFailsShowsErrorNotEmpty() async {
        let mock = makeMock()
        mock.searchMetadataError = serverError
        let vm = makeSearchVM(mock)

        await vm.search()

        XCTAssertEqual(vm.resultsState, .error(UserFacingError.serverErrorMessage))
        XCTAssertTrue(vm.results.isEmpty)
    }

    func test_AC_149_search_retryShowsLoadingThenData() async {
        let mock = makeMock(items: [makeAsset(id: "a")])
        mock.searchMetadataError = serverError
        let vm = makeSearchVM(mock)
        await vm.search()
        mock.searchMetadataError = nil
        let latch = TestLatch()
        mock.searchMetadataGate = { _ in try await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.retryResults() }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.resultsState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.resultsState, .data(.idle))
        XCTAssertEqual(vm.results.map(\.id), ["a"])
    }

    func test_AC_152_search_refreshFailureKeepsDataThenRetryClears() async {
        let mock = makeMock(items: [makeAsset(id: "a")])
        let vm = makeSearchVM(mock)
        await vm.search()

        mock.searchMetadataError = serverError
        await vm.refreshResults()

        XCTAssertEqual(vm.results.map(\.id), ["a"], "a failed read keeps the data")
        XCTAssertEqual(vm.resultsState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertFalse(vm.isRefreshing)

        mock.searchMetadataError = nil
        await vm.retryResults()
        XCTAssertEqual(vm.resultsState, .data(.idle))
    }

    func test_AC_152_search_cancelledReplayChangesNothing() async {
        let mock = makeMock(items: [makeAsset(id: "a")])
        let vm = makeSearchVM(mock)
        await vm.search()

        mock.searchMetadataError = URLError(.cancelled)
        await vm.refreshResults()

        XCTAssertEqual(vm.results.map(\.id), ["a"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.resultsState, .data(.idle))
    }

    func test_AC_143_search_dataKeptDuringRefresh() async {
        let mock = makeMock(items: [makeAsset(id: "a"), makeAsset(id: "b")])
        let vm = makeSearchVM(mock)
        await vm.search()
        mock.searchMetadataResponse = response(["c"])
        let latch = TestLatch()
        mock.searchMetadataGate = { _ in try await latch.wait() }
        let before = mock.requestCount

        let pull = Task { @MainActor in await vm.refreshResults() }
        await pollUntil("pull in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.results.map(\.id), ["a", "b"], "results are not emptied before the answer")
        XCTAssertEqual(vm.resultsState, .data(.idle))
        latch.open()
        await pull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.results.map(\.id), ["c"])
    }

    func test_AC_154_search_refreshFromEmptyAndErrorReads() async {
        let mock = makeMock()
        let vm = makeSearchVM(mock)
        await vm.search()
        XCTAssertEqual(vm.resultsState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        mock.searchMetadataGate = { _ in try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refreshResults() }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 1 }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.resultsState, .empty)
        mock.searchMetadataResponse = response(["a"])
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.resultsState, .data(.idle))

        // From the error state.
        mock.searchMetadataGate = nil
        mock.searchMetadataResponse = nil
        let failing = makeSearchVM(mock)
        mock.searchMetadataError = serverError
        await failing.search()
        XCTAssertEqual(failing.resultsState, .error(UserFacingError.serverErrorMessage))
        mock.searchMetadataError = nil
        let errorLatch = TestLatch()
        mock.searchMetadataGate = { _ in try await errorLatch.wait() }
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refreshResults() }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 1 }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.resultsState, .error(UserFacingError.serverErrorMessage))
        mock.searchMetadataResponse = response(["b"])
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.resultsState, .data(.idle))
    }

    func test_AC_154_search_refreshDuringReadIsNotIgnored() async {
        let mock = makeMock(items: [makeAsset(id: "a")])
        let latch = TestLatch()
        mock.searchMetadataGate = holdingFirstSearch(latch)
        let vm = makeSearchVM(mock)

        let first = Task { @MainActor in await vm.search() }
        await pollUntil("first search in flight") { mock.requestCount == 1 }
        await vm.refreshResults()
        XCTAssertEqual(mock.requestCount, 2, "a pull during a read is a request of its own")
        XCTAssertEqual(vm.results.map(\.id), ["a"], "the pull's answer is on screen")
        // `isLoading` stays up while the superseded read is still in flight.
        XCTAssertEqual(vm.resultsState, .data(.reloading))

        // The superseded read fails late: it must not write.
        mock.searchMetadataError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.resultsState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }

    func test_AC_154_search_pullBeforeAnySearchStartsNothing() async {
        let mock = makeMock()
        let vm = makeSearchVM(mock)

        await vm.refreshResults()

        XCTAssertEqual(mock.requestCount, 0)
        XCTAssertFalse(vm.hasSearched)
        XCTAssertFalse(vm.isRefreshing)
    }

    func test_AC_31_search_errorThenEmptyThenData() async {
        let mock = makeMock()
        mock.searchMetadataError = serverError
        let vm = makeSearchVM(mock)
        await vm.search()
        XCTAssertEqual(vm.resultsState, .error(UserFacingError.serverErrorMessage))

        mock.searchMetadataError = nil
        await vm.refreshResults()
        XCTAssertEqual(vm.resultsState, .empty)

        mock.searchMetadataResponse = response(["a"])
        await vm.refreshResults()
        XCTAssertEqual(vm.resultsState, .data(.idle))
        XCTAssertEqual(vm.results.map(\.id), ["a"])
    }

    func test_AC_155_search_refreshReplaysSameQueryAndFilters() async {
        let mock = makeMock(items: [makeAsset(id: "a")])
        let vm = makeSearchVM(mock)
        await vm.setRatingFilter(3)
        let first = mock.searchMetadataCalls.count

        await vm.refreshResults()

        XCTAssertEqual(mock.searchMetadataCalls.count, first + 1)
        let original = mock.searchMetadataCalls[first - 1]
        let replay = mock.searchMetadataCalls[first]
        XCTAssertEqual(replay.query, original.query)
        XCTAssertEqual(replay.rating, 3)
        XCTAssertEqual(replay.rating, original.rating)
        XCTAssertEqual(replay.page ?? 1, 1)
        XCTAssertEqual(vm.results.map(\.id), ["a"])
    }

    func test_AC_152_search_loadMoreFailureKeepsGridWithBannerThenRetriesThePage() async {
        let mock = makeMock()
        mock.searchMetadataResponsesByPage[1] = response(["a"], nextPage: "2")
        mock.searchMetadataResponsesByPage[2] = response(["b"])
        let vm = makeSearchVM(mock)
        await vm.search()

        mock.searchMetadataError = serverError
        await vm.loadMore()

        XCTAssertEqual(vm.results.map(\.id), ["a"], "the grid stays")
        XCTAssertEqual(vm.resultsState, .data(.failed(UserFacingError.serverErrorMessage)))

        mock.searchMetadataError = nil
        let before = mock.searchMetadataCalls.count
        await vm.retryResults()

        XCTAssertEqual(mock.searchMetadataCalls.count, before + 1)
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 2, "retry re-runs the failed page, not the search")
        XCTAssertEqual(vm.results.map(\.id), ["a", "b"])
        XCTAssertEqual(vm.resultsState, .data(.idle))
    }

    // MARK: Explore (L-16)

    func test_AC_142_explore_loadingUntilFirstAnswer() async {
        let mock = MockImmichClient()
        mock.citiesResponse = [makeCityAsset(id: "t1", city: "Paris")]
        let latch = TestLatch()
        mock.citiesGate = { try await latch.wait() }
        let vm = SearchViewModel(client: mock)
        XCTAssertEqual(vm.exploreState, .loading)

        let read = Task { @MainActor in await vm.loadExplore() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.exploreState, .loading)
        XCTAssertTrue(vm.isLoadingExplore)
        XCTAssertFalse(vm.isLoading, "Explore does not share the results' loading flag")
        latch.open()
        await read.value
        XCTAssertEqual(vm.exploreState, .data(.idle))
    }

    func test_AC_147_explore_emptyAnswerIsEmptyState() async {
        let vm = SearchViewModel(client: MockImmichClient())

        await vm.loadExplore()

        XCTAssertEqual(vm.exploreState, .empty)
    }

    func test_AC_149_explore_firstReadFailsShowsErrorNotEmpty() async {
        let mock = MockImmichClient()
        mock.citiesError = serverError
        let vm = SearchViewModel(client: mock)

        await vm.loadExplore()

        XCTAssertEqual(vm.exploreState, .error(UserFacingError.serverErrorMessage))
        XCTAssertEqual(vm.exploreLoadError, UserFacingError.serverErrorMessage)
        XCTAssertNil(vm.errorMessage, "Explore never writes the results' error")
        XCTAssertTrue(vm.explorePlaces.isEmpty)
    }

    func test_AC_149_explore_retryShowsLoadingThenData() async {
        let mock = MockImmichClient()
        mock.citiesError = serverError
        let vm = SearchViewModel(client: mock)
        await vm.loadExplore()
        mock.citiesError = nil
        mock.citiesResponse = [makeCityAsset(id: "t1", city: "Paris")]
        let latch = TestLatch()
        mock.citiesGate = { try await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.loadExplore(force: true) }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isLoadingExplore)
        XCTAssertFalse(vm.isRefreshingExplore)
        XCTAssertEqual(vm.exploreState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.exploreState, .data(.idle))
        XCTAssertEqual(vm.explorePlaces.map(\.city), ["Paris"])
    }

    func test_AC_152_explore_refreshFailureKeepsCardsThenRetryClears() async {
        let mock = MockImmichClient()
        mock.citiesResponse = [makeCityAsset(id: "t1", city: "Paris")]
        let vm = SearchViewModel(client: mock)
        await vm.loadExplore()

        mock.citiesError = serverError
        await vm.refreshExplore()

        XCTAssertEqual(vm.explorePlaces.map(\.city), ["Paris"], "a failed read keeps the cards")
        XCTAssertEqual(vm.exploreState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertFalse(vm.isRefreshingExplore)

        mock.citiesError = nil
        await vm.loadExplore(force: true)
        XCTAssertEqual(vm.exploreState, .data(.idle))
    }

    func test_AC_157_explore_refreshKeepsTheCardsUntilTheAnswer() async {
        let mock = MockImmichClient()
        mock.citiesResponse = [makeCityAsset(id: "t1", city: "Paris")]
        let vm = SearchViewModel(client: mock)
        await vm.loadExplore()
        mock.citiesResponse = [makeCityAsset(id: "t2", city: "Rome")]
        let latch = TestLatch()
        mock.citiesGate = { try await latch.wait() }
        let before = mock.requestCount

        let pull = Task { @MainActor in await vm.refreshExplore() }
        await pollUntil("pull in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isRefreshingExplore)
        XCTAssertEqual(vm.explorePlaces.map(\.city), ["Paris"], "cards are not emptied before the answer")
        XCTAssertEqual(vm.exploreState, .data(.idle))
        latch.open()
        await pull.value
        XCTAssertFalse(vm.isRefreshingExplore)
        XCTAssertEqual(vm.explorePlaces.map(\.city), ["Rome"])
    }

    func test_AC_143_explore_dataKeptDuringRefresh() async {
        let mock = MockImmichClient()
        mock.citiesResponse = [makeCityAsset(id: "t1", city: "Paris")]
        let vm = SearchViewModel(client: mock)
        await vm.loadExplore()

        // Pull: cards stay, the system control is the indicator.
        let pullLatch = TestLatch()
        mock.citiesGate = { try await pullLatch.wait() }
        var before = mock.requestCount
        let pull = Task { @MainActor in await vm.refreshExplore() }
        await pollUntil("pull in flight") { mock.requestCount == before + 1 }
        XCTAssertEqual(vm.explorePlaces.map(\.city), ["Paris"])
        XCTAssertEqual(vm.exploreState, .data(.idle))
        pullLatch.open()
        await pull.value

        // "Try Again" with cards: they stay, an indicator stands in for the banner.
        let retryLatch = TestLatch()
        mock.citiesGate = { try await retryLatch.wait() }
        before = mock.requestCount
        let retry = Task { @MainActor in await vm.loadExplore(force: true) }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }
        XCTAssertEqual(vm.explorePlaces.map(\.city), ["Paris"])
        XCTAssertEqual(vm.exploreState, .data(.reloading))
        retryLatch.open()
        await retry.value
        XCTAssertEqual(vm.exploreState, .data(.idle))
    }

    func test_AC_154_explore_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        let vm = SearchViewModel(client: mock)
        await vm.loadExplore()
        XCTAssertEqual(vm.exploreState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        mock.citiesGate = { try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refreshExplore() }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 1 }
        XCTAssertTrue(vm.isRefreshingExplore)
        XCTAssertEqual(vm.exploreState, .empty)
        mock.citiesResponse = [makeCityAsset(id: "t1", city: "Paris")]
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshingExplore)
        XCTAssertEqual(vm.exploreState, .data(.idle))

        // From the error state.
        mock.citiesGate = nil
        mock.citiesResponse = nil
        let failing = SearchViewModel(client: mock)
        mock.citiesError = serverError
        await failing.loadExplore()
        XCTAssertEqual(failing.exploreState, .error(UserFacingError.serverErrorMessage))
        mock.citiesError = nil
        let errorLatch = TestLatch()
        mock.citiesGate = { try await errorLatch.wait() }
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refreshExplore() }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 1 }
        XCTAssertTrue(failing.isRefreshingExplore)
        XCTAssertEqual(failing.exploreState, .error(UserFacingError.serverErrorMessage))
        mock.citiesResponse = [makeCityAsset(id: "t1", city: "Paris")]
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.exploreState, .data(.idle))
    }

    func test_AC_154_explore_refreshDuringReadIsNotIgnored() async {
        let mock = MockImmichClient()
        mock.citiesResponse = [makeCityAsset(id: "t1", city: "Paris")]
        let latch = TestLatch()
        mock.citiesGate = holdingFirstCities(latch)
        let vm = SearchViewModel(client: mock)

        let first = Task { @MainActor in await vm.loadExplore() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }
        await vm.refreshExplore()
        XCTAssertEqual(vm.exploreState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.citiesError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.exploreState, .data(.idle))
        XCTAssertFalse(vm.isLoadingExplore)
    }

    func test_AC_157_explore_failureIsErrorThenEmptyThenRefresh() async {
        let mock = MockImmichClient()
        mock.citiesError = serverError
        let vm = SearchViewModel(client: mock)
        await vm.loadExplore()
        XCTAssertEqual(vm.exploreState, .error(UserFacingError.serverErrorMessage))

        mock.citiesError = nil
        await vm.refreshExplore()
        XCTAssertEqual(vm.exploreState, .empty)

        mock.citiesResponse = [makeCityAsset(id: "t1", city: "Paris")]
        await vm.refreshExplore()
        XCTAssertEqual(vm.exploreState, .data(.idle))
        XCTAssertEqual(vm.explorePlaces.map(\.city), ["Paris"])
    }
}
