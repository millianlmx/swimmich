import Foundation

/// Footer of a paginated list or grid: nothing, a spinner that requests the
/// next page when it appears, or the error of the last next-page request.
enum ListFooter: Equatable {
    case none
    case loadingMore
    case error(String)
}

/// People & faces state (P3 people-faces): person list, face-thumbnail counts,
/// rename / favorite / hide / merge, and a faces drill-down grid of one
/// person's assets (via `searchMetadata(personIds:)` — the server no longer
/// exposes /people/{id}/assets).
///
/// Both the list (`GET /people?page=`, offset pagination) and the grid
/// (`POST /search/metadata`, `page`/`nextPage`) load page by page. A stale
/// response is dropped by an integer generation captured before the `await`
/// (never by `Task.isCancelled`), the convention of `AlbumDetailViewModel`.
@Observable
@MainActor
final class PeopleViewModel {
    let client: any ImmichClient

    var people: [PersonResponseDto] = []
    var hiddenCount = 0
    var total = 0
    var showingHidden = false
    var isLoading = false
    var errorMessage: String?

    /// Per-person asset counts (GET /people/{id}/statistics), keyed by person id.
    var statsByID: [String: Int] = [:]

    /// List pagination.
    private(set) var hasMorePeople = false
    private(set) var isLoadingMorePeople = false
    private(set) var peopleLoadMoreError: String?
    /// Changes whenever the end of the list may have moved, so the footer
    /// spinner re-triggers `loadMorePeople()` while the user sits at the bottom.
    private(set) var peopleEndRevision = 0
    private var nextPeoplePage: Int?
    private var peopleGeneration = 0
    private var loadedPeopleIds: Set<String> = []
    private var lastVisit: UUID?
    /// Last server answer per person id, written by `apply` whether or not the
    /// person is in `people`: a person that left the loaded pages (merge target
    /// on page 2+, reload to page 1) keeps its edits in the detail.
    private var lastKnownPeople: [String: PersonResponseDto] = [:]

    /// Faces drill-down state.
    var personAssets: [AssetReactItem] = []
    var assetsLoading = false
    var assetsError: String?
    var selectedPersonID: String?

    /// Grid pagination.
    private(set) var hasMoreAssets = false
    private(set) var isLoadingMoreAssets = false
    private(set) var assetsLoadMoreError: String?
    private(set) var assetsEndRevision = 0
    private var assetsNextPage: Int?
    private var assetsGeneration = 0
    private var loadedAssetIds: Set<String> = []

    /// Test-visible: last merge payload.
    private(set) var lastMergeIds: [String]?
    private(set) var lastMergeTarget: String?

    /// Fan-out for statistics enrichment (mirrors SearchViewModel explore).
    private let statsConcurrency = 6
    private var assetsLoadedForID: String?

    init(client: any ImmichClient) {
        self.client = client
    }

    var selectedPerson: PersonResponseDto? {
        guard let id = selectedPersonID else { return nil }
        return people.first { $0.id == id }
    }

    func assetCount(for id: String) -> Int {
        statsByID[id] ?? 0
    }

    /// The row to show for a person the navigation pushed: the loaded row, else
    /// the last server answer of this session, else the pushed snapshot.
    func livePerson(_ pushed: PersonResponseDto) -> PersonResponseDto {
        people.first { $0.id == pushed.id } ?? lastKnownPeople[pushed.id] ?? pushed
    }

    // MARK: - Displayed order

    /// Favorites, by photo count descending (server order on ties).
    var featuredPeople: [PersonResponseDto] {
        sortedByCount(people.filter { $0.isFavorite == true })
    }

    var otherPeople: [PersonResponseDto] {
        sortedByCount(people.filter { $0.isFavorite != true })
    }

    /// The last row the list shows: after the Featured / People split and the
    /// count sort, not `people.last`.
    var lastDisplayedPersonID: String? {
        (otherPeople.last ?? featuredPeople.last)?.id
    }

    private func sortedByCount(_ list: [PersonResponseDto]) -> [PersonResponseDto] {
        list.enumerated()
            .sorted { a, b in
                let ca = assetCount(for: a.element.id)
                let cb = assetCount(for: b.element.id)
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: - List

    var peopleFooter: ListFooter {
        if let message = peopleLoadMoreError { return .error(message) }
        return hasMorePeople ? .loadingMore : .none
    }

    /// Entry point of the screen's `.task`. The same token (the detail popped
    /// back, which replays the task) does nothing; a new token (a fresh push
    /// from Profile) reloads page 1 and every count.
    func appear(visit: UUID) async {
        guard visit != lastVisit else { return }
        lastVisit = visit
        await refresh()
    }

    /// Pull to refresh, "Refresh people", "Retry": page 1, then every count.
    func refresh() async {
        await load(force: true)
        await loadStatistics()
    }

    func load(force: Bool = false) async {
        guard !(isLoading && !force) else { return }
        peopleGeneration += 1
        let g = peopleGeneration
        isLoading = true
        isLoadingMorePeople = false
        defer { if g == peopleGeneration { isLoading = false } }
        do {
            let page = try await client.getPeople(page: 1, withHidden: showingHidden)
            guard g == peopleGeneration else { return }
            var seen = Set<String>()
            people = page.people.filter { seen.insert($0.id).inserted }
            loadedPeopleIds = seen
            hiddenCount = page.hidden
            total = page.total
            hasMorePeople = page.hasNextPage == true
            nextPeoplePage = 2
            peopleLoadMoreError = nil
            errorMessage = nil
            peopleEndRevision += 1
        } catch {
            guard g == peopleGeneration, let message = error.userFacingMessage else { return }
            errorMessage = message
        }
    }

    /// The last displayed row appeared: ask for the next page. Any other row,
    /// including a search result, does nothing.
    func personRowAppeared(_ id: String) async {
        guard id == lastDisplayedPersonID else { return }
        await loadMorePeople()
    }

    func loadMorePeople() async {
        guard !isLoading, !isLoadingMorePeople, hasMorePeople, let page = nextPeoplePage else { return }
        isLoadingMorePeople = true
        let g = peopleGeneration
        do {
            let response = try await client.getPeople(page: page, withHidden: showingHidden)
            guard g == peopleGeneration else { return }
            var added: [String] = []
            for person in response.people where loadedPeopleIds.insert(person.id).inserted {
                people.append(person)
                added.append(person.id)
            }
            hiddenCount = response.hidden
            total = response.total
            hasMorePeople = response.hasNextPage == true
            nextPeoplePage = page + 1
            peopleLoadMoreError = nil
            isLoadingMorePeople = false
            peopleEndRevision += 1
            await fetchMissingStatistics(for: added)
        } catch {
            guard g == peopleGeneration else { return }
            peopleLoadMoreError = error.userFacingMessage
            isLoadingMorePeople = false
        }
    }

    func toggleShowHidden() async {
        showingHidden.toggle()
        await load(force: true)
        await fetchMissingStatistics(for: people.map(\.id))
    }

    // MARK: - Statistics

    /// Re-asks the count of every loaded person.
    func loadStatistics() async {
        await fetchStatistics(for: people.map(\.id))
    }

    /// Asks only the counts that are not known yet.
    private func fetchMissingStatistics(for ids: [String]) async {
        await fetchStatistics(for: ids.filter { statsByID[$0] == nil })
    }

    /// Bounded task-group fan-out. Successes are merged into `statsByID`
    /// (ids outside `people` are kept); a failure writes nothing, so the id
    /// stays unknown and is asked again next time.
    private func fetchStatistics(for ids: [String]) async {
        var offset = 0
        while offset < ids.count {
            let upper = min(offset + statsConcurrency, ids.count)
            let slice = ids[offset..<upper]
            offset = upper
            let counts: [(id: String, count: Int)] = await withTaskGroup(of: (id: String, count: Int)?.self) { group in
                for id in slice {
                    group.addTask { [client] in
                        guard let stats = try? await client.getPersonStatistics(id: id) else { return nil }
                        return (id, stats.assets)
                    }
                }
                var results: [(id: String, count: Int)] = []
                for await result in group {
                    if let result { results.append(result) }
                }
                return results
            }
            for (id, count) in counts { statsByID[id] = count }
        }
    }

    // MARK: - Person actions (all via PUT /people/{id})

    func rename(_ person: PersonResponseDto, to name: String) async {
        await updateAndReloadIfPaged(person.id, PersonUpdateDto(name: name))
    }

    func toggleFavorite(_ person: PersonResponseDto) async {
        await updateAndReloadIfPaged(person.id, PersonUpdateDto(isFavorite: !(person.isFavorite ?? false)))
    }

    func toggleHidden(_ person: PersonResponseDto) async {
        await updateAndReloadIfPaged(person.id, PersonUpdateDto(isHidden: !person.isHidden))
    }

    /// Sets a person's cover / feature photo (gap #4): PUT /people/{id}
    /// {featureFaceAssetId}. The cover is one of the person's face assets.
    func setFeatureFace(_ person: PersonResponseDto, assetId: String) async {
        await update(person.id, PersonUpdateDto(featureFaceAssetId: assetId))
    }

    /// Sets or clears a person's birthday (gap G15). `wire` is the date-only
    /// `"YYYY-MM-DD"` form: a value rides `PersonUpdateDto(birthDate:)`, so the
    /// synthesized encoder leaves the other five fields out of the body; `nil`
    /// rides `clearPersonBirthday`, whose body is the explicit `null` — the only
    /// form the server reads as an erase.
    func setBirthday(_ person: PersonResponseDto, to wire: String?) async {
        if let wire {
            await apply(person.id) { try await client.updatePerson(id: person.id, dto: PersonUpdateDto(birthDate: wire)) }
        } else {
            await apply(person.id) { try await client.clearPersonBirthday(id: person.id) }
        }
    }

    /// Name, favorite and hidden decide the server's place of a person (favorites
    /// first, then name) or whether `withHidden=false` returns it at all. With
    /// offset pagination the next page asked as is could skip a person at the
    /// boundary, so once an edit succeeds and pages remain, the list restarts
    /// from page 1. Birthday and cover do not enter the order: no reload.
    private func updateAndReloadIfPaged(_ id: String, _ dto: PersonUpdateDto) async {
        guard await update(id, dto), hasMorePeople else { return }
        await load(force: true)
        await fetchMissingStatistics(for: people.map(\.id))
    }

    @discardableResult
    private func update(_ id: String, _ dto: PersonUpdateDto) async -> Bool {
        await apply(id) { try await client.updatePerson(id: id, dto: dto) }
    }

    /// The one path both write shapes share: run `call`, replace the row with
    /// the server's answer (and remember it for `livePerson`), and surface a
    /// failure. Neither the erase nor the set may duplicate it — an erase that
    /// forgot to rewrite `people` would look applied until the next load.
    @discardableResult
    private func apply(_ id: String, _ call: () async throws -> PersonResponseDto) async -> Bool {
        do {
            let updated = try await call()
            if let i = people.firstIndex(where: { $0.id == id }) { people[i] = updated }
            lastKnownPeople[id] = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.userFacingMessage
            return false
        }
    }

    /// Merges the given persons INTO `person` (POST /people/{id}/merge), then
    /// reloads the list from page 1, the counts, and the target's grid.
    func merge(_ ids: [String], into person: PersonResponseDto) async {
        lastMergeIds = ids
        lastMergeTarget = person.id
        do {
            _ = try await client.mergePeople(ids: ids, into: person.id)
        } catch {
            errorMessage = error.userFacingMessage
            return
        }
        errorMessage = nil
        await load(force: true)
        await fetchMissingStatistics(for: people.map(\.id))
        // The target absorbed photos: its known count is stale.
        await fetchStatistics(for: [person.id])
        // `loadAssets()` would return at once (same id already loaded).
        if selectedPersonID == person.id { await refreshAssets() }
    }

    // MARK: - Faces drill-down

    var assetsFooter: ListFooter {
        if let message = assetsLoadMoreError { return .error(message) }
        return hasMoreAssets ? .loadingMore : .none
    }

    func select(_ person: PersonResponseDto) async {
        // The detail's `.task` replays when it reappears: keep the pagination.
        if selectedPersonID == person.id, assetsLoadedForID == person.id { return }
        selectedPersonID = person.id
        resetAssetsGrid()
        await loadAssets()
    }

    func loadAssets() async {
        guard let id = selectedPersonID else { return }
        if assetsLoadedForID == id { return }
        assetsLoadedForID = id
        await fetchAssets(id)
    }

    func refreshAssets() async {
        guard let id = selectedPersonID else { return }
        await fetchAssets(id)
    }

    /// Loads page 1 and replaces the grid. The old grid stays on screen while
    /// the request is in flight; a page 2 of the old series is dropped.
    private func fetchAssets(_ id: String) async {
        assetsGeneration += 1
        let g = assetsGeneration
        assetsLoading = true
        isLoadingMoreAssets = false
        defer { if g == assetsGeneration { assetsLoading = false } }
        do {
            let resp = try await client.searchMetadata(dto: assetsDto(id, page: 1))
            guard g == assetsGeneration, selectedPersonID == id else { return }
            var seen = Set<String>()
            personAssets = resp.assets.items.map { AssetReactItem(from: $0) }.filter { seen.insert($0.id).inserted }
            loadedAssetIds = seen
            assetsNextPage = resp.assets.nextPage.flatMap(Int.init)
            hasMoreAssets = assetsNextPage != nil
            assetsError = nil
            assetsLoadMoreError = nil
            assetsEndRevision += 1
        } catch {
            guard g == assetsGeneration, let message = error.userFacingMessage else { return }
            assetsError = message
        }
    }

    /// The last grid cell appeared: ask for the next page.
    func assetCellAppeared(_ id: String) async {
        guard id == personAssets.last?.id else { return }
        await loadMoreAssets()
    }

    func loadMoreAssets() async {
        guard let personID = selectedPersonID, !assetsLoading, !isLoadingMoreAssets,
              hasMoreAssets, let page = assetsNextPage else { return }
        isLoadingMoreAssets = true
        let g = assetsGeneration
        do {
            let resp = try await client.searchMetadata(dto: assetsDto(personID, page: page))
            guard g == assetsGeneration, selectedPersonID == personID else { return }
            for item in resp.assets.items where loadedAssetIds.insert(item.id).inserted {
                personAssets.append(AssetReactItem(from: item))
            }
            assetsNextPage = resp.assets.nextPage.flatMap(Int.init)
            hasMoreAssets = assetsNextPage != nil
            assetsLoadMoreError = nil
            isLoadingMoreAssets = false
            assetsEndRevision += 1
        } catch {
            guard g == assetsGeneration else { return }
            assetsLoadMoreError = error.userFacingMessage
            isLoadingMoreAssets = false
        }
    }

    private func assetsDto(_ personID: String, page: Int) -> MetadataSearchDto {
        var dto = MetadataSearchDto()
        dto.personIds = [personID]
        dto.page = page
        return dto
    }

    private func resetAssetsGrid() {
        personAssets = []
        loadedAssetIds = []
        assetsNextPage = nil
        hasMoreAssets = false
        isLoadingMoreAssets = false
        assetsError = nil
        assetsLoadMoreError = nil
    }

    func clearSelection() {
        assetsGeneration += 1
        selectedPersonID = nil
        assetsLoadedForID = nil
        assetsLoading = false
        resetAssetsGrid()
    }
}
