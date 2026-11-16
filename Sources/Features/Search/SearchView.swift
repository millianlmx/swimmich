import SwiftUI

/// Search tab — Apple-Photos-like search. One screen, no mode switch: what it
/// shows follows what the user did.
///
/// - **Nothing searched yet → Explore**: a "Map" entry, then every place you've
///   photographed, powered by `GET /api/search/cities` (one representative
///   asset per city) + per-place counts from `POST /api/search/statistics`.
///   Tap a card → `searchByExplore(field: .city, value:)` filters results by
///   that city. The search field stays on top: there is no state in which it
///   disappears.
/// - **A search ran → Results**: a LazyVGrid of `AssetThumbnailCell` (corner
///   radius 0 — project convention), under one line that says how the typed
///   text is read (a chip naming the mode, plus detected text in Metadata) and
///   holds the result actions (Save search, Select). The line shows as soon as
///   the field is active, so a mode can be picked before typing. Clearing the
///   field goes back to Explore.
/// - **Map**: clustered MapKit view of all geolocated photos (AC-710), opened
///   from Explore's entry and closed by the bar's back button.
///
/// People, tags and the display options live in the Filters sheet.
struct SearchView: View {
    @PVReduceMotion private var reduceMotion
    @Bindable var vm: SearchViewModel
    @Bindable var mapVM: MapViewModel
    /// The process-wide download queue: a batch download from the selection
    /// goes through it, as from the timeline.
    let downloads: DownloadQueueViewModel
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.openProfile) private var openProfile

    @State private var viewerItem: PhotoViewerItem? // Full-screen photo viewer
    @State private var showSaveSearch = false
    @State private var saveSearchName = ""
    @State private var showFilters = false
    /// The search field is active (focused, or Cancel not yet tapped): the
    /// mode chips show from then on, so a mode can be picked before typing.
    @State private var isSearchPresented = false
    /// Ticks on a touch or a long press that checks a thumbnail (the haptic the timeline gives).
    @State private var lastSelectionTick = 0
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
                    // Leaving the map takes the map photo sheet down (and
                    // clears any marker filter) — the sheet is owned by RootView
                    // and would otherwise stay open over the search. Opening the
                    // map ends a selection of results it hides.
                    if newMode == .map { vm.exitSelectionMode() }
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
                // Under the field: how the text is read and what to do with the
                // results — shown once there is something to read or act on.
                // While selecting, the selection's count takes the line (the
                // navigation title says it too, but iOS drops the title when the
                // seven selection actions fill the bar: this line always shows).
                .safeAreaInset(edge: .top, spacing: 0) {
                    if vm.viewMode == .results {
                        if vm.selectionMode {
                            Text("\(vm.selectedIds.count) selected")
                                .font(.pvSubhead.weight(.semibold))
                                .foregroundStyle(Color.textSecondaryPV)
                                .accessibilityIdentifier("searchSelectionCount")
                                .padding(.vertical, PVSpacing.s8)
                        } else if showsResultsBar {
                            resultsBar
                        }
                    }
                }
                // `verbatim`: the bar intentionally carries no title, and an
                // empty `LocalizedStringKey` would be extracted as a `""` key.
                .navigationTitle(vm.selectionMode ? Text("\(vm.selectedIds.count) selected") : Text(verbatim: ""))
                .navigationBarTitleDisplayMode(.inline)
                // Filters + avatar (topBarTrailing): iOS 26 renders its own
                // Liquid-Glass chrome, so no manual glassEffect — a manual circle
                // on the label would double-glass and clip. Filters only over the
                // search (a filter alone, without text, is a search too); the
                // avatar, which carries the backup ring, always. On the map, a
                // back button returns to the search.
                .toolbar {
                    if vm.viewMode == .map {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                vm.viewMode = .results
                            } label: {
                                Label("Search", systemImage: "chevron.backward")
                            }
                            .accessibilityIdentifier("searchMapClose")
                        }
                    }
                    if !(vm.selectionMode && vm.viewMode == .results) {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if vm.viewMode == .results {
                                filtersButton
                            }
                            ProfileAvatarButton { openProfile() }
                        }
                    }
                }
                // L-23b: the same selection bar as the Photos tab, written once.
                .batchSelectionBar(vm, userId: auth.userId, downloads: downloads, alertsSuspended: viewerItem != nil)
                .appSensoryFeedback(.selection, trigger: lastSelectionTick)
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

    /// The search (Explore until a search ran, then its results) under the
    /// native `.searchable` field, or the full-screen map.
    @ViewBuilder
    private var modeContent: some View {
        switch vm.viewMode {
        case .results:
            searchContent
                .searchable(
                    text: $vm.query,
                    isPresented: $isSearchPresented,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: searchPrompt
                )
                // While the field is active iOS hides the navigation bar's items:
                // the Filters button and the avatar would be out of reach as soon
                // as something is typed.
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

    /// Opens the Filters sheet (search-filters), over the search only — a
    /// filter alone, with no text, is a search too; the map has its own. The
    /// active count rides a circular overlay: `.badge(_:)` exists only inside a
    /// `List` or a tab bar.
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
                    // HIG: a touch target of at least 44 × 44 pt (the glyph alone is 15).
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("searchFilterChipRemove_\(constraint.field.rawValue)")
            .accessibilityLabel("Remove filter")
        }
        // The cross's 44 pt frame closes the capsule on the right.
        .padding(.leading, PVSpacing.s12)
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

    /// The results bar shows from the moment the field is active — a mode can
    /// be picked before typing — and stays while there are results to act on.
    private var showsResultsBar: Bool {
        isSearchPresented || vm.hasSearched || !vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Under the field: how the typed text is read — a chip that names the
    /// current mode and lists the four (Smart (CLIP), Metadata, file name,
    /// description; identifier `searchTextMode_<mode>`, the current one
    /// checked; a pick with a text re-runs the search) — and the two result
    /// actions, "Save search…" and "Select", in plain sight, on one line
    /// (stacked at accessibility sizes). The detected-text toggle, carried by
    /// Metadata alone, takes a second line while that mode is on: its label
    /// and the mode's do not fit beside the actions on a phone.
    private var resultsBar: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s4) {
            resultsBarMainLine
            if vm.searchMode == .metadata {
                ocrFilterToggle
            }
        }
        .padding(.horizontal, PVSpacing.s16)
        .padding(.bottom, PVSpacing.s4)
    }

    private var resultsBarMainLine: some View {
        PVAdaptiveStack(hAlignment: .center, vAlignment: .leading, spacing: PVSpacing.s8) {
            modeMenu
            Spacer(minLength: 0)
            HStack(spacing: PVSpacing.s16) {
                Button {
                    saveSearchName = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    showSaveSearch = true
                } label: {
                    Label("Save search…", systemImage: "bookmark")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("searchSaveButton")
                Button {
                    vm.enterSelectionMode()
                } label: {
                    Text("Select")
                        .frame(minHeight: 44)
                }
                .disabled(vm.results.isEmpty)
                .accessibilityIdentifier("searchSelectButton")
            }
            .font(.pvSubhead.weight(.semibold))
        }
    }

    /// The mode chip: the current mode in words and its glyph — no lone
    /// sparkle to decode — opening the list of the four.
    private var modeMenu: some View {
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
            HStack(spacing: PVSpacing.s4) {
                Image(systemName: modeIcon(vm.searchMode))
                Text(modeTitle(vm.searchMode))
                Image(systemName: "chevron.down")
                    .font(.pvCaption.weight(.semibold))
            }
            .font(.pvSubhead.weight(.semibold))
            .foregroundStyle(Color.textPrimaryPV)
            .padding(.horizontal, PVSpacing.s12)
            .frame(minHeight: 44)
            .background(Color.bgSecondary, in: Capsule())
            .overlay(Capsule().stroke(Color.separatorPV, lineWidth: 1))
            .contentShape(Capsule())
        }
        .accessibilityLabel(Text("Search mode"))
        .accessibilityValue(Text(modeTitle(vm.searchMode)))
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
        case .smart, .metadata: Text("Places, people, things…")
        case .filename: Text("Search by file name")
        case .description: Text("Search descriptions")
        }
    }

    /// Restricts the results to photos whose detected text matches the query
    /// (ocr-text): the chip under the mode, shown while the mode is Metadata —
    /// it changes how the query is interpreted, not which grid is shown. Only a
    /// server with the v3.2.0 structured filter has a field for it: on an older
    /// one the chip stays, disabled, rather than silently searching something
    /// else. A toggle: a check mark and the brand outline when on, and VoiceOver
    /// reads its state as the value.
    private var ocrFilterToggle: some View {
        let isOn = vm.ocrFilterEnabled
        let isUsable = vm.searchMode == .metadata && vm.supportsStructuredSearch
        return Button {
            Task { await vm.setOcrFilterEnabled(!isOn) }
        } label: {
            // Not "Detected text": that is the Filters sheet's field, which sets
            // the text itself — two controls must not read the same.
            Label("Search in detected text", systemImage: isOn ? "checkmark" : "text.viewfinder")
                .font(.pvSubhead.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.immichPrimary : Color.textPrimaryPV)
                .padding(.horizontal, PVSpacing.s12)
                .frame(minHeight: 44)
                .background(Color.bgSecondary, in: Capsule())
                .overlay(Capsule().stroke(isOn ? Color.immichPrimary : Color.separatorPV, lineWidth: 1))
                .contentShape(Capsule())
                .opacity(isUsable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isUsable)
        .accessibilityValue(isOn ? Text("on") : Text("off"))
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

    // MARK: - Content (explore | results grid | loading | error)

    /// Explore until a search ran — the screen is never an empty page that
    /// repeats the field's placeholder — then the results. Clearing the field
    /// (`resetToIdle`) brings Explore back.
    @ViewBuilder
    private var searchContent: some View {
        if !vm.hasSearched {
            exploreView
                .task {
                    // AC-404a / AC-404c: load explore once per VM lifetime.
                    await vm.loadExplore()
                }
        } else {
            resultsContent
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if case .loading = vm.resultsState {
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
                // The chips stay over "No results": a filtered grid that came
                // back empty lets the user drop one criterion at a time.
                VStack(spacing: 0) {
                    if vm.isFilterActive {
                        activeFiltersBar
                            .padding(.horizontal, PVSpacing.s4)
                            .padding(.vertical, PVSpacing.s8)
                    }
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
                }
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
                    lastSelectionTick &+= 1
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
            lastSelectionTick &+= 1
        }
    }

    /// Explore: the map entry, then the places. The map entry shows in every
    /// state (loading, error, empty): the map needs no place list to open.
    @ViewBuilder
    private var exploreView: some View {
        // The first read shows a spinner outside the scroll container; every
        // other state lives in one ScrollView that carries the pull-to-refresh.
        if case .loading = vm.exploreState {
            VStack(spacing: PVSpacing.s24) {
                mapEntry
                ProgressView()
                    .pvLoadingIndicator("exploreLoading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, PVSpacing.s12)
            .padding(.top, PVSpacing.s8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: PVSpacing.s12) {
                    mapEntry
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
                    case .empty:
                        ContentUnavailableView(
                            "No places yet",
                            systemImage: "mappin.and.ellipse",
                            description: Text("Photos with a recognized location will appear here as places you can explore.")
                        )
                        .accessibilityIdentifier("exploreEmptyState")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PVSpacing.s24)
                    case .data(let status):
                        Text("Places")
                            .font(.pvH5)
                            .foregroundStyle(Color.textPrimaryPV)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("explorePlacesHeader")
                            .padding(.top, PVSpacing.s8)
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
                    }
                }
                .padding(.horizontal, PVSpacing.s12)
                .padding(.vertical, PVSpacing.s8)
            }
            .refreshable { await vm.refreshExplore() }
        }
    }

    /// Opens the map of every geolocated photo — what used to be the third
    /// segment of a mode switch, now one entry among the things to explore.
    private var mapEntry: some View {
        Button {
            vm.viewMode = .map
        } label: {
            HStack(spacing: PVSpacing.s12) {
                Image(systemName: "map")
                    .font(.pvH5)
                    .foregroundStyle(Color.immichPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.immichPrimary.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PVSpacing.s2) {
                    Text("Map")
                        .font(.pvHeadline)
                        .foregroundStyle(Color.textPrimaryPV)
                    Text("Your photos on a map")
                        .font(.pvSubhead)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                Spacer(minLength: PVSpacing.s8)
                Image(systemName: "chevron.forward")
                    .font(.pvSubhead.weight(.semibold))
                    .foregroundStyle(Color.textTertiaryPV)
                    .accessibilityHidden(true)
            }
            .padding(PVSpacing.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("searchMapEntry")
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
