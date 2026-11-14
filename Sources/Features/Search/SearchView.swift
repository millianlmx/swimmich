import SwiftUI

/// Search tab — Apple-Photos-like search with three modes (Results | Explore | Map).
///
/// - **Results**: native `.searchable` field with debounced live search.
///   LazyVGrid of `AssetThumbnailCell` (corner radius 0 — project convention).
///   Tap → `AssetDetailView` (NavigationLink pattern from TimelineView.swift:253).
///   The text-mode menu (Smart, Metadata, file name, description) lives in a
///   toolbar `Menu` (default Smart/CLIP).
/// - **Explore**: a vertical list of every place you've photographed, powered by
///   `GET /api/search/cities` (one representative asset per city) + per-place
///   counts from `POST /api/search/statistics`. Tap a card →
///   `searchByExplore(field: .city, value:)` filters results by that city.
/// - **Map**: clustered MapKit view of all geolocated photos (AC-710).
///
/// People, tags and the display options live in the Filters sheet; the file
/// name and description are modes of the search field.
struct SearchView: View {
    @PVReduceMotion private var reduceMotion
    @Bindable var vm: SearchViewModel
    @Bindable var mapVM: MapViewModel
    /// The process-wide download queue: a batch download from the selection
    /// goes through it, as from the timeline.
    let downloads: DownloadQueueViewModel
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.openProfile) private var openProfile
    @Environment(\.openSyncStatus) private var openSyncStatus

    @State private var viewerItem: PhotoViewerItem? // Full-screen photo viewer
    @State private var showSaveSearch = false
    @State private var saveSearchName = ""
    @State private var showFilters = false
    @State private var pendingDeleteSelected = false
    @State private var presentAlbumPicker = false
    /// What the photo viewer needs to grow out of a thumbnail and shrink back
    /// onto it (L-14): the thumbnails' frames and the scroll owed on close.
    @State private var zoomSource = ViewerZoomSource()

    @Environment(AppSettingsStore.self) private var appSettings

    /// Result columns: the density set in Preferences (`tilesPerRow`, 2…7),
    /// the same setting as the Photos grid. Reading it here is the whole
    /// feature: changing it sends no request.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: appSettings.tilesPerRow)
    }

    var body: some View {
        NavigationStack {
            modeContent
                .onChange(of: vm.viewMode) { _, newMode in
                    // Leaving the map segment takes the map photo sheet down
                    // (and clears any marker filter) — the sheet is owned by
                    // RootView and would otherwise stay open over the other
                    // segments.
                    if newMode != .results { vm.exitSelectionMode() }
                    if newMode != .map {
                        mapVM.isPhotoSheetPresented = false
                        mapVM.deselectMarker()
                    }
                }
                // The Filters sheet hangs off the mode content (inside this
                // NavigationStack, never on the stack itself) — it edits the
                // constraints of the grid it is shown over.
                .sheet(isPresented: $showFilters) {
                    SearchFilterSheet(vm: vm)
                }
                // Floating Liquid-Glass segmented control over all three modes.
                // The map ignores the safe area and extends *under* this pill
                // (Apple Maps-style); Résultats/Explorer content sits below it.
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: PVSpacing.s4) {
                        // Compact pill centered with guaranteed side margins (never
                        // kisses the screen edges).
                        HStack {
                            Spacer(minLength: PVSpacing.s16)
                            SearchModeGlassBar(mode: $vm.viewMode)
                            Spacer(minLength: PVSpacing.s16)
                        }
                        // The selection's count. The navigation title says it too,
                        // but iOS drops the title when the selection actions fill
                        // the bar: this line is the one that always shows.
                        if vm.selectionMode && vm.viewMode == .results {
                            Text("\(vm.selectedIds.count) selected")
                                .font(.pvSubhead.weight(.semibold))
                                .foregroundStyle(Color.textSecondaryPV)
                                .accessibilityIdentifier("searchSelectionCount")
                        }
                    }
                    .padding(.top, PVSpacing.s8)
                    .padding(.bottom, PVSpacing.s4)
                }
                // `verbatim`: the bar intentionally carries no title, and an
                // empty `LocalizedStringKey` would be extracted as a `""` key.
                .navigationTitle(vm.selectionMode ? Text("\(vm.selectedIds.count) selected") : Text(verbatim: ""))
                .navigationBarTitleDisplayMode(.inline)
                // Search-mode menu + sync status + avatar as a nav-bar row
                // (topBarTrailing): iOS 26 renders its own Liquid-Glass chrome,
                // so no manual glassEffect — a manual circle on the label would
                // double-glass and clip. Menu only in results mode; the two
                // pinned buttons are always visible.
                .toolbar {
                    if vm.selectionMode && vm.viewMode == .results {
                        SearchSelectionToolbar(
                            vm: vm,
                            userId: auth.userId,
                            onConfirmDelete: { pendingDeleteSelected = true },
                            onAddToAlbum: { presentAlbumPicker = true },
                            onDownload: {
                                Task {
                                    await downloads.enqueue(assets: vm.selectedItems)
                                    vm.exitSelectionMode()
                                }
                            }
                        )
                    }
                    if !(vm.selectionMode && vm.viewMode == .results) {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if vm.viewMode == .results {
                                ratingFilterMenu
                                filtersButton
                                searchModeMenu
                                ocrFilterToggle
                                Button {
                                    saveSearchName = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
                                    showSaveSearch = true
                                } label: {
                                    Image(systemName: "bookmark")
                                }
                                .disabled(vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityLabel("Save search")
                                .accessibilityIdentifier("searchSaveButton")
                            }
                            SyncStatusButton { openSyncStatus() }
                            ProfileAvatarButton { openProfile() }
                        }
                    }
                }
                .modifier(SearchSelectionPresentations(
                    vm: vm,
                    userId: auth.userId,
                    pendingDelete: $pendingDeleteSelected,
                    presentAlbumPicker: $presentAlbumPicker
                ))
                // Full-screen photo viewer (tap any result photo → browse/zoom).
                // Favorite/delete run self-sufficient; re-run the search so the
                // results grid reflects mutations after the viewer closes.
                .onAppear {
                    zoomSource.orderedIDs = { [vm = self.vm] in vm.results.map(\.id) }
                }
                .photoViewer(
                    item: $viewerItem,
                    baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
                    token: auth.accessToken,
                    onDataChanged: {
                        Task { await vm.search() }
                    },
                    zoomSource: zoomSource
                )
                .alert("Save Search", isPresented: $showSaveSearch) {
                    TextField("Name", text: $saveSearchName)
                        .textInputAutocapitalization(.words)
                    Button("Cancel", role: .cancel) {}
                    Button("Save") {
                        vm.saveCurrentSearch(name: saveSearchName)
                    }
                } message: {
                    Text("Save the current search for quick access.")
                }
        }
    }

    /// The active mode's content. Results keeps the native `.searchable` field;
    /// Explore loads its curated suggestions once; Map is full-screen.
    @ViewBuilder
    private var modeContent: some View {
        switch vm.viewMode {
        case .results:
            resultsContent
                .searchable(
                    text: $vm.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: searchPrompt
                )
                // While the field is active iOS hides the navigation bar's items:
                // the Filters button and the text-mode menu would be out of reach
                // as soon as something is typed.
                .searchPresentationToolbarBehavior(.avoidHidingContent)
                .onChange(of: vm.query) { _, _ in vm.queryDidChange() }
                .searchSuggestions { searchSuggestions }
                .task {
                    // What the server can express decides whether the detected-
                    // text toggle and the Filters sheet's OCR section are on
                    // offer, so the question is asked when the screen appears —
                    // once per session (the ViewModel caches the answer).
                    await vm.probeSearchShape()
                }
        case .explore:
            exploreView
                .task {
                    // AC-404a / AC-404c: load explore once per VM lifetime.
                    await vm.loadExplore()
                }
        case .map:
            MapSegmentView(vm: mapVM)
        }
    }

    /// Opens the Photos-style viewer at `item`, paging through search results.
    private func openViewer(for item: AssetReactItem) {
        guard let idx = vm.results.firstIndex(where: { $0.id == item.id }) else { return }
        zoomSource.presentInstantly {
            viewerItem = PhotoViewerItem(assets: vm.results, index: idx)
        }
    }

    // MARK: - Shared chrome

    /// Opens the Filters sheet (search-filters). It sits with the mode menu —
    /// the filter applies to whatever the mode shows — and only in results mode,
    /// where there is a grid to filter. The active count rides a circular
    /// overlay: `.badge(_:)` exists only inside a `List` or a tab bar.
    private var filtersButton: some View {
        Button {
            showFilters = true
        } label: {
            Image(systemName: vm.isFilterActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .font(.pvBody.weight(.semibold))
                .foregroundStyle(Color.immichPrimary)
                .frame(minWidth: 44, minHeight: 44)
                .overlay(alignment: .topTrailing) {
                    if vm.activeFilterCount > 0 {
                        Text("\(vm.activeFilterCount)")
                            .font(.pvCaption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, PVSpacing.s4)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Color.immichPrimary, in: Capsule())
                            .contentTransition(PVMotion.contentChange(.numericText(), reduceMotion: reduceMotion))
                            .accessibilityHidden(true)
                    }
                }
                .contentTransition(PVMotion.contentChange(.symbolEffect(.replace), reduceMotion: reduceMotion))
        }
        .accessibilityIdentifier("searchFilterButton")
        .accessibilityLabel("Filters")
        .accessibilityValue(vm.activeFilterCount > 0
            ? Text("\(vm.activeFilterCount) active")
            : Text("No active filters"))
    }

    /// Chip row of the active criteria (search-filters) — the sheet's
    /// constraints and the file name / description text mode — shown only while
    /// `vm.isFilterActive`. It is the first thing inside the results
    /// `ScrollView`: it scrolls away with the thumbnails and, being content
    /// rather than floating chrome, borrows no glass surface.
    ///
    /// `searchActiveFiltersBar` sits on the `Text("Filters")` label, never on
    /// the horizontal `ScrollView`: an identifier on a container propagates to
    /// its children and erases theirs (`languageRelaunchToast`, measured).
    private var activeFiltersBar: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            HStack(spacing: PVSpacing.s8) {
                Text("Filters")
                    .font(.pvSubhead.weight(.semibold))
                    .foregroundStyle(Color.textSecondaryPV)
                    .accessibilityIdentifier("searchActiveFiltersBar")
                Spacer(minLength: PVSpacing.s8)
                Button("Clear") {
                    Task { await vm.clearFilters() }
                }
                .font(.pvSubhead)
                .accessibilityIdentifier("searchActiveFiltersClear")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PVSpacing.s8) {
                    ForEach(vm.activeConstraints) { constraint in
                        filterChip(constraint)
                    }
                }
                .padding(.vertical, PVSpacing.s2)
            }
        }
    }

    /// One constraint: the label removes it, and so does its cross — the two
    /// targets are separate buttons so each keeps its own identifier (a nested
    /// button would swallow the inner one's taps).
    private func filterChip(_ constraint: SearchFilter.Constraint) -> some View {
        HStack(spacing: PVSpacing.s4) {
            Button {
                removeFilter(constraint.field)
            } label: {
                Text(verbatim: constraint.label)
                    .font(.pvSubhead)
                    .foregroundStyle(Color.textPrimaryPV)
                    .padding(.vertical, PVSpacing.s8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("searchFilterChip_\(constraint.field.rawValue)")
            .accessibilityHint("Removes this filter")

            Button {
                removeFilter(constraint.field)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("searchFilterChipRemove_\(constraint.field.rawValue)")
            .accessibilityLabel("Remove filter")
        }
        .padding(.horizontal, PVSpacing.s12)
        .frame(minHeight: PVSpacing.s32)
        .background(Color.bgSecondary, in: Capsule())
        .overlay(Capsule().stroke(Color.separatorPV, lineWidth: 1))
    }

    /// Drops exactly one constraint and re-runs the search: the chip's whole
    /// gesture, and the only removal that does not go through the sheet. The
    /// file name / description chips go back to Smart and keep the text.
    private func removeFilter(_ field: SearchFilter.Field) {
        Task { await vm.removeConstraint(field) }
    }

    /// How the typed text is read — Smart (CLIP), Metadata, file name or
    /// description — folded into a compact menu so the Results area stays
    /// uncluttered. Each mode is its own button (identifier
    /// `searchTextMode_<mode>`), the current one checked; a pick with a text
    /// re-runs the search.
    @ViewBuilder
    private var searchModeMenu: some View {
        Menu {
            ForEach(SearchViewModel.SearchMode.allCases, id: \.self) { mode in
                Button {
                    Task { await vm.selectSearchMode(mode) }
                } label: {
                    if mode == vm.searchMode {
                        Label(modeTitle(mode), systemImage: "checkmark")
                    } else {
                        Text(modeTitle(mode))
                    }
                }
                .accessibilityIdentifier("searchTextMode_\(mode.rawValue)")
            }
        } label: {
            Image(systemName: modeIcon(vm.searchMode))
                .font(.pvBody.weight(.semibold))
                .foregroundStyle(Color.immichPrimary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(Text("Search mode: \(modeTitle(vm.searchMode))"))
        .accessibilityIdentifier("searchModeMenu")
    }

    private func modeTitle(_ mode: SearchViewModel.SearchMode) -> String {
        switch mode {
        case .smart: String(localized: "Smart")
        case .metadata: String(localized: "Metadata")
        case .filename: String(localized: "File name")
        case .description: String(localized: "Description")
        }
    }

    private func modeIcon(_ mode: SearchViewModel.SearchMode) -> String {
        switch mode {
        case .smart: "sparkles"
        case .metadata: "character.magnify"
        case .filename: "doc.text"
        case .description: "text.alignleft"
        }
    }

    /// The search field's invite follows the mode.
    private var searchPrompt: Text {
        switch vm.searchMode {
        case .smart, .metadata: Text("Search photos and places")
        case .filename: Text("Search by file name")
        case .description: Text("Search descriptions")
        }
    }

    /// Star-rating filter (star-ratings): mono-valued — "Any rating" or 1…5 —
    /// and only in the results branch, where there is a grid to filter (Smart
    /// carries the rating too; with no text the view model moves to Metadata).
    /// The tinted
    /// glyph keeps an active filter visible with the menu closed.
    private var ratingFilterMenu: some View {
        Menu {
            Picker("Rating", selection: ratingFilterBinding) {
                Label("Any rating", systemImage: "star").tag(Int?.none)
                ForEach(1...5, id: \.self) { value in
                    Label("\(value) stars", systemImage: "star.fill").tag(Int?.some(value))
                }
            }
        } label: {
            Image(systemName: vm.ratingFilter == nil ? "star" : "star.fill")
                .font(.pvBody.weight(.semibold))
                .foregroundStyle(Color.immichPrimary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("searchRatingFilterMenu")
        .accessibilityLabel(vm.ratingFilter.map { Text("Rating filter: \($0) stars") } ?? Text("Rating filter: any rating"))
    }

    /// `Picker` needs an explicit `Binding<Int?>`: with a plain `Int` selection
    /// `nil` and `0` would be indistinguishable, and `0` is not a rating the
    /// server accepts. Selecting writes the value first (so the tinted glyph
    /// updates immediately) and lets the ViewModel own the request.
    private var ratingFilterBinding: Binding<Int?> {
        Binding(
            get: { vm.ratingFilter },
            set: { newValue in
                vm.ratingFilter = newValue
                Task { await vm.setRatingFilter(newValue) }
            }
        )
    }

    /// Restricts the results to photos whose detected text matches the query
    /// (ocr-text). Sits with the mode menu — it changes how the query is
    /// interpreted, not which grid is shown. Only the metadata route carries
    /// the criterion, and only a server with the v3.2.0 structured filter has a
    /// field for it: on an older one the toggle is off the table rather than
    /// silently searching something else.
    private var ocrFilterToggle: some View {
        Button {
            vm.ocrFilterEnabled.toggle()
            vm.queryDidChange()
        } label: {
            Image(systemName: "text.viewfinder")
                .font(.pvBody.weight(.semibold))
                .foregroundStyle(vm.ocrFilterEnabled ? Color.immichPrimary : Color.secondary)
        }
        .disabled(vm.searchMode != .metadata || !vm.supportsStructuredSearch)
        .accessibilityLabel("Search by detected text")
        .accessibilityValue(vm.ocrFilterEnabled ? "on" : "off")
        .accessibilityIdentifier("searchOcrFilterToggle")
    }

    @ViewBuilder
    private var searchSuggestions: some View {
        if vm.query.isEmpty {
            if !vm.savedSearches.isEmpty {
                Section("Saved") {
                    ForEach(vm.savedSearches) { saved in
                        Button {
                            Task { await vm.searchSaved(saved) }
                        } label: {
                            Label(saved.name, systemImage: "bookmark")
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                vm.deleteSavedSearch(id: saved.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            if !vm.recentSearches.isEmpty {
                Section("Recent") {
                    ForEach(vm.recentSearches, id: \.self) { term in
                        Button {
                            Task { await vm.searchRecent(term) }
                        } label: {
                            Label(term, systemImage: "clock")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Content (results grid | explore cards | map | loading | error)

    @ViewBuilder
    private var resultsContent: some View {
        if !vm.hasSearched {
            // No search done: nothing to refresh, so no `.refreshable` here.
            ContentUnavailableView {
                Label {
                    Text("Search your library")
                        .accessibilityIdentifier("searchPromptTitle")
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
            } description: {
                Text("Find photos by place, object, camera, or natural language.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .loading = vm.resultsState {
            ProgressView()
                .pvLoadingIndicator("searchLoading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            resultsScroll
        }
    }

    /// One scroll container for the error, "No results" and the grid, so the
    /// pull-to-refresh task is never torn down by a state change.
    private var resultsScroll: some View {
        ScrollViewReader { proxy in
        ScrollView {
            switch vm.resultsState {
            case .loading:
                EmptyView()
            case .error(let message):
                PVErrorStateView(
                    title: "Couldn't load results",
                    message: message,
                    identifierPrefix: "search",
                    retry: { Task { await vm.retryResults() } }
                )
                .frame(maxWidth: .infinity)
                .padding(PVSpacing.s24)
                .containerRelativeFrame(.vertical)
            case .empty:
                ContentUnavailableView {
                    Label("No results", systemImage: "magnifyingglass")
                        .accessibilityIdentifier("searchEmptyState")
                } description: {
                    Text("Try a different search term.")
                } actions: {
                    // A filtered grid that came back empty must offer the way
                    // out without opening the sheet again.
                    if vm.isFilterActive {
                        Button("Reset filters") {
                            Task { await vm.clearFilters() }
                        }
                        .accessibilityIdentifier("searchNoResultsReset")
                    }
                }
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
            case .data(let status):
                resultsGridContent(status)
            }
        }
        .refreshable { await vm.refreshResults() }
        .viewerZoomViewport(zoomSource)
        .viewerZoomReveal(zoomSource, proxy: proxy)
        }
    }

    private func resultsGridContent(_ status: DataStatus) -> some View {
        // Mirrors the Photos timeline grid: LazyVStack + LazyVGrid with 2pt
        // seams and a 4pt horizontal inset — no count header above the grid.
        LazyVStack(alignment: .leading, spacing: PVSpacing.s2) {
            if case .failed(let message) = status {
                InlineErrorBadge(message: message, retry: { Task { await vm.retryResults() } })
                    .padding(.horizontal, PVSpacing.s4)
                    .accessibilityIdentifier("searchRefreshError")
            }
            if !vm.selectionMode && !vm.results.isEmpty {
                // Explicit entry point of the multi-selection; a long press on a
                // thumbnail enters it too.
                HStack {
                    Spacer()
                    Button("Select") { vm.enterSelectionMode() }
                        .font(.pvSubhead.weight(.semibold))
                        .accessibilityIdentifier("searchSelectButton")
                }
                .padding(.horizontal, PVSpacing.s8)
            }
            if vm.isFilterActive {
                activeFiltersBar
                    .padding(.horizontal, PVSpacing.s4)
                    .padding(.bottom, PVSpacing.s8)
            }
            LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                ForEach(vm.results) { item in
                    resultCell(item)
                        .viewerZoomTile(id: item.id, source: zoomSource)
                        .id(item.id)
                        .onAppear {
                            // AC-406: trigger next page when the last cell appears.
                            // A failed page waits for its "Try Again" instead of
                            // looping on the cell that is still on screen.
                            if item.id == vm.results.last?.id, vm.errorMessage == nil {
                                Task { await vm.loadMore() }
                            }
                        }
                }
            }
            .padding(.horizontal, PVSpacing.s4)
            // A new search builds a new grid: a cell kept from the previous
            // results (the same photo found again) would not appear again, and
            // the last one's `onAppear` is what asks for the next page.
            .id(vm.searchGeneration)
            if status == .reloading {
                ProgressView()
                    .pvLoadingIndicator("searchLoading")
                    .padding(.vertical, PVSpacing.s12)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// One result: a tap opens the viewer — or, while selecting, checks and
    /// unchecks the photo. A long press enters the selection (and checks) or,
    /// while selecting, toggles, as on the timeline.
    private func resultCell(_ item: AssetReactItem) -> some View {
        AssetThumbnailCell(
            asset: item,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken,
            isCompact: appSettings.tilesPerRow >= 6,
            selectionMode: vm.selectionMode,
            isSelected: vm.selectedIds.contains(item.id),
            onTap: {
                if vm.selectionMode {
                    vm.toggleSelection(id: item.id)
                } else {
                    openViewer(for: item)
                }
            },
            // No context menu: its long press would win over the one that
            // starts the selection (AC-216), and its actions are not wired here.
            contextMenuEnabled: false
        )
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.4) {
            if !vm.selectionMode { vm.enterSelectionMode() }
            vm.toggleSelection(id: item.id)
        }
    }

    @ViewBuilder
    private var exploreView: some View {
        // The first read shows a spinner outside the scroll container; every
        // other state lives in one ScrollView that carries the pull-to-refresh.
        if case .loading = vm.exploreState {
            ProgressView()
                .pvLoadingIndicator("exploreLoading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                switch vm.exploreState {
                case .loading:
                    EmptyView()
                case .error(let message):
                    PVErrorStateView(
                        title: "Couldn't load places",
                        message: message,
                        identifierPrefix: "explore",
                        retry: { Task { await vm.loadExplore(force: true) } }
                    )
                    .frame(maxWidth: .infinity)
                    .padding(PVSpacing.s24)
                    .containerRelativeFrame(.vertical)
                case .empty:
                    ContentUnavailableView(
                        "No places yet",
                        systemImage: "mappin.and.ellipse",
                        description: Text("Photos with a recognized location will appear here as places you can explore.")
                    )
                    .accessibilityIdentifier("exploreEmptyState")
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical)
                case .data(let status):
                    LazyVStack(spacing: PVSpacing.s12) {
                        switch status {
                        case .idle:
                            EmptyView()
                        case .reloading:
                            ProgressView()
                                .pvLoadingIndicator("exploreLoading")
                        case .failed(let message):
                            InlineErrorBadge(message: message, retry: { Task { await vm.loadExplore(force: true) } })
                                .accessibilityIdentifier("exploreRefreshError")
                        }
                        ForEach(vm.explorePlaces) { place in
                            Button {
                                Task { await vm.searchByExplore(field: .city, value: place.city) }
                            } label: {
                                ExplorePlaceCard(
                                    place: place,
                                    baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
                                    token: auth.accessToken
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.isLoadingExplore)
                            .accessibilityIdentifier("explorePlaceCard_\(place.city)")
                        }
                    }
                    .padding(.horizontal, PVSpacing.s12)
                    .padding(.vertical, PVSpacing.s8)
                }
            }
            .refreshable { await vm.refreshExplore() }
        }
    }
}

/// Full-width hero card for one place: a 3:2 representative photo with a
/// darkened bottom gradient and overlaid flag + city + state/country + photo
/// count + most-recent date. The thumbnail URL is precomputed once (preview
/// size for sharper hero imagery than the grid thumbnail).
struct ExplorePlaceCard: View {
    let place: ExplorePlace
    let baseURL: URL
    let token: String?

    private let url: URL

    init(place: ExplorePlace, baseURL: URL, token: String?) {
        self.place = place
        self.baseURL = baseURL
        self.token = token
        self.url = ImmichAssetURL.thumbnail(
            assetId: place.assetId, thumbhash: place.thumbhash ?? "", baseURL: baseURL, size: .preview
        )
    }

    var body: some View {
        // Overlaid metadata: it sets the card height (at least 220 pt) and the
        // photo fills whatever height that gives.
        VStack(alignment: .leading, spacing: PVSpacing.s2) {
            Text(headline)
                .font(.pvH4)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(radius: 4)
            if !place.subtitle.isEmpty {
                Text(place.subtitle)
                    .font(.pvSubhead)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.footerText(photoCount: place.photoCount, date: place.date))
                .font(.pvCaption)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PVSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Legibility gradient under the text.
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(minHeight: 140)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .bottomLeading)
        .background {
            AuthenticatedAsyncImage(url: url, token: token)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
        .pvFloatingShadow()
        .contentShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
    }

    /// "🇫🇷 Paris" or just "Paris" when no flag resolved.
    private var headline: String {
        if let flag = place.flag { return "\(flag) \(place.city)" }
        return place.city
    }

    /// "247 photos  ·  Jul 2024" — count shows a placeholder dash while loading.
    /// The count is a catalog plural ("1 photo" / "2 photos"). Pure, so each
    /// shipped language is testable.
    static func footerText(photoCount: Int?, date: Date?, bundle: Bundle = .main, locale: Locale = .current) -> String {
        var parts: [String] = []
        if let count = photoCount {
            parts.append(String(localized: "\(count) photos", bundle: bundle, locale: locale))
        } else {
            parts.append("·") // count still loading
        }
        if let date {
            parts.append(date.formatted(.dateTime.month(.abbreviated).year()))
        }
        return parts.joined(separator: "  ·  ")
    }
}
