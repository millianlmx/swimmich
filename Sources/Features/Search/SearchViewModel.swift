import Foundation

/// One row in the Explore Places list — a distinct city with its representative
/// asset (for the hero thumbnail), location metadata, most-recent date, and
/// (lazily loaded) photo count. Identifiable by city name (server returns one
/// representative asset per distinct city via GET /search/cities).
struct ExplorePlace: Identifiable, Equatable {
    let id: String          // city name (stable identity)
    let city: String
    let state: String?
    let country: String?
    let date: Date?         // representative asset's dateTimeOriginal
    let assetId: String     // representative asset (thumbnail URL source)
    let thumbhash: String?
    var photoCount: Int?    // nil = count still loading

    /// Subtitle: "State, Country" (whichever parts exist), joined.
    var subtitle: String {
        [state, country].compactMap { $0 }.joined(separator: ", ")
    }

    /// Flag emoji derived client-side from `country`, or nil if unresolved.
    var flag: String? { CountryFlag.emoji(forCountryName: country) }
}

/// Search feature ViewModel — covers cahier §6 MVP:
/// - free-text metadata search (`POST /api/search/metadata`)
/// - CLIP semantic smart search (`POST /api/search/smart`)
/// - curated explore suggestions (`GET /api/search/explore`)
/// - people, tags, display options (not in album, favourites, archive), and
///   the file name / description text modes, as criteria of the two routes
///
/// `@Observable @MainActor` mirrors TimelineViewModel / TrashViewModel.
@Observable
@MainActor
final class SearchViewModel {
    /// How the typed text is read. Smart is CLIP; Metadata keeps the OCR
    /// toggle; file name and description are `POST /api/search/metadata`
    /// criteria (a substring, case and accent insensitive).
    enum SearchMode: String, CaseIterable, Hashable { case smart, metadata, filename, description }
    enum ViewMode: Hashable { case results, explore, map }

    /// EXIF field a user can drill into from an Explore card. Maps the server's
    /// `fieldName` ("exifInfo.city" …) onto the matching `MetadataSearchDto`
    /// property so a tap under "Cameras" searches `make`, not `city`.
    enum ExploreField: String {
        case city, country, make, model, state, lensModel

        /// Parses a raw Immich `fieldName` ("exifInfo.city" → `.city`).
        /// Returns nil for unrecognized fields (card tap no-ops gracefully).
        init?(rawFieldName: String) {
            // Strip the "exifInfo." prefix; map the remainder to the enum case.
            let key = rawFieldName.hasPrefix("exifInfo.")
                ? String(rawFieldName.dropFirst("exifInfo.".count))
                : rawFieldName
            self.init(rawValue: key)
        }

        /// Writes `value` into the matching EXIF field on `dto`.
        func apply(_ value: String, to dto: inout MetadataSearchDto) {
            switch self {
            case .city: dto.city = value
            case .country: dto.country = value
            case .make: dto.make = value
            case .model: dto.model = value
            case .state: dto.state = value
            case .lensModel: dto.lensModel = value
            }
        }
    }

    let client: any ImmichClient
    /// The timeline's selection and batch actions, reused as the engine of the
    /// result grid (L-23b). Private to this view model — never shared; its
    /// `items` mirror `results` (`results.didSet`) and every action copies them
    /// back (`runBatch`).
    private let batch: TimelineViewModel
    private let recentsStore: RecentSearchesStore
    private let savedStore: SavedSearchesStore

    // Inputs
    var query: String = ""
    var searchMode: SearchMode = .smart
    /// The current Metadata mode was taken by the view model (criteria with no
    /// text, an Explore card), not picked in the menu: typing a text returns
    /// to Smart (S-5).
    private var metadataIsAutomatic = false
    var viewMode: ViewMode = .results
    /// Restrict metadata results to assets whose *detected text* matches the
    /// query (ocr-text). Sent as the v3.2.0 `filter.ocr.matches` similarity
    /// filter, never as the deprecated scalar `MetadataSearchDto.ocr`.
    var ocrFilterEnabled = false
    /// Active Explore drill-down filter (AC-404b, generalized to any field).
    /// When non-nil, metadata `search()` ignores free-text `query` and filters
    /// by this field instead. Public for `recordRecentSearch` / view wiring.
    var pendingExploreFilter: (ExploreField, String)? = nil

    /// The Filters sheet's state (search-filters): every constraint the sheet
    /// edits lives here, and `apply(to:)` is the only reader that touches a DTO.
    var filter = SearchFilter()
    /// The criteria the bar shows, in the bar's order: the file name /
    /// description text mode first, then the sheet's constraints.
    var activeConstraints: [SearchFilter.Constraint] {
        (textModeConstraint.map { [$0] } ?? []) + filter.constraints
    }
    /// Active constraints — the number the toolbar button badges.
    var activeFilterCount: Int { activeConstraints.count }
    var isFilterActive: Bool { !activeConstraints.isEmpty }

    /// The file name / description text mode, as a chip: only while that mode
    /// is chosen and a text is typed.
    var textModeConstraint: SearchFilter.Constraint? {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        switch searchMode {
        case .filename:
            return SearchFilter.Constraint(field: .originalFileName, label: String(localized: "File name, \(typed)"))
        case .description:
            return SearchFilter.Constraint(field: .description, label: String(localized: "Description, \(typed)"))
        case .smart, .metadata:
            return nil
        }
    }

    /// Star-rating filter (star-ratings) — `nil` = no rating constraint.
    /// Sticky by design: it survives text edits and Explore drill-downs; only
    /// "Any rating" in the filter menu, the sheet's Clear, or `clearFilters()`
    /// clear it.
    ///
    /// A view onto `filter.rating`: the toolbar menu and the Filters sheet edit
    /// one value, and a rating outside the server's `1...5` scale (including
    /// `0`, invalid since v3) means "no constraint" rather than a request the
    /// server would reject.
    var ratingFilter: Int? {
        get { filter.rating }
        set { filter.rating = newValue.flatMap { (1...5).contains($0) ? $0 : nil } }
    }

    /// Convenience: the city value when the active filter is a city (legacy
    /// accessor + tests). Nil for non-city filters or when no filter is set.
    var selectedCity: String? {
        if case (.city, let value)? = pendingExploreFilter { return value }
        return nil
    }

    // Results
    private(set) var results: [AssetReactItem] = [] {
        // The batch engine acts on the rows the grid shows (selection, owner
        // split, favourite targets): keep its copy in step with every change.
        didSet { batch.items = results }
    }
    private(set) var loadedIds: Set<String> = []
    private(set) var currentPage: Int = 1
    /// Flat pagination token: the page number the flat route must send next
    /// (`nil` on a structured response, which paginates with `nextCursor`).
    private(set) var nextPage: String? = nil
    /// Structured pagination token (v3.2.0): the cursor the next request must
    /// carry. Exactly one of the two is ever set — the route that answered owns
    /// the pagination.
    private(set) var nextCursor: String? = nil
    var canLoadMore: Bool { nextPage != nil || nextCursor != nil }
    var hasSearched: Bool = false
    /// Whether the last failed read was a `loadMore()` (decides what "Try Again" re-runs).
    private var lastFailureWasLoadMore = false

    /// Render state of the results (S-1); `hasSearched` plays the role of `hasLoaded`.
    var resultsState: ListRenderState {
        .resolve(
            isEmpty: results.isEmpty,
            hasLoaded: hasSearched,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            loadError: errorMessage
        )
    }

    // Explore (AC-404) — Places list powered by GET /search/cities.
    private(set) var exploreData: [SearchExploreResponseDto] = []
    /// The full Places list (every city, no ≥5-photo floor), enriched with
    /// per-place photo counts. Drives the Explore view. `photoCount == nil`
    /// means the count is still loading for that place.
    private(set) var explorePlaces: [ExplorePlace] = []

    // Recent searches (UX)
    private(set) var recentSearches: [String] = []

    // Saved searches (gap #11, local)
    private(set) var savedSearches: [SavedSearch] = []

    // MARK: - Server search shape (v3.2.0 `filter` / `orderBy` / `cursor`)

    /// Version the server reported, `nil` while unknown (never probed, or a
    /// probe that failed). Not persisted: signing out builds a new VM, so an
    /// app re-pointed at another server never keeps the old answer.
    private var serverVersion: ServerVersionResponseDto?

    /// Whether the server has the v3.2.0 structured search — the generation
    /// test the whole request shape hangs on. `false` while the version is
    /// unknown: the flat route works everywhere, so "unknown" must degrade to
    /// it, never to a body only a new server accepts.
    var supportsStructuredSearch: Bool {
        guard let serverVersion else { return false }
        let minimum = Self.structuredSearchMinimum
        return serverVersion.isAtLeast(major: minimum.major, minor: minimum.minor, patch: minimum.patch)
    }

    /// The first server version with the structured search. The one place the
    /// threshold is written: the guard above and the "requires Immich X or
    /// later" notice of the Filters sheet both read it.
    static let structuredSearchMinimum = ServerVersionResponseDto(major: 3, minor: 2, patch: 0, prerelease: nil)

    /// "3.2" for the threshold above; the patch is only written when non-zero.
    static var structuredSearchMinimumLabel: String {
        let minimum = structuredSearchMinimum
        let base = "\(minimum.major).\(minimum.minor)"
        return minimum.patch == 0 ? base : "\(base).\(minimum.patch)"
    }

    /// Asks the server for its version once, and remembers the answer.
    ///
    /// Lazy on purpose: nothing probes at launch — the first metadata request
    /// does (each carries `visibility`, spelled differently per generation),
    /// and so does the Filters sheet, which must tell the user what the server
    /// can search before anything is sent. A failed probe stays unknown, so the
    /// next request retries it.
    func probeSearchShape() async {
        guard serverVersion == nil else { return }
        serverVersion = try? await client.serverVersion()
    }

    // MARK: - People and tag pickers (the Filters sheet's two pushed screens)

    /// Every non-hidden person, in the server's order, read once per opening of
    /// the picker and filtered locally (`matchingPeople`).
    private(set) var peopleOptions: [PersonResponseDto] = []
    private(set) var peopleOptionsError: String?
    private var peopleOptionsLoaded = false
    private var isLoadingPeopleOptions = false

    var peopleOptionsState: ListRenderState {
        .resolve(
            isEmpty: peopleOptions.isEmpty,
            hasLoaded: peopleOptionsLoaded,
            isLoading: isLoadingPeopleOptions,
            isRefreshing: false,
            loadError: peopleOptionsError
        )
    }

    /// Reads every page of `GET /api/people` (hidden people excluded), then
    /// replaces the list in one go: a failure on page 3 keeps the previous
    /// list and publishes the reason.
    func loadPeopleOptions() async {
        guard !isLoadingPeopleOptions else { return }
        isLoadingPeopleOptions = true
        defer { isLoadingPeopleOptions = false }
        do {
            var collected: [PersonResponseDto] = []
            var page = 1
            while true {
                let response = try await client.getPeople(page: page, withHidden: false)
                collected.append(contentsOf: response.people.filter { !$0.isHidden })
                guard response.hasNextPage == true, !response.people.isEmpty else { break }
                page += 1
            }
            peopleOptions = collected
            peopleOptionsLoaded = true
            peopleOptionsError = nil
        } catch {
            if UserFacingError.isCancellation(error) { return }
            peopleOptionsError = error.userFacingMessage
        }
    }

    /// The people whose name contains `query`, ignoring case and accents; the
    /// whole list for a blank query. A nameless person never matches a text.
    static func matchingPeople(_ people: [PersonResponseDto], query: String) -> [PersonResponseDto] {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: options, locale: nil)
        guard !needle.isEmpty else { return people }
        return people.filter { person in
            !person.name.isEmpty && person.name.folding(options: options, locale: nil).contains(needle)
        }
    }

    /// Adds or removes a person; the search runs on Done (`applyFilters()`).
    func togglePerson(_ person: PersonResponseDto) {
        filter.toggle(person: person)
    }

    /// Every tag as an indented row (`TagTree`), read when the picker opens.
    private(set) var tagOptions: [TagRow] = []
    private(set) var tagOptionsError: String?
    private var tagOptionsLoaded = false
    private var isLoadingTagOptions = false

    var tagOptionsState: ListRenderState {
        .resolve(
            isEmpty: tagOptions.isEmpty,
            hasLoaded: tagOptionsLoaded,
            isLoading: isLoadingTagOptions,
            isRefreshing: false,
            loadError: tagOptionsError
        )
    }

    func loadTagOptions() async {
        guard !isLoadingTagOptions else { return }
        isLoadingTagOptions = true
        defer { isLoadingTagOptions = false }
        do {
            tagOptions = TagTree.rows(from: try await client.getAllTags())
            tagOptionsLoaded = true
            tagOptionsError = nil
        } catch {
            if UserFacingError.isCancellation(error) { return }
            tagOptionsError = error.userFacingMessage
        }
    }

    /// Adds or removes a tag by id only: the server includes the descendants
    /// of `Voyages` when it is asked for `Voyages`, so the client adds nothing.
    func toggleTag(_ tag: TagResponseDto) {
        filter.toggle(tag: tag)
    }

    // UI state
    private(set) var isLoading: Bool = false
    private(set) var isRefreshing: Bool = false
    /// Reads in flight; `isLoading` is true while any is, so a superseded read
    /// ending never hides a newer one.
    private var readsInFlight = 0
    private func beginRead() {
        readsInFlight += 1
        isLoading = true
    }
    private func endRead() {
        readsInFlight -= 1
        isLoading = readsInFlight > 0
    }
    var errorMessage: String? = nil

    /// Debounce for live search (queryDidChange). Tests override with `.zero`.
    var debounceInterval: Duration = .milliseconds(400)

    /// Max recent searches kept in memory + persisted.
    private let recentsCapacity = 8

    /// Last query actually dispatched (or "") so programmatic query writes
    /// (searchRecent, clear) don't trigger a second debounced search.
    private var lastQueried = ""
    private var searchTask: Task<Void, Never>?
    /// Bumped on every new search intent; guards stale in-flight responses
    /// from overwriting the idle state after clear/reset.
    private var searchGeneration = 0

    init(
        client: any ImmichClient,
        recents: RecentSearchesStore = RecentSearchesStore(),
        saved: SavedSearchesStore = SavedSearchesStore()
    ) {
        self.client = client
        self.batch = TimelineViewModel(client: client)
        self.recentsStore = recents
        self.savedStore = saved
        self.recentSearches = recents.load()
        self.savedSearches = saved.load()
    }

    // MARK: - Live search (debounced)

    /// Called by the View on `onChange(of: query)`. Debounces free-text input;
    /// an empty query resets to the idle (suggestions) state instead of
    /// dispatching. Programmatic writes already searched are skipped.
    func queryDidChange() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastQueried else { return }
        searchGeneration += 1
        guard !trimmed.isEmpty else {
            resetToIdle()
            lastQueried = ""
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            // Wait for any in-flight search/loadMore to settle so the fresh
            // query wins instead of being swallowed by the isLoading guard.
            while isLoading && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    // MARK: - Search (AC-401 / AC-401b / AC-402 / AC-405)

    /// Reset + dispatch a fresh search (page=1).
    func search() async {
        guard !isLoading else { return }
        batch.exitSelectionMode()
        searchTask?.cancel()
        let gen = searchGeneration + 1
        searchGeneration = gen
        lastQueried = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A free-text search supersedes any Explore drill-down filter — if the
        // user types after tapping a card, the typed query wins and the EXIF
        // field filter is cleared. (`searchByExplore` calls `search()` with an
        // empty query but pre-sets the filter, so we only clear when there is
        // actual free-text to run.)
        if !lastQueried.isEmpty { pendingExploreFilter = nil }
        reevaluateMode(typed: lastQueried)
        beginRead()
        defer { endRead() }

        // Reset pagination state (AC-404b: not accumulated).
        results = []
        loadedIds = []
        currentPage = 1
        nextPage = nil
        nextCursor = nil
        errorMessage = nil
        lastFailureWasLoadMore = false
        hasSearched = true

        do {
            let resp = try await dispatchSearch(page: 1)
            // A superseded search (newer keystroke / clear / city tap bumped the
            // generation) must never overwrite the fresher state. We don't check
            // `Task.isCancelled` here because `search()` runs inside the very
            // `searchTask` it cancels on line above — that self-cancel is benign
            // (it only clears the debounce sleep) and must not short-circuit a
            // successful response. Cancellation from a *newer* search is caught
            // by the generation guard.
            guard gen == searchGeneration else { return }
            applyResponse(resp)
            recordRecentSearch()
        } catch {
            // Cancellation is a normal outcome of debounced live search
            // (rapid typing cancels the in-flight request). Never surface it.
            if UserFacingError.isCancellation(error) { return }
            guard gen == searchGeneration else { return }
            errorMessage = error.userFacingMessage
        }
    }

    /// AC-406 / AC-406b / AC-406c: load next page when canLoadMore.
    func loadMore() async {
        guard !isLoading, canLoadMore else { return }
        let gen = searchGeneration
        beginRead()
        defer { endRead() }

        let nextPageNumber = currentPage + 1
        do {
            let resp = try await dispatchSearch(page: nextPageNumber)
            // Only apply if no newer search superseded this pagination.
            guard gen == searchGeneration else { return }
            currentPage = nextPageNumber
            applyResponse(resp, append: true)
            errorMessage = nil
            lastFailureWasLoadMore = false
        } catch {
            if UserFacingError.isCancellation(error) { return }
            guard gen == searchGeneration else { return }
            errorMessage = error.userFacingMessage
            lastFailureWasLoadMore = true
        }
    }

    /// Read without pull (S-7): re-runs the current search — same text, mode,
    /// filters and OCR toggle — from page 1. `results` stay on screen until the
    /// answer replaces them; a failure keeps them and sets `errorMessage`.
    /// Never touches `isRefreshing`, never swallowed by an in-flight read.
    func replaySearch() async {
        guard hasSearched else { return }
        batch.exitSelectionMode()
        let gen = searchGeneration + 1
        searchGeneration = gen
        beginRead()
        defer { endRead() }

        do {
            let resp = try await dispatchSearch(page: 1)
            guard gen == searchGeneration else { return }
            loadedIds = []
            currentPage = 1
            applyResponse(resp)
            errorMessage = nil
            lastFailureWasLoadMore = false
        } catch {
            if UserFacingError.isCancellation(error) { return }
            guard gen == searchGeneration else { return }
            errorMessage = error.userFacingMessage
            lastFailureWasLoadMore = false
        }
    }

    /// Pull-to-refresh (S-3): `replaySearch()` with `isRefreshing` raised.
    /// Nothing to refresh before the first search.
    func refreshResults() async {
        guard hasSearched else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await replaySearch()
    }

    /// Both "Try Again" buttons: the page that failed, or the whole search.
    func retryResults() async {
        if lastFailureWasLoadMore {
            await loadMore()
        } else {
            await replaySearch()
        }
    }

    /// Clears results back to the idle state (empty query path). The filters —
    /// and with them the rating — are **not** touched: emptying the query is not
    /// erasing the filters, `clearFilters()` is the only way out.
    func clearSearch() {
        query = ""
        searchTask?.cancel()
        searchGeneration += 1
        resetToIdle()
        lastQueried = ""
    }

    /// Sets (or clears) the star-rating filter and re-runs the search. Smart
    /// carries the rating as a flat field, so a typed text stays Smart; with no
    /// text, `search()` moves to Metadata on its own.
    func setRatingFilter(_ value: Int?) async {
        ratingFilter = value
        await restartSearch()
    }

    /// Done in the Filters sheet: run the filter as it now stands. An Explore
    /// drill-down is cancelled — a filter typed into the sheet is the more
    /// specific intent — and the search is dispatched directly: the 400 ms
    /// debounce of `queryDidChange()` would only delay what the user just
    /// confirmed. A search already in flight is superseded, not skipped.
    func applyFilters() async {
        pendingExploreFilter = nil
        await restartSearch()
    }

    /// Reset, from the sheet or the chips bar: back to `SearchFilter()`, then
    /// the same dispatch path. The query is **not** touched — only the
    /// constraints go; the file name / description text mode is one of them
    /// (the bar shows it as a chip), so the mode returns to Smart and the text
    /// stays.
    ///
    /// An Explore drill-down goes with them: it is a constraint the chips bar
    /// cannot show, so leaving it behind would contradict a bar that just
    /// emptied.
    func clearFilters() async {
        let hadTextMode = textModeConstraint != nil
        filter = SearchFilter()
        pendingExploreFilter = nil
        if hadTextMode {
            searchMode = .smart
            metadataIsAutomatic = false
        }
        await restartSearch()
    }

    /// Drops one chip and re-runs the search. The text-mode chips (file name,
    /// description) return to Smart and keep the text; any other chip clears
    /// its constraint.
    func removeConstraint(_ field: SearchFilter.Field) async {
        switch field {
        case .originalFileName, .description:
            searchMode = .smart
            metadataIsAutomatic = false
            await restartSearch()
        default:
            filter.clear(field)
            await applyFilters()
        }
    }

    /// Menu choice of how the typed text is read. Changing it with a text
    /// re-runs the search; without one, nothing is sent.
    func selectSearchMode(_ mode: SearchMode) async {
        guard mode != searchMode else { return }
        searchMode = mode
        metadataIsAutomatic = false
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await restartSearch()
        }
    }

    /// Re-runs the search from the current state even while a read is in
    /// flight (`search()` alone returns when `isLoading`). The generation bump
    /// makes the running read drop its answer; once it has finished, a fresh
    /// search reads the state as it is *then*. A newer restart, keystroke or
    /// search that takes over while we wait already carries the current state:
    /// we step aside.
    private func restartSearch() async {
        searchTask?.cancel()
        searchGeneration += 1
        let token = searchGeneration
        while isLoading {
            try? await Task.sleep(for: .milliseconds(50))
            if token != searchGeneration { return }
        }
        await search()
    }

    /// Moves between Smart and Metadata where the typed text and the criteria
    /// call for it, as long as the user has not picked a mode in the menu.
    ///
    /// Smart carries every criterion but the detected-text one, so Metadata is
    /// taken for an OCR criterion, and for an empty text (Smart needs a query).
    /// A Metadata that was taken automatically goes back to Smart as soon as a
    /// text is typed — unless a detected-text criterion is still active.
    private func reevaluateMode(typed: String) {
        let ocrCriterion = !(filter.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if searchMode == .smart, ocrCriterion || typed.isEmpty {
            searchMode = .metadata
            metadataIsAutomatic = true
        } else if searchMode == .metadata, metadataIsAutomatic,
                  !typed.isEmpty, !ocrCriterion, !ocrFilterEnabled {
            searchMode = .smart
            metadataIsAutomatic = false
        }
    }

    /// Recent-search chip tap: write the term into the field, then search
    /// immediately (the subsequent onChange is deduped via `lastQueried`).
    func searchRecent(_ term: String) async {
        searchTask?.cancel()
        query = term
        await search()
    }

    // MARK: - Saved searches (gap #11, local persistence)

    /// Saves the current free-text query under a name. No-op for an empty
    /// query or duplicate name (updates the existing entry instead).
    func saveCurrentSearch(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedQuery.isEmpty else { return }
        var saved = savedSearches
        saved.removeAll { $0.name == trimmedName || $0.id == trimmedName }
        saved.insert(SavedSearch(id: UUID().uuidString, name: trimmedName, query: trimmedQuery), at: 0)
        savedSearches = saved
        savedStore.save(saved)
    }

    func deleteSavedSearch(id: String) {
        savedSearches.removeAll { $0.id == id }
        savedStore.save(savedSearches)
    }

    /// Saved-search tap: write its query into the field, then search.
    func searchSaved(_ saved: SavedSearch) async {
        searchTask?.cancel()
        query = saved.query
        await search()
    }

    private func resetToIdle() {
        batch.exitSelectionMode()
        results = []
        loadedIds = []
        currentPage = 1
        nextPage = nil
        nextCursor = nil
        errorMessage = nil
        lastFailureWasLoadMore = false
        hasSearched = false
    }

    private func recordRecentSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pendingExploreFilter == nil, !results.isEmpty else { return }
        var recents = recentSearches
        recents.removeAll { $0 == trimmed }
        recents.insert(trimmed, at: 0)
        recentSearches = Array(recents.prefix(recentsCapacity))
        recentsStore.save(recentSearches)
    }

    /// Builds the right DTO for the current mode + dispatches.
    ///
    /// One writer builds the body of every constraint (`constraintBody`):
    /// the Explore pin, the sheet's `SearchFilter` and the date range, written
    /// the flat way. Smart then copies the flat criteria its route accepts
    /// (`smartShape`, flat on every server version: v3.4.0 has no Smart cursor).
    /// The three metadata modes hand the body to the shape the server speaks —
    /// `structuredShape(cursor:)` from v3.2.0, `flatShape()` anywhere else,
    /// unknown version included. A body never carries both languages: the
    /// server rejects that with a 400.
    ///
    /// Every metadata request asks the server's version (cached after the
    /// first answer): each one carries `visibility`, whose flat and structured
    /// spellings differ, so even free text pays for the probe.
    private func dispatchSearch(page: Int) async throws -> SearchResponseDto {
        var dto = constraintBody(page: page)
        if searchMode == .smart {
            return try await client.searchSmart(dto: dto.smartShape(query: query, page: page))
        }

        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The toolbar toggle reads the query as a detected-text criterion — in
        // Metadata mode only. On a server that has no field for one the toggle
        // changes nothing: emptying the query for a criterion that cannot be
        // sent would turn a search into an unfiltered one.
        let toggleCarriesCriterion = searchMode == .metadata
            && filter.ocrText == nil && ocrFilterEnabled && !typed.isEmpty

        await probeSearchShape()
        let structured = supportsStructuredSearch

        switch searchMode {
        case .metadata:
            // Text is only ever a criterion through the toggle or the OCR field
            // (the server ignores a Metadata `query`, decision #10).
            dto.query = pendingExploreFilter == nil ? query : nil
        case .filename:
            if !typed.isEmpty { dto.originalFileName = typed }
        case .description:
            if !typed.isEmpty { dto.description = typed }
        case .smart:
            break
        }

        // The toolbar's "search by detected text" toggle keeps its meaning:
        // *the typed query is* the criterion, so that route replaces free
        // text. An OCR criterion typed into the sheet is a filter like any
        // other (`filter.apply` already wrote it) and joins the query instead
        // of replacing it.
        if toggleCarriesCriterion, structured {
            dto.query = nil
            dto.filter = SearchFilterDto(ocr: StringSimilarityFilterDto(matches: typed))
        }

        if structured {
            return try await client.searchMetadata(dto: dto.structuredShape(cursor: page > 1 ? nextCursor : nil))
        }
        return try await client.searchMetadata(dto: dto.flatShape())
    }

    /// The flat body of every active constraint — the only writes of the
    /// whole feature into a request body.
    private func constraintBody(page: Int) -> MetadataSearchDto {
        var dto = MetadataSearchDto(page: page)
        if let (field, value) = pendingExploreFilter {
            field.apply(value, to: &dto)
        }
        filter.apply(to: &dto)
        if let after = filter.takenAfter { dto.takenAfter = ISO8601.immichFormatter.string(from: after) }
        if let before = filter.takenBefore { dto.takenBefore = ISO8601.immichFormatter.string(from: before) }
        return dto
    }

    private func applyResponse(_ resp: SearchResponseDto, append: Bool = false) {
        nextPage = resp.assets.nextPage
        nextCursor = resp.assets.nextCursor
        let newItems = resp.assets.items.compactMap { item -> AssetReactItem? in
            // Dedup via loadedIds (AC-406).
            guard !loadedIds.contains(item.id) else { return nil }
            loadedIds.insert(item.id)
            return AssetReactItem(from: item)
        }
        if append {
            results.append(contentsOf: newItems)
        } else {
            results = newItems
        }
    }

    // MARK: - Explore (AC-404a / AC-404c)

    /// Explore is considered stale after this interval; the Search tab is now
    /// persistent, so a once-per-VM fetch would never reflect new uploads.
    private let exploreStaleInterval: TimeInterval = 5 * 60
    private var exploreLoadedAt: Date? = nil
    /// Explore's own read state (S-8): never shared with the search results.
    private(set) var isLoadingExplore = false
    private(set) var isRefreshingExplore = false
    private(set) var exploreLoadError: String? = nil
    private var exploreGeneration = 0

    /// Render state of the Places list (S-1); `hasLoaded` = a first answer arrived.
    var exploreState: ListRenderState {
        .resolve(
            isEmpty: explorePlaces.isEmpty,
            hasLoaded: exploreLoadedAt != nil,
            isLoading: isLoadingExplore,
            isRefreshing: isRefreshingExplore,
            loadError: exploreLoadError
        )
    }
    /// Max concurrent per-city count fetches during enrichment.
    private let exploreCountConcurrency = 6

    /// Loads the Places list if empty or older than `exploreStaleInterval`
    /// (AC-404a). Idempotent within the freshness window so tab-focus
    /// re-entry doesn't spam the server (AC-404c). Pass `force: true` to
    /// bypass the freshness check (used by pull-to-refresh).
    ///
    /// Flow: GET /search/cities → map to ExplorePlace (sorted by most-recent
    /// date desc so the freshest trip lands on top immediately) → fan out
    /// POST /search/statistics per city (concurrency-limited) and update each
    /// place's photoCount as it arrives, re-sorting by count desc.
    func loadExplore(force: Bool = false) async {
        let stale = exploreLoadedAt.map { Date().timeIntervalSince($0) > exploreStaleInterval } ?? true
        guard force || explorePlaces.isEmpty || stale else { return }
        // Latest read wins: a read started while another is in flight
        // supersedes it, and only the latest one writes (S-3).
        exploreGeneration += 1
        let gen = exploreGeneration
        isLoadingExplore = true
        defer { if gen == exploreGeneration { isLoadingExplore = false } }

        do {
            let assets = try await client.getAssetsByCity()
            guard gen == exploreGeneration else { return }
            // Try then write: the cards are replaced only by the answer.
            explorePlaces = Self.buildPlaces(from: assets)
            exploreLoadedAt = Date()
            exploreLoadError = nil
            // The list is read; the per-city counts below only decorate it.
            isLoadingExplore = false
            // Enrich counts concurrently; updates are visible progressively.
            await enrichPlaceCounts()
        } catch {
            // A cancellation changes nothing (S-3).
            if UserFacingError.isCancellation(error) { return }
            guard gen == exploreGeneration else { return }
            exploreLoadError = error.userFacingMessage
        }
    }

    /// Pull-to-refresh: the `refresh()` of S-3 around `loadExplore(force: true)`.
    /// The cards stay on screen until the answer replaces them.
    func refreshExplore() async {
        isRefreshingExplore = true
        defer { isRefreshingExplore = false }
        await loadExplore(force: true)
    }

    /// Maps the raw cities response into deduplicated, date-sorted places.
    /// Static + pure so it's unit-testable without a live client.
    static func buildPlaces(from assets: [AssetResponseDto]) -> [ExplorePlace] {
        var seen = Set<String>()
        let places = assets.compactMap { asset -> ExplorePlace? in
            guard let city = asset.exifInfo?.city?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !city.isEmpty else { return nil }
            guard !seen.contains(city) else { return nil } // dedup by city
            seen.insert(city)
            return ExplorePlace(
                id: city,
                city: city,
                state: asset.exifInfo?.state,
                country: asset.exifInfo?.country,
                date: Self.parseDate(asset.exifInfo?.dateTimeOriginal),
                assetId: asset.id,
                thumbhash: asset.thumbhash,
                photoCount: nil
            )
        }
        // Initial order: most-recent first (counts re-sort once loaded).
        return places.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Parses an Immich ISO-8601 `dateTimeOriginal` string into a Date.
    /// Tolerates fractional seconds; nil if unparseable/absent.
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: raw)
    }

    /// Fans out a statistics request per place (concurrency-limited) and
    /// updates each `photoCount` in place, re-sorting by count desc as the
    /// results arrive so the most-photographed places rise to the top.
    private func enrichPlaceCounts() async {
        let cities = explorePlaces.map(\.city)
        await withTaskGroup(of: (String, Int?).self) { [weak self] group in
            for city in cities {
                group.addTask { [weak self] in
                    guard let self else { return (city, nil) }
                    do {
                        let resp = try await self.client.searchStatistics(
                            dto: SearchStatisticsDto(city: city)
                        )
                        return (city, resp.total)
                    } catch {
                        return (city, nil)
                    }
                }
            }
            // TaskGroup already bounds concurrency at the cooperative pool
            // level; collect results as they complete and apply.
            var counts: [String: Int] = [:]
            for await (city, total) in group {
                if let total { counts[city] = total }
            }
            guard !counts.isEmpty else { return }
            // Update + re-sort: places with a known count first (desc), then
            // unresolved ones keep their date order.
            for i in explorePlaces.indices {
                if let total = counts[explorePlaces[i].city] {
                    explorePlaces[i].photoCount = total
                }
            }
            explorePlaces.sort { lhs, rhs in
                Self.comparePlaces(lhs, rhs)
            }
        }
    }

    /// Ordering: known photo count desc; ties (incl. both-unknown) broken by
    /// most-recent date desc so unresolved places keep a sensible position.
    private static func comparePlaces(_ lhs: ExplorePlace, _ rhs: ExplorePlace) -> Bool {
        switch (lhs.photoCount, rhs.photoCount) {
        case let (l?, r?): return l > r
        case (let l?, nil): return true   // known count ranks above unknown
        case (nil, let r?): return false
        default:
            return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast)
        }
    }

    /// AC-404b (generalized): Explore card tap → switch to Results mode +
    /// metadata search filtered by the card's EXIF field. Clears free-text
    /// `query`, stores the field+value filter, then dispatches (`search()`
    /// resets pagination state). For a city card this matches the legacy
    /// `searchByCity` behavior; for make/model/country/state/lensModel it
    /// now routes to the correct field instead of misusing `city`.
    func searchByExplore(field: ExploreField, value: String) async {
        searchTask?.cancel()
        viewMode = .results
        searchMode = .metadata
        // Not the user's pick: typing after a card returns to Smart (S-5).
        metadataIsAutomatic = true
        pendingExploreFilter = (field, value)
        query = ""
        await search()
    }
}

// MARK: - Selection and batch actions (L-23b)

/// The result grid's multi-selection. The state and the requests are the
/// timeline's (`TimelineViewModel`, kept private as `batch`): the same owner
/// split, the same try-then-mutate discipline, the same routes. This extension
/// only adapts what the grid shows afterwards.
extension SearchViewModel {
    var selectionMode: Bool { batch.selectionMode }
    var selectedIds: Set<String> { batch.selectedIds }

    /// The selected rows in grid order (what a download enqueues).
    var selectedItems: [AssetReactItem] { results.filter { batch.selectedIds.contains($0.id) } }

    /// A refusal of a batch action (server or read-only mode), shown by the view.
    var actionErrorMessage: String? {
        get { batch.actionErrorMessage }
        set { batch.actionErrorMessage = newValue }
    }

    /// Photos of a partner left out of the last batch action.
    var skippedPartnerCount: Int? {
        get { batch.skippedPartnerCount }
        set { batch.skippedPartnerCount = newValue }
    }

    func enterSelectionMode() { batch.enterSelectionMode() }
    func exitSelectionMode() { batch.exitSelectionMode() }
    func toggleSelection(id: String) { batch.toggleSelection(id: id) }

    func ownerScopedSelection(currentUserId: String?) -> (ids: [String], skipped: Int) {
        batch.ownerScopedSelection(currentUserId: currentUserId)
    }

    /// "Unarchive" replaces "Archive" when the grid lists archived photos
    /// (the Archive option is on) or the selection holds only archived rows.
    var selectionOffersUnarchive: Bool { filter.isArchived || batch.selectionOffersUnarchive }

    func favoriteSelected(currentUserId: String?) async {
        await batch.favoriteSelected(currentUserId: currentUserId)
        results = batch.items
        // A grid filtered on favourites (or non-favourites) no longer holds a
        // row whose state just changed.
        if let wanted = filter.isFavorite { results.removeAll { $0.isFavorite != wanted } }
    }

    func deleteSelected(currentUserId: String?) async {
        await batch.deleteSelected(currentUserId: currentUserId)
        results = batch.items
    }

    func archiveSelected(currentUserId: String?) async {
        await batch.archiveSelected(currentUserId: currentUserId)
        results = batch.items
    }

    /// Moves the selection back to the timeline. The grid lists archived
    /// photos only when the Archive option is on: then they leave it.
    func unarchiveSelected() async {
        let ids = batch.selectedIds
        await batch.unarchiveSelected()
        let accepted = !ids.isEmpty && !batch.selectionMode
        results = batch.items
        if accepted && filter.isArchived { results.removeAll { ids.contains($0.id) } }
    }

    func moveSelectedToLockedFolder(currentUserId: String?) async {
        await batch.moveSelectedToLockedFolder(currentUserId: currentUserId)
        results = batch.items
    }

    /// Stacks the selection, then re-reads the results so the new stack shows.
    func stackSelected(currentUserId: String?) async {
        let wasSelecting = batch.selectionMode
        await batch.stackSelected(currentUserId: currentUserId, refreshing: false)
        if wasSelecting && !batch.selectionMode { await replaySearch() }
    }
}
