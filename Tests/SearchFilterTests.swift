import XCTest
@testable import ImmichSwiftUI

/// search-filters (AC-5130…AC-5139): the filter the sheet edits and — the part
/// that matters — what the server actually receives. Assertions read
/// `MockImmichClient.lastMetadataSearchDto` (the captured body) rather than the
/// ViewModel's wiring.
@MainActor
final class SearchFilterTests: XCTestCase {

    /// The mock reports **1.120.0** by default — the flat route, which every
    /// server accepts. `structured` opts a case into the v3.2.0 generation that
    /// has `filter`/`orderBy`/`cursor`.
    private func makeMock(structured: Bool = false) -> MockImmichClient {
        let mock = MockImmichClient()
        if structured {
            mock.serverVersionResponse = ServerVersionResponseDto(major: 3, minor: 2, patch: 0, prerelease: nil)
        }
        let empty = SearchResponseDto(
            assets: SearchAssetResponseDto(count: 0, items: [], nextPage: nil)
        )
        mock.searchMetadataResponse = empty
        mock.smartSearchResponse = empty
        return mock
    }

    // MARK: - AC-5130 / AC-5133: the filter reaches the body, and only what is set

    func test_filterApply_writesOnlyNonNilFields() throws {
        let filter = SearchFilter(rating: 4, city: "Lyon", country: "France")

        var dto = MetadataSearchDto(query: "quai", page: 1)
        filter.apply(to: &dto)

        XCTAssertEqual(dto.rating, 4)
        XCTAssertEqual(dto.city, "Lyon")
        XCTAssertEqual(dto.country, "France")
        XCTAssertNil(dto.state)
        XCTAssertNil(dto.make)
        XCTAssertNil(dto.model)
        XCTAssertNil(dto.lensModel)
        XCTAssertNil(dto.type)
        XCTAssertNil(dto.isFavorite)
        XCTAssertNil(dto.filter, "no OCR criterion means no similarity node")
        XCTAssertEqual(dto.visibility, .timeline, "visibility is written even with Archive off")

        // …and the untouched fields really leave the request body (synthesized
        // `Codable` omits the key, it does not send null).
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.immich.encode(dto)) as? [String: Any]
        )
        XCTAssertNil(body["state"])
        XCTAssertNil(body["make"])
        XCTAssertEqual(body["rating"] as? Int, 4)
        XCTAssertEqual(body["city"] as? String, "Lyon")
    }

    func test_activeCount_countsEachConstraintOnce() {
        var filter = SearchFilter()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertEqual(filter.activeCount, 0)
        XCTAssertTrue(filter.constraints.isEmpty)

        filter.rating = 3
        filter.city = "Lyon"
        filter.lensModel = "XF 23mm"
        filter.isFavorite = true
        XCTAssertEqual(filter.activeCount, 4)
        XCTAssertFalse(filter.isEmpty)

        // A blank text field is not a constraint — the sheet normalizes it to
        // nil, and the chip row must not outlive the request field.
        filter.ocrText = ""
        XCTAssertEqual(filter.activeCount, 4)
        XCTAssertEqual(filter.constraints.map(\.field), [.rating, .city, .lensModel, .isFavorite])

        filter.clear(.city)
        XCTAssertEqual(filter.activeCount, 3)
        XCTAssertFalse(filter.constraints.contains { $0.field == .city }, "a chip removes exactly one constraint")

        filter = SearchFilter.none
        XCTAssertTrue(filter.isEmpty)
    }

    func test_rating_outOfRange_isIgnoredByApply() {
        var filter = SearchFilter()
        filter.rating = 7

        var dto = MetadataSearchDto(query: nil, page: 1)
        filter.apply(to: &dto)

        XCTAssertNil(dto.rating, "the server's scale is 1…5 — an out-of-range value is not a request")
        XCTAssertEqual(filter.activeCount, 0, "and it is not a constraint the grid claims to be filtered by")
    }

    func test_ocrText_switchesFromSmartToMetadata() async {
        // `filter.ocr` is v3.2.0: the case needs a server that has the field.
        let mock = makeMock(structured: true)
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .smart
        vm.query = "receipt"
        vm.filter.ocrText = "invoice"

        await vm.applyFilters()

        XCTAssertEqual(vm.searchMode, .metadata, "SmartSearchDto has no filter field")
        XCTAssertNil(mock.lastSmartSearchDto)
        XCTAssertEqual(mock.lastMetadataSearchDto?.filter?.ocr?.matches, "invoice")
        XCTAssertEqual(
            mock.lastMetadataSearchDto?.query, "receipt",
            "an OCR criterion typed in the sheet is a filter, not a replacement for the query"
        )
    }

    // MARK: - AC-5136 / AC-5138: the two ways back to no filter

    func test_clearFilters_resetsFilterButKeepsQuery() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.query = "lyon"
        vm.filter.city = "Lyon"
        vm.filter.rating = 3

        await vm.clearFilters()

        XCTAssertTrue(vm.filter.isEmpty)
        XCTAssertFalse(vm.isFilterActive)
        XCTAssertEqual(vm.query, "lyon")
        XCTAssertNil(mock.lastMetadataSearchDto?.city)
        XCTAssertNil(mock.lastMetadataSearchDto?.rating)
    }

    func test_clearSearch_doesNotClearFilters() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.query = "lyon"
        vm.filter.city = "Lyon"
        vm.filter.rating = 3

        vm.clearSearch()

        XCTAssertEqual(vm.filter.city, "Lyon", "emptying the query is not erasing the filters")
        XCTAssertEqual(vm.ratingFilter, 3)
        XCTAssertTrue(vm.isFilterActive)

        await vm.applyFilters()
        XCTAssertEqual(mock.lastMetadataSearchDto?.city, "Lyon")
        XCTAssertEqual(mock.lastMetadataSearchDto?.rating, 3)
    }

    // MARK: - AC-5133: the dates on the wire

    func test_dispatch_writesDateRangeAsISO8601() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.filter.takenAfter = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01T00:00:00Z
        vm.filter.takenBefore = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01T00:00:00Z

        await vm.applyFilters()

        XCTAssertEqual(mock.lastMetadataSearchDto?.takenAfter, "2024-01-01T00:00:00.000Z")
        XCTAssertEqual(mock.lastMetadataSearchDto?.takenBefore, "2025-01-01T00:00:00.000Z")
    }

    func test_dispatch_writesNoDateWhenToggleIsOff() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.filter.takenBefore = Date(timeIntervalSince1970: 1_735_689_600)

        await vm.applyFilters()
        XCTAssertNil(mock.lastMetadataSearchDto?.takenAfter, "only the enabled bound is sent")
        XCTAssertEqual(mock.lastMetadataSearchDto?.takenBefore, "2025-01-01T00:00:00.000Z")

        vm.filter.takenBefore = nil
        await vm.applyFilters()
        XCTAssertNil(mock.lastMetadataSearchDto?.takenBefore)
    }

    // MARK: - The request shape follows the server generation

    /// Every constraint the sheet can set, at once.
    private func fillEveryConstraint(_ vm: SearchViewModel) {
        vm.searchMode = .metadata
        vm.query = "lyon"
        vm.filter.city = "Lyon"
        vm.filter.state = "Auvergne-Rhône-Alpes"
        vm.filter.country = "France"
        vm.filter.make = "Canon"
        vm.filter.model = "EOS R6"
        vm.filter.lensModel = "RF 50mm"
        vm.filter.type = SearchFilter.photoType
        vm.filter.isFavorite = true
        vm.filter.rating = 4
        vm.filter.takenAfter = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01T00:00:00Z
        vm.filter.takenBefore = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01T00:00:00Z
    }

    /// The whole body, as the server receives it — the json the app would put
    /// on the wire, not the ViewModel's wiring.
    private func json(_ dto: MetadataSearchDto) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.immich.encode(dto)) as? [String: Any])
    }

    /// ≥ v3.2.0: the constraints travel as a `SearchFilter` and **no** flat
    /// field rides along — the server rejects that mix with a 400.
    func test_structuredServer_movesEveryConstraintIntoTheFilter() async throws {
        let mock = makeMock(structured: true)
        let vm = SearchViewModel(client: mock)
        fillEveryConstraint(vm)

        await vm.applyFilters()

        let dto = try XCTUnwrap(mock.lastMetadataSearchDto)
        let filter = try XCTUnwrap(dto.filter, "a v3.2.0 server receives the structured filter")
        XCTAssertEqual(filter.city?.eq, "Lyon")
        XCTAssertEqual(filter.state?.eq, "Auvergne-Rhône-Alpes")
        XCTAssertEqual(filter.country?.eq, "France")
        XCTAssertEqual(filter.make?.eq, "Canon")
        XCTAssertEqual(filter.model?.eq, "EOS R6")
        XCTAssertEqual(filter.lensModel?.eq, "RF 50mm")
        XCTAssertEqual(filter.type?.eq, "IMAGE")
        XCTAssertEqual(filter.isFavorite?.eq, true)
        XCTAssertEqual(filter.rating?.eq, 4)
        XCTAssertEqual(filter.takenAt?.gte, "2024-01-01T00:00:00.000Z", "takenAfter is the range's lower bound")
        XCTAssertEqual(filter.takenAt?.lte, "2025-01-01T00:00:00.000Z")
        XCTAssertEqual(filter.visibility?.eq, "timeline", "every metadata request states its visibility")
        XCTAssertNil(dto.visibility)

        XCTAssertNil(dto.city)
        XCTAssertNil(dto.state)
        XCTAssertNil(dto.country)
        XCTAssertNil(dto.make)
        XCTAssertNil(dto.model)
        XCTAssertNil(dto.lensModel)
        XCTAssertNil(dto.type)
        XCTAssertNil(dto.isFavorite)
        XCTAssertNil(dto.rating)
        XCTAssertNil(dto.takenAfter)
        XCTAssertNil(dto.takenBefore)
        XCTAssertNil(dto.page, "`page` is a deprecated flat field")
        XCTAssertNil(dto.cursor, "page 1 does not continue a cursor chain")
        XCTAssertEqual(dto.query, "lyon", "free text is not a deprecated field")

        // …and the same on the wire: no deprecated key is even present.
        let body = try json(dto)
        for key in ["page", "city", "state", "country", "make", "model", "lensModel",
                    "type", "isFavorite", "rating", "takenAfter", "takenBefore", "order", "ocr", "visibility"] {
            XCTAssertNil(body[key], "\(key) cannot be combined with filter/orderBy/cursor")
        }
        XCTAssertNil(
            body["orderBy"],
            "the screen sends no `orderBy`: with the sort option gone the server's own order stands"
        )
        let filterBody = try XCTUnwrap(body["filter"] as? [String: Any])
        XCTAssertEqual((filterBody["city"] as? [String: String])?["eq"], "Lyon")
        XCTAssertEqual((filterBody["type"] as? [String: String])?["eq"], "IMAGE")
        XCTAssertEqual((filterBody["isFavorite"] as? [String: Bool])?["eq"], true)
        XCTAssertEqual((filterBody["rating"] as? [String: Double])?["eq"], 4)
        XCTAssertEqual((filterBody["takenAt"] as? [String: String])?["gte"], "2024-01-01T00:00:00.000Z")
        XCTAssertEqual((filterBody["takenAt"] as? [String: String])?["lte"], "2025-01-01T00:00:00.000Z")
    }

    /// ≥ v3.2.0: page 2 continues from the cursor the server handed out, and
    /// never from a page number.
    func test_structuredServer_paginatesByCursor() async throws {
        let mock = makeMock(structured: true)
        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(count: 0, items: [], nextPage: nil, nextCursor: "eyJvZmZzZXQiOjI1MH0")
        )
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.filter.city = "Lyon"

        await vm.applyFilters()
        XCTAssertTrue(vm.canLoadMore, "the v3.2.0 page token is the cursor")
        XCTAssertNil(vm.nextPage)

        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(count: 0, items: [], nextPage: nil, nextCursor: nil)
        )
        await vm.loadMore()

        let dto = try XCTUnwrap(mock.lastMetadataSearchDto)
        XCTAssertEqual(dto.cursor, "eyJvZmZzZXQiOjI1MH0", "page 2 replays the cursor of page 1")
        XCTAssertNil(dto.page)
        XCTAssertEqual(dto.filter?.city?.eq, "Lyon", "the constraints survive the page turn")
        XCTAssertFalse(vm.canLoadMore, "the server sent no further cursor")
    }

    /// < v3.2.0: the request is exactly the one this screen has always sent —
    /// flat fields and a page number, and not one structured field.
    func test_legacyServer_keepsTheFlatRoute() async throws {
        let mock = makeMock() // 1.120.0
        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(count: 0, items: [], nextPage: "2")
        )
        let vm = SearchViewModel(client: mock)
        fillEveryConstraint(vm)

        await vm.applyFilters()

        var dto = try XCTUnwrap(mock.lastMetadataSearchDto)
        XCTAssertEqual(dto.city, "Lyon")
        XCTAssertEqual(dto.rating, 4)
        XCTAssertEqual(dto.takenAfter, "2024-01-01T00:00:00.000Z")
        XCTAssertEqual(dto.page, 1)
        XCTAssertNil(dto.filter)
        XCTAssertEqual(dto.visibility, .timeline, "the flat route says `timeline` itself, archived photos stay out")
        XCTAssertNil(dto.orderBy)
        XCTAssertNil(dto.cursor)

        // The flat body, verbatim: flat constraints plus a page number.
        let body = try json(dto)
        XCTAssertEqual(body["page"] as? Int, 1)
        XCTAssertEqual(body["city"] as? String, "Lyon")
        XCTAssertEqual(body["rating"] as? Int, 4)
        XCTAssertEqual(body["takenAfter"] as? String, "2024-01-01T00:00:00.000Z")
        XCTAssertEqual(body["takenBefore"] as? String, "2025-01-01T00:00:00.000Z")
        for key in ["filter", "orderBy", "cursor"] {
            XCTAssertNil(body[key], "\(key) is a v3.2.0 field: it never rides with a flat one")
        }

        mock.searchMetadataResponse = SearchResponseDto(
            assets: SearchAssetResponseDto(count: 0, items: [], nextPage: nil)
        )
        await vm.loadMore()

        dto = try XCTUnwrap(mock.lastMetadataSearchDto)
        XCTAssertEqual(dto.page, 2, "the flat route paginates by page number")
        XCTAssertEqual(dto.city, "Lyon", "and keeps the constraints across pages")
        XCTAssertNil(dto.cursor)
        XCTAssertNil(dto.filter)
    }

    /// The generation breakpoint is v3.2.0: 3.1.x still has no `filter`, and a
    /// major bump past 3 does.
    func test_shapeThreshold_isVersionThreeTwo() async {
        for (version, structured) in [
            (ServerVersionResponseDto(major: 3, minor: 1, patch: 9, prerelease: nil), false),
            (ServerVersionResponseDto(major: 3, minor: 2, patch: 0, prerelease: nil), true),
            (ServerVersionResponseDto(major: 4, minor: 0, patch: 0, prerelease: nil), true),
        ] {
            let mock = makeMock()
            mock.serverVersionResponse = version
            let vm = SearchViewModel(client: mock)
            vm.searchMode = .metadata
            vm.filter.city = "Lyon"

            await vm.applyFilters()

            let described = "\(version.major).\(version.minor).\(version.patch)"
            XCTAssertEqual(
                vm.supportsStructuredSearch, structured,
                "\(described) — the value the Filters sheet and the OCR toggle are gated on"
            )
            XCTAssertEqual(mock.lastMetadataSearchDto?.filter?.city?.eq, structured ? "Lyon" : nil, described)
            XCTAssertEqual(mock.lastMetadataSearchDto?.city, structured ? nil : "Lyon", described)
        }
    }

    /// B-21: the "requires Immich X or later" notice reads the threshold the
    /// guard uses — one constant, not a version written twice.
    func test_AC_32_6_versionNoticeUsesTheGuardThreshold() async {
        XCTAssertEqual(SearchViewModel.structuredSearchMinimumLabel, "3.2")
        let minimum = SearchViewModel.structuredSearchMinimum
        XCTAssertEqual([minimum.major, minimum.minor, minimum.patch], [3, 2, 0])

        for (version, structured) in [
            (ServerVersionResponseDto(major: 3, minor: 1, patch: 9, prerelease: nil), false),
            (minimum, true),
        ] {
            let mock = makeMock()
            mock.serverVersionResponse = version
            let vm = SearchViewModel(client: mock)
            vm.searchMode = .metadata
            vm.filter.city = "Lyon"
            await vm.applyFilters()
            XCTAssertEqual(vm.supportsStructuredSearch, structured, "\(version.major).\(version.minor).\(version.patch)")
        }
    }

    /// A version that cannot be read leaves the generation unknown, and unknown
    /// means the flat route — the one no server rejects.
    func test_unreachableVersionEndpoint_keepsTheFlatRoute() async throws {
        let mock = makeMock()
        mock.serverVersionError = URLError(.cannotConnectToHost)
        let vm = SearchViewModel(client: mock)
        fillEveryConstraint(vm)

        await vm.applyFilters()

        XCTAssertFalse(vm.supportsStructuredSearch)
        let dto = try XCTUnwrap(mock.lastMetadataSearchDto)
        XCTAssertEqual(dto.city, "Lyon")
        XCTAssertEqual(dto.page, 1)
        XCTAssertNil(dto.filter)
        XCTAssertNil(dto.orderBy)
        XCTAssertNil(dto.cursor)
    }

    /// The toolbar's detected-text toggle on a server without the structured
    /// filter: no request may carry a text criterion — and the typed query must
    /// not be emptied for one that cannot be sent.
    func test_legacyServer_ocrToggle_sendsNoTextCriterion() async throws {
        let mock = makeMock() // 1.120.0
        let vm = SearchViewModel(client: mock)
        vm.searchMode = .metadata
        vm.query = "receipt"
        vm.ocrFilterEnabled = true

        await vm.search()

        let dto = try XCTUnwrap(mock.lastMetadataSearchDto)
        XCTAssertNil(dto.filter, "the deprecated scalar `ocr` is gone and `filter.ocr` needs v3.2.0")
        XCTAssertEqual(dto.query, "receipt", "the query is not sacrificed to a criterion that cannot be sent")

        let body = try json(dto)
        XCTAssertNil(body["ocr"], "the deprecated scalar is never sent")
        XCTAssertNil(body["filter"])
    }
}
