import XCTest
@testable import ImmichSwiftUI

/// L-23 — people, tags, display options (not in album, favourites, archive) and
/// the file name / description text modes: what the criteria write into each
/// request shape, how the view model moves between Smart, Metadata and the
/// text modes, and what the two pickers read. Assertions read the bodies the
/// mock captured (and their JSON), not the view model's wiring.
@MainActor
final class SearchCriteriaTests: XCTestCase {

    private let alice = PersonResponseDto(id: "p-alice", name: "Alice", isHidden: false)
    private let bob = PersonResponseDto(id: "p-bob", name: "Bob", isHidden: false)
    private let voyages = TagResponseDto(id: "t-voyages", name: "Voyages", value: "Voyages")
    private let japon = TagResponseDto(id: "t-japon", name: "Japon", value: "Voyages/Japon", parentId: "t-voyages")

    // MARK: - Helpers

    private func response(_ items: [AssetResponseDto] = [], nextPage: String? = nil) -> SearchResponseDto {
        SearchResponseDto(assets: SearchAssetResponseDto(count: items.count, items: items, nextPage: nextPage))
    }

    private func asset(_ id: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T00:00:00.000Z", ownerId: "owner",
            originalPath: "/\(id).jpg", originalFileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            updatedAt: "2024-07-01T00:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false,
            isOffline: false, visibility: "timeline", checksum: "x", isEdited: false,
            exifInfo: nil
        )
    }

    /// `version == nil` keeps the mock's default, 1.120.0 (the flat route).
    private func makeMock(version: (Int, Int, Int)? = nil, countsProbe: Bool = false) -> MockImmichClient {
        let mock = MockImmichClient()
        mock.versionProbeCountsAsRequest = countsProbe
        if let version {
            mock.serverVersionResponse = ServerVersionResponseDto(
                major: version.0, minor: version.1, patch: version.2, prerelease: nil
            )
        }
        mock.searchMetadataResponse = response()
        mock.smartSearchResponse = response()
        return mock
    }

    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.immich.encode(value)) as? [String: Any])
    }

    private func ids(_ node: Any?) -> [String]? {
        node as? [String]
    }

    // MARK: - S-1: the filter type

    func test_AC_213_constraintsOrderLabelsAndClear() {
        var filter = SearchFilter()
        filter.isArchived = true
        filter.isNotInAlbum = true
        filter.rating = 4
        filter.toggle(tag: japon)
        filter.toggle(person: alice)
        filter.toggle(person: PersonResponseDto(id: "p-anon", name: "", isHidden: false))

        XCTAssertEqual(
            filter.constraints.map(\.field),
            [.personIds, .tagIds, .rating, .isNotInAlbum, .visibility],
            "the bar's order is the sheet's"
        )
        XCTAssertEqual(filter.activeCount, 5)
        let people = filter.constraints[0].label
        XCTAssertTrue(people.contains("Alice"), people)
        XCTAssertTrue(people.contains(String(localized: "Unnamed")), "a nameless person is not an empty chip: \(people)")
        XCTAssertTrue(filter.constraints[1].label.contains("Voyages/Japon"), "a child chip shows its full path")

        filter.toggle(person: alice)
        XCTAssertEqual(filter.people.map(\.id), ["p-anon"], "toggling a chosen person removes it")

        filter.clear(.originalFileName)
        filter.clear(.description)
        XCTAssertEqual(filter.activeCount, 5, "the text modes are not the filter's to clear")

        filter.clear(.personIds)
        filter.clear(.tagIds)
        filter.clear(.isNotInAlbum)
        filter.clear(.visibility)
        XCTAssertEqual(filter.constraints.map(\.field), [.rating])
        XCTAssertFalse(filter.isArchived)
    }

    func test_AC_211_applyAlwaysWritesVisibility() {
        var dto = MetadataSearchDto(page: 1)
        SearchFilter().apply(to: &dto)
        XCTAssertEqual(dto.visibility, .timeline, "Archive off is `timeline`, never absent")
        XCTAssertNil(dto.personIds)
        XCTAssertNil(dto.tagIds)
        XCTAssertNil(dto.isNotInAlbum, "the official client only ever sends `true`")

        var filter = SearchFilter()
        filter.isArchived = true
        filter.isNotInAlbum = true
        filter.toggle(person: bob)
        filter.toggle(person: alice)
        filter.toggle(tag: japon)
        dto = MetadataSearchDto(page: 1)
        filter.apply(to: &dto)
        XCTAssertEqual(dto.visibility, .archive)
        XCTAssertEqual(dto.isNotInAlbum, true)
        XCTAssertEqual(dto.personIds, ["p-bob", "p-alice"], "selection order")
        XCTAssertEqual(dto.tagIds, ["t-japon"])
    }

    // MARK: - S-2: the three shapes

    func test_AC_214_shapesCarryEveryCriterion() throws {
        var filter = SearchFilter()
        filter.isArchived = true
        filter.isNotInAlbum = true
        filter.toggle(person: alice)
        filter.toggle(person: bob)
        filter.toggle(tag: japon)
        var base = MetadataSearchDto(page: 1)
        filter.apply(to: &base)
        base.originalFileName = "kyoto"
        base.description = "temple"

        let flat = try json(base.flatShape())
        XCTAssertEqual(ids(flat["personIds"]), ["p-alice", "p-bob"])
        XCTAssertEqual(ids(flat["tagIds"]), ["t-japon"])
        XCTAssertEqual(flat["isNotInAlbum"] as? Bool, true)
        XCTAssertEqual(flat["visibility"] as? String, "archive")
        XCTAssertEqual(flat["originalFileName"] as? String, "kyoto")
        XCTAssertEqual(flat["description"] as? String, "temple")
        XCTAssertEqual(flat["page"] as? Int, 1)
        for key in ["filter", "orderBy", "cursor"] { XCTAssertNil(flat[key], key) }

        let structured = try json(base.structuredShape(cursor: nil))
        let node = try XCTUnwrap(structured["filter"] as? [String: Any])
        XCTAssertEqual(ids((node["personIds"] as? [String: Any])?["all"]), ["p-alice", "p-bob"])
        XCTAssertEqual(ids((node["tagIds"] as? [String: Any])?["all"]), ["t-japon"])
        XCTAssertEqual((node["hasAlbums"] as? [String: Any])?["eq"] as? Bool, false)
        XCTAssertEqual((node["visibility"] as? [String: Any])?["eq"] as? String, "archive")
        XCTAssertEqual((node["originalFileName"] as? [String: Any])?["like"] as? String, "kyoto")
        XCTAssertEqual((node["description"] as? [String: Any])?["like"] as? String, "temple")
        for key in ["page", "personIds", "tagIds", "isNotInAlbum", "visibility", "originalFileName", "description"] {
            XCTAssertNil(structured[key], "\(key) is a deprecated flat field: it cannot ride with `filter`")
        }

        let smart = try json(base.smartShape(query: "plage", page: 2))
        XCTAssertEqual(smart["query"] as? String, "plage")
        XCTAssertEqual(smart["page"] as? Int, 2)
        XCTAssertEqual(ids(smart["personIds"]), ["p-alice", "p-bob"])
        XCTAssertEqual(ids(smart["tagIds"]), ["t-japon"])
        XCTAssertEqual(smart["isNotInAlbum"] as? Bool, true)
        XCTAssertEqual(smart["visibility"] as? String, "archive")
        for key in ["filter", "orderBy", "cursor", "originalFileName", "description", "albumIds", "order"] {
            XCTAssertNil(smart[key], "the Smart route has no `\(key)`")
        }
    }

    // MARK: - S-3: the Metadata shape follows the server generation

    func test_AC_214_metadataShapePerServerVersion() async throws {
        enum Version { case known(Int, Int, Int), unreadable }
        let cases: [(Version, structured: Bool)] = [
            (.known(2, 0, 0), false), (.known(3, 1, 0), false), (.unreadable, false),
            (.known(3, 2, 0), true), (.known(3, 4, 0), true),
        ]
        for (version, structured) in cases {
            let mock = makeMock()
            switch version {
            case .known(let major, let minor, let patch):
                mock.serverVersionResponse = ServerVersionResponseDto(
                    major: major, minor: minor, patch: patch, prerelease: nil
                )
            case .unreadable:
                mock.serverVersionError = URLError(.cannotConnectToHost)
            }
            let vm = SearchViewModel(client: mock)
            vm.filter.toggle(person: alice)
            vm.filter.toggle(person: bob)
            vm.filter.toggle(tag: japon)
            vm.filter.isNotInAlbum = true
            vm.filter.isArchived = true
            await vm.selectSearchMode(.filename)
            vm.query = "kyoto"
            await vm.search()

            let body = try json(try XCTUnwrap(mock.lastMetadataSearchDto))
            let label = "\(version)"
            if structured {
                let node = try XCTUnwrap(body["filter"] as? [String: Any], label)
                XCTAssertEqual(ids((node["personIds"] as? [String: Any])?["all"]), ["p-alice", "p-bob"], label)
                XCTAssertEqual(ids((node["tagIds"] as? [String: Any])?["all"]), ["t-japon"], label)
                XCTAssertEqual((node["hasAlbums"] as? [String: Any])?["eq"] as? Bool, false, label)
                XCTAssertEqual((node["visibility"] as? [String: Any])?["eq"] as? String, "archive", label)
                XCTAssertEqual((node["originalFileName"] as? [String: Any])?["like"] as? String, "kyoto", label)
                for key in ["page", "personIds", "tagIds", "isNotInAlbum", "visibility", "originalFileName",
                            "description", "rating", "isFavorite", "type"] {
                    XCTAssertNil(body[key], "\(label): \(key)")
                }
            } else {
                XCTAssertEqual(ids(body["personIds"]), ["p-alice", "p-bob"], label)
                XCTAssertEqual(ids(body["tagIds"]), ["t-japon"], label)
                XCTAssertEqual(body["isNotInAlbum"] as? Bool, true, label)
                XCTAssertEqual(body["visibility"] as? String, "archive", label)
                XCTAssertEqual(body["originalFileName"] as? String, "kyoto", label)
                XCTAssertEqual(body["page"] as? Int, 1, label)
                for key in ["filter", "orderBy", "cursor"] { XCTAssertNil(body[key], "\(label): \(key)") }
            }
        }
    }

    // MARK: - S-4: the Smart shape

    func test_AC_211_smartCarriesVisibility() async throws {
        let mock = makeMock(version: (3, 4, 0))
        let vm = SearchViewModel(client: mock)
        vm.query = "plage"

        await vm.search()
        XCTAssertEqual(vm.searchMode, .smart)
        XCTAssertEqual(mock.searchSmartCalls.last?.visibility, .timeline, "even with no filter at all")
        XCTAssertEqual(try json(try XCTUnwrap(mock.searchSmartCalls.last))["visibility"] as? String, "timeline")

        vm.filter.isArchived = true
        await vm.applyFilters()
        XCTAssertEqual(vm.searchMode, .smart, "a text plus a criterion stays Smart")
        XCTAssertEqual(mock.searchSmartCalls.last?.visibility, .archive)
        XCTAssertTrue(mock.searchMetadataCalls.isEmpty)
    }

    // MARK: - S-5: Smart with text and criteria

    func test_AC_218_smartWithTextKeepsFilters() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.query = "plage"
        vm.togglePerson(alice)

        await vm.applyFilters()

        XCTAssertEqual(vm.searchMode, .smart)
        let sent = mock.searchSmartCalls.last
        XCTAssertEqual(sent?.query, "plage")
        XCTAssertEqual(sent?.personIds, ["p-alice"])
        XCTAssertEqual(sent?.visibility, .timeline)
        XCTAssertEqual(sent?.page, 1)
        XCTAssertTrue(mock.searchMetadataCalls.isEmpty)
    }

    func test_AC_218_emptyTextFallsBackToMetadata() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.togglePerson(alice)

        await vm.applyFilters()

        XCTAssertEqual(vm.searchMode, .metadata, "Smart needs a text")
        XCTAssertEqual(mock.lastMetadataSearchDto?.personIds, ["p-alice"])
        XCTAssertTrue(mock.searchSmartCalls.isEmpty)
    }

    func test_AC_218_filtersThenTextReturnsToSmart() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.togglePerson(alice)
        await vm.applyFilters()
        XCTAssertEqual(vm.searchMode, .metadata)

        vm.query = "plage"
        await vm.search()

        XCTAssertEqual(vm.searchMode, .smart)
        XCTAssertEqual(mock.searchSmartCalls.last?.query, "plage")
        XCTAssertEqual(mock.searchSmartCalls.last?.personIds, ["p-alice"])
    }

    func test_AC_218_chosenMetadataIgnoresTyping() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        await vm.selectSearchMode(.metadata)
        vm.togglePerson(alice)
        await vm.applyFilters()

        vm.query = "plage"
        await vm.search()

        XCTAssertEqual(vm.searchMode, .metadata, "a mode picked in the menu is never changed by typing")
        XCTAssertTrue(mock.searchSmartCalls.isEmpty)
    }

    func test_AC_218_ocrToggleKeepsAutomaticMetadata() async {
        let mock = makeMock(version: (3, 4, 0))
        let vm = SearchViewModel(client: mock)
        vm.togglePerson(alice)
        await vm.applyFilters()
        XCTAssertEqual(vm.searchMode, .metadata)

        vm.ocrFilterEnabled = true
        vm.query = "plage"
        await vm.search()

        XCTAssertEqual(vm.searchMode, .metadata, "detected text is a Metadata-only criterion")
        XCTAssertTrue(mock.searchSmartCalls.isEmpty)
        XCTAssertEqual(mock.lastMetadataSearchDto?.filter?.ocr?.matches, "plage")
    }

    func test_AC_218_exploreThenTextReturnsToSmart() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        await vm.searchByExplore(field: .city, value: "Paris")
        XCTAssertEqual(mock.lastMetadataSearchDto?.city, "Paris")

        vm.query = "plage"
        await vm.search()

        XCTAssertEqual(vm.searchMode, .smart)
        XCTAssertEqual(mock.searchSmartCalls.last?.query, "plage")
        XCTAssertNil(mock.searchSmartCalls.last?.city, "typing drops the Explore card")
    }

    func test_AC_218_smartLoadMoreKeepsFilters() async {
        let mock = makeMock()
        mock.smartSearchResponse = response([asset("a1")], nextPage: "2")
        let vm = SearchViewModel(client: mock)
        vm.query = "plage"
        vm.togglePerson(alice)
        vm.filter.isArchived = true
        await vm.applyFilters()
        XCTAssertTrue(vm.canLoadMore)

        mock.smartSearchResponse = response([asset("a2")])
        await vm.loadMore()

        XCTAssertEqual(mock.searchSmartCalls.count, 2)
        let second = mock.searchSmartCalls[1]
        XCTAssertEqual(second.page, 2)
        XCTAssertEqual(second.query, "plage")
        XCTAssertEqual(second.personIds, ["p-alice"])
        XCTAssertEqual(second.visibility, .archive)
        XCTAssertEqual(vm.results.map(\.id), ["a1", "a2"])
    }

    func test_AC_218_smartShapeIsFlatOnEveryVersion() async throws {
        var bodies: [SmartSearchDto] = []
        for version in [(2, 0, 0), nil, (3, 4, 0)] as [(Int, Int, Int)?] {
            let mock = makeMock(version: version, countsProbe: true)
            if version == nil { mock.serverVersionError = URLError(.cannotConnectToHost) }
            let vm = SearchViewModel(client: mock)
            vm.query = "plage"
            vm.togglePerson(alice)
            await vm.applyFilters()

            XCTAssertEqual(mock.requestCount, 1, "Smart never asks the server's version")
            bodies.append(try XCTUnwrap(mock.searchSmartCalls.last))
            let body = try json(try XCTUnwrap(mock.searchSmartCalls.last))
            for key in ["filter", "orderBy", "cursor"] { XCTAssertNil(body[key], key) }
        }
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(bodies[1], bodies[2])
    }

    // MARK: - S-6: file name and description modes

    func test_AC_212_filenameModeSendsOriginalFileName() async throws {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        await vm.selectSearchMode(.filename)
        XCTAssertTrue(mock.searchMetadataCalls.isEmpty, "no text, no request")
        vm.query = "  img_12  "

        await vm.search()

        let dto = try XCTUnwrap(mock.lastMetadataSearchDto)
        XCTAssertEqual(dto.originalFileName, "img_12", "the text is trimmed")
        XCTAssertNil(dto.query)
        XCTAssertNil(dto.description)
        XCTAssertEqual(dto.visibility, .timeline)
    }

    func test_AC_212_descriptionModeSendsDescription() async throws {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        await vm.selectSearchMode(.description)
        vm.query = "biarritz"

        await vm.search()

        let dto = try XCTUnwrap(mock.lastMetadataSearchDto)
        XCTAssertEqual(dto.description, "biarritz")
        XCTAssertNil(dto.query)
        XCTAssertNil(dto.originalFileName)
    }

    func test_AC_212_backToSmartSendsQueryAndTimeline() async throws {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        await vm.selectSearchMode(.filename)
        vm.query = "img_12"
        await vm.search()

        await vm.selectSearchMode(.smart)

        let sent = try XCTUnwrap(mock.searchSmartCalls.last)
        XCTAssertEqual(sent.query, "img_12")
        XCTAssertEqual(sent.visibility, .timeline)
        let body = try json(sent)
        XCTAssertNil(body["originalFileName"])
        XCTAssertNil(body["description"])
    }

    func test_AC_212_modeChangeDuringSmartSearchRedispatches() async throws {
        let mock = makeMock()
        mock.smartSearchResponse = response([asset("smart-hit")])
        mock.searchMetadataResponse = response([asset("name-hit")])
        let latch = TestLatch()
        mock.searchSmartGate = { _ in try await latch.wait() }
        let vm = SearchViewModel(client: mock)
        vm.query = "img_12"

        let read = Task { @MainActor in await vm.search() }
        await pollUntil("the Smart search is in flight") { mock.searchSmartCalls.count == 1 }
        let change = Task { @MainActor in await vm.selectSearchMode(.filename) }
        try? await Task.sleep(for: .milliseconds(120))
        latch.open()
        await read.value
        await change.value

        XCTAssertEqual(mock.lastMetadataSearchDto?.originalFileName, "img_12")
        XCTAssertEqual(vm.results.map(\.id), ["name-hit"], "the superseded Smart answer is never shown")
    }

    // MARK: - S-7: the people picker

    func test_AC_209_loadsEveryPageWithoutHidden() async {
        let mock = makeMock()
        let carla = PersonResponseDto(id: "p-carla", name: "Carla", isHidden: true)
        mock.peopleResponsesByPage = [
            1: PeopleResponseDto(people: [alice], hidden: 1, total: 3, hasNextPage: true),
            2: PeopleResponseDto(people: [carla, bob], hidden: 1, total: 3, hasNextPage: nil),
        ]
        let vm = SearchViewModel(client: mock)
        XCTAssertEqual(vm.peopleOptionsState, .loading)

        await vm.loadPeopleOptions()

        XCTAssertEqual(vm.peopleOptions.map(\.id), ["p-alice", "p-bob"], "every page, hidden people never")
        XCTAssertEqual(mock.lastPeopleWithHidden, false)
        XCTAssertEqual(mock.lastPeoplePage, 2)
        XCTAssertEqual(vm.peopleOptionsState, .data(.idle))
    }

    func test_AC_209_matchingIgnoresCaseAndAccents() {
        let people = [
            alice, PersonResponseDto(id: "p-alvaro", name: "Àlvaro", isHidden: false), bob,
            PersonResponseDto(id: "p-anon", name: "", isHidden: false),
        ]
        XCTAssertEqual(SearchViewModel.matchingPeople(people, query: "al").map(\.id), ["p-alice", "p-alvaro"])
        XCTAssertEqual(SearchViewModel.matchingPeople(people, query: "ÀLV").map(\.id), ["p-alvaro"])
        XCTAssertEqual(SearchViewModel.matchingPeople(people, query: "  ").map(\.id), people.map(\.id), "blank = everyone")
    }

    func test_AC_209_failureKeepsPreviousOptions() async {
        let mock = makeMock()
        mock.peopleResponse = PeopleResponseDto(people: [alice], hidden: 0, total: 1, hasNextPage: nil)
        let vm = SearchViewModel(client: mock)
        await vm.loadPeopleOptions()
        XCTAssertEqual(vm.peopleOptions.map(\.id), ["p-alice"])

        mock.peopleError = URLError(.notConnectedToInternet)
        await vm.loadPeopleOptions()

        XCTAssertEqual(vm.peopleOptions.map(\.id), ["p-alice"], "a failed read keeps the list")
        XCTAssertNotNil(vm.peopleOptionsError)
        guard case .data(.failed) = vm.peopleOptionsState else {
            return XCTFail("expected the list with a failure banner, got \(vm.peopleOptionsState)")
        }

        mock.peopleError = nil
        await vm.loadPeopleOptions()
        XCTAssertNil(vm.peopleOptionsError)
    }

    func test_AC_42_twoPeopleSentInSelectionOrder() async throws {
        for version in [nil, (3, 4, 0)] as [(Int, Int, Int)?] {
            let mock = makeMock(version: version)
            let vm = SearchViewModel(client: mock)
            vm.togglePerson(bob)
            vm.togglePerson(alice)

            await vm.applyFilters()

            let dto = try XCTUnwrap(mock.lastMetadataSearchDto)
            if version == nil {
                XCTAssertEqual(dto.personIds, ["p-bob", "p-alice"])
            } else {
                XCTAssertEqual(dto.filter?.personIds?.all, ["p-bob", "p-alice"], "every person must appear")
                XCTAssertNil(dto.personIds)
            }
        }
    }

    // MARK: - S-8: the tag picker

    func test_AC_210_tagRowsCarryPathAndRequestCarriesTagId() async throws {
        for version in [nil, (3, 4, 0)] as [(Int, Int, Int)?] {
            let mock = makeMock(version: version)
            mock.tagsResponse = [japon, voyages]
            let vm = SearchViewModel(client: mock)
            XCTAssertEqual(vm.tagOptionsState, .loading)

            await vm.loadTagOptions()

            XCTAssertEqual(vm.tagOptions.map(\.tag.id), ["t-voyages", "t-japon"])
            XCTAssertEqual(vm.tagOptions.map(\.depth), [0, 1])
            XCTAssertEqual(vm.tagOptions[1].tag.path, "Voyages/Japon")

            vm.toggleTag(vm.tagOptions[1].tag)
            XCTAssertEqual(vm.filter.tags, [SearchFilter.Tag(id: "t-japon", path: "Voyages/Japon")])
            await vm.applyFilters()

            let dto = try XCTUnwrap(mock.lastMetadataSearchDto)
            if version == nil {
                XCTAssertEqual(dto.tagIds, ["t-japon"], "the id only: the server adds the descendants")
            } else {
                XCTAssertEqual(dto.filter?.tagIds?.all, ["t-japon"])
            }
        }
    }

    func test_AC_210_tagFailureKeepsPreviousRows() async {
        let mock = makeMock()
        mock.tagsResponse = [voyages]
        let vm = SearchViewModel(client: mock)
        await vm.loadTagOptions()

        mock.tagsError = URLError(.notConnectedToInternet)
        await vm.loadTagOptions()

        XCTAssertEqual(vm.tagOptions.map(\.tag.id), ["t-voyages"])
        XCTAssertNotNil(vm.tagOptionsError)
    }

    // MARK: - S-10: chips, badge and Reset

    func test_AC_213_removeTagKeepsOthersThenResetBackToTimeline() async throws {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        vm.togglePerson(alice)
        vm.togglePerson(bob)
        vm.toggleTag(japon)
        vm.filter.isNotInAlbum = true
        vm.filter.isArchived = true
        await vm.applyFilters()
        XCTAssertEqual(vm.activeFilterCount, 4, "one chip per criterion: people, tags, not in album, archive")
        XCTAssertEqual(vm.activeConstraints.map(\.field), [.personIds, .tagIds, .isNotInAlbum, .visibility])

        await vm.removeConstraint(.tagIds)

        var dto = try XCTUnwrap(mock.lastMetadataSearchDto)
        XCTAssertNil(dto.tagIds)
        XCTAssertEqual(dto.personIds, ["p-alice", "p-bob"])
        XCTAssertEqual(dto.isNotInAlbum, true)
        XCTAssertEqual(dto.visibility, .archive)

        await vm.clearFilters()

        dto = try XCTUnwrap(mock.lastMetadataSearchDto)
        XCTAssertNil(dto.personIds)
        XCTAssertNil(dto.tagIds)
        XCTAssertNil(dto.isNotInAlbum)
        XCTAssertEqual(dto.visibility, .timeline, "Archive is back to off")
        XCTAssertEqual(vm.activeFilterCount, 0)
    }

    func test_AC_213_textModeChipCountsAndRemovesBackToSmart() async throws {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        await vm.selectSearchMode(.filename)
        vm.query = "img_12"
        vm.toggleTag(japon)

        XCTAssertEqual(vm.activeConstraints.map(\.field), [.originalFileName, .tagIds])
        XCTAssertEqual(vm.activeFilterCount, 2)
        XCTAssertTrue(vm.isFilterActive)

        await vm.removeConstraint(.originalFileName)

        XCTAssertEqual(vm.searchMode, .smart)
        XCTAssertEqual(vm.query, "img_12", "the text stays")
        let sent = try XCTUnwrap(mock.searchSmartCalls.last)
        XCTAssertEqual(sent.query, "img_12")
        XCTAssertEqual(sent.tagIds, ["t-japon"])
        XCTAssertEqual(vm.activeFilterCount, 1)
    }

    func test_AC_213_resetLeavesTextModeKeepsText() async {
        let mock = makeMock()
        let vm = SearchViewModel(client: mock)
        await vm.selectSearchMode(.description)
        vm.query = "biarritz"
        vm.toggleTag(japon)
        XCTAssertEqual(vm.activeFilterCount, 2)

        await vm.clearFilters()

        XCTAssertEqual(vm.searchMode, .smart)
        XCTAssertEqual(vm.query, "biarritz")
        XCTAssertEqual(vm.activeFilterCount, 0)
        XCTAssertEqual(mock.searchSmartCalls.last?.query, "biarritz")
        XCTAssertNil(mock.searchSmartCalls.last?.tagIds)
    }

    func test_AC_213_applyDuringInFlightSearchRedispatches() async throws {
        let mock = makeMock()
        let latch = TestLatch()
        let withAlice = response([asset("alice-hit")])
        let stale = response([asset("stale-hit")])
        mock.searchMetadataGate = { dto in
            if dto.personIds == nil { try await latch.wait() }
        }
        mock.searchMetadataHandler = { dto in
            dto.personIds == nil ? stale : withAlice
        }
        let vm = SearchViewModel(client: mock)
        await vm.selectSearchMode(.metadata)
        vm.query = "plage"

        let read = Task { @MainActor in await vm.search() }
        await pollUntil("the first search is in flight") { mock.searchMetadataCalls.count == 1 }
        vm.togglePerson(alice)
        let apply = Task { @MainActor in await vm.applyFilters() }
        try? await Task.sleep(for: .milliseconds(120))
        latch.open()
        await read.value
        await apply.value

        XCTAssertEqual(mock.searchMetadataCalls.count, 2)
        XCTAssertEqual(mock.searchMetadataCalls.last?.personIds, ["p-alice"])
        XCTAssertEqual(vm.results.map(\.id), ["alice-hit"], "the old answer is dropped, the new one shown")
    }

    // MARK: - AC-43: the criteria accumulate, in both shapes

    func test_AC_43_cumulatedCriteriaReachEachRequest() async throws {
        for structured in [false, true] {
            let mock = makeMock(version: structured ? (3, 4, 0) : nil)
            let vm = SearchViewModel(client: mock)
            vm.query = "kyoto"
            await vm.selectSearchMode(.metadata)
            func sent() throws -> MetadataSearchDto { try XCTUnwrap(mock.lastMetadataSearchDto) }
            func isArchive(_ dto: MetadataSearchDto) -> Bool {
                structured ? dto.filter?.visibility?.eq == "archive" : dto.visibility == .archive
            }
            func notInAlbum(_ dto: MetadataSearchDto) -> Bool {
                structured ? dto.filter?.hasAlbums?.eq == false : dto.isNotInAlbum == true
            }
            func archivedAndOutOfAlbum() throws -> Bool {
                let dto = try sent()
                return isArchive(dto) && notInAlbum(dto)
            }
            func tagIds(_ dto: MetadataSearchDto) -> [String]? {
                structured ? dto.filter?.tagIds?.all : dto.tagIds
            }
            func fileName(_ dto: MetadataSearchDto) -> String? {
                structured ? dto.filter?.originalFileName?.like : dto.originalFileName
            }
            func descriptionOf(_ dto: MetadataSearchDto) -> String? {
                structured ? dto.filter?.description?.like : dto.description
            }

            vm.filter.isArchived = true
            await vm.applyFilters()
            XCTAssertTrue(isArchive(try sent()), "archive, structured=\(structured)")

            vm.filter.isNotInAlbum = true
            await vm.applyFilters()
            XCTAssertTrue(try archivedAndOutOfAlbum(), "not in album, structured=\(structured)")

            vm.toggleTag(japon)
            await vm.applyFilters()
            XCTAssertEqual(tagIds(try sent()), ["t-japon"], "tag, structured=\(structured)")
            XCTAssertTrue(try archivedAndOutOfAlbum())

            await vm.selectSearchMode(.filename)
            XCTAssertEqual(fileName(try sent()), "kyoto", "file name, structured=\(structured)")
            XCTAssertNil(descriptionOf(try sent()))
            XCTAssertEqual(tagIds(try sent()), ["t-japon"])
            XCTAssertTrue(try archivedAndOutOfAlbum())

            await vm.selectSearchMode(.description)
            XCTAssertEqual(descriptionOf(try sent()), "kyoto", "description, structured=\(structured)")
            XCTAssertNil(fileName(try sent()), "the previous mode's criterion is gone")
            XCTAssertEqual(tagIds(try sent()), ["t-japon"])
            XCTAssertTrue(try archivedAndOutOfAlbum())
        }
    }
}
