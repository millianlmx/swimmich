import SwiftUI

/// Search tab — Apple-Photos-like search with three modes (Results | Explore | Map).
///
/// - **Results**: native `.searchable` field with debounced live search.
///   LazyVGrid of `AssetThumbnailCell` (corner radius 0 — project convention).
///   Tap → `AssetDetailView` (NavigationLink pattern from TimelineView.swift:253).
///   Smart/Metadata mode toggle lives in a toolbar `Menu` (default Smart/CLIP).
/// - **Explore**: a vertical list of every place you've photographed, powered by
///   `GET /api/search/cities` (one representative asset per city) + per-place
///   counts from `POST /api/search/statistics`. Tap a card →
///   `searchByExplore(field: .city, value:)` filters results by that city.
/// - **Map**: clustered MapKit view of all geolocated photos (AC-710).
///
/// People / faces deferred to a future iteration (cahier L136).
struct SearchView: View {
    @Bindable var vm: SearchViewModel
    @Bindable var mapVM: MapViewModel
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.openProfile) private var openProfile
    @Environment(\.openSyncStatus) private var openSyncStatus

    @State private var viewerItem: PhotoViewerItem? // Full-screen photo viewer
    @State private var showSaveSearch = false
    @State private var saveSearchName = ""
    @State private var showFilters = false

    /// Result columns. Fixed at three: the density option the Filters sheet
    /// used to carry is gone (upstream has none), so the grid keeps the columns
    /// it shipped with.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3)

    var body: some View {
        NavigationStack {
            modeContent
                .onChange(of: vm.viewMode) { _, newMode in
                    // Leaving the map segment takes the map photo sheet down
                    // (and clears any marker filter) — the sheet is owned by
                    // RootView and would otherwise stay open over the other
                    // segments.
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
                    // Compact pill centered with guaranteed side margins (never
                    // kisses the screen edges).
                    HStack {
                        Spacer(minLength: PVSpacing.s16)
                        SearchModeGlassBar(mode: $vm.viewMode)
                        Spacer(minLength: PVSpacing.s16)
                    }
                    .padding(.top, PVSpacing.s8)
                    .padding(.bottom, PVSpacing.s4)
                }
                // `verbatim`: the bar intentionally carries no title, and an
                // empty `LocalizedStringKey` would be extracted as a `""` key.
                .navigationTitle(Text(verbatim: ""))
                .navigationBarTitleDisplayMode(.inline)
                // Search-mode menu + sync status + avatar as a nav-bar row
                // (topBarTrailing): iOS 26 renders its own Liquid-Glass chrome,
                // so no manual glassEffect — a manual circle on the label would
                // double-glass and clip. Menu only in results mode; the two
                // pinned buttons are always visible.
                .toolbar {
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
                        }
                        SyncStatusButton { openSyncStatus() }
                        ProfileAvatarButton { openProfile() }
                    }
                }
                // Full-screen photo viewer (tap any result photo → browse/zoom).
                // Favorite/delete run self-sufficient; re-run the search so the
                // results grid reflects mutations after the viewer closes.
                .photoViewer(
                    item: $viewerItem,
                    baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
                    token: auth.accessToken,
                    onDataChanged: {
                        Task { await vm.search() }
                    }
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
                    prompt: "Search photos and places"
                )
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
        viewerItem = PhotoViewerItem(assets: vm.results, index: idx)
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
                            .contentTransition(.numericText())
                            .accessibilityHidden(true)
                    }
                }
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityIdentifier("searchFilterButton")
        .accessibilityLabel("Filters")
        .accessibilityValue(vm.activeFilterCount > 0
            ? Text("\(vm.activeFilterCount) active")
            : Text("No active filters"))
    }

    /// Chip row of the active constraints (search-filters), shown only while
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
                    ForEach(vm.filter.constraints) { constraint in
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
    /// gesture, and the only removal that does not go through the sheet.
    private func removeFilter(_ field: SearchFilter.Field) {
        vm.filter.clear(field)
        Task { await vm.applyFilters() }
    }

    /// Smart (CLIP semantic) vs Metadata (EXIF fields) search — folded into a
    /// compact menu so the Results area stays uncluttered.
    private var searchModeMenu: some View {
        Menu {
            Picker("Search Mode", selection: $vm.searchMode) {
                Label("Smart", systemImage: "sparkles").tag(SearchViewModel.SearchMode.smart)
                Label("Metadata", systemImage: "character.magnify").tag(SearchViewModel.SearchMode.metadata)
            }
        } label: {
            Image(systemName: vm.searchMode == .smart ? "sparkles" : "character.magnify")
                .font(.pvBody.weight(.semibold))
                .foregroundStyle(Color.immichPrimary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Search mode: \(vm.searchMode == .smart ? "Smart" : "Metadata")")
    }

    /// Star-rating filter (star-ratings): mono-valued — "Any rating" or 1…5 —
    /// and only in the results branch, where there is a grid to filter (`Smart`
    /// search has no filter field, so the selection forces Metadata). The tinted
    /// glyph keeps an active filter visible with the menu closed.
    private var ratingFilterMenu: some View {
        Menu {
            Picker("Rating", selection: ratingFilterBinding) {
                Label("Any rating", systemImage: "star").tag(Int?.none)
                ForEach(1...5, id: \.self) { value in
                    Label("\(value) star", systemImage: "star.fill").tag(Int?.some(value))
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
        if vm.isLoading && vm.results.isEmpty && vm.hasSearched {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = vm.errorMessage {
            errorView(msg)
        } else if vm.results.isEmpty {
            if vm.hasSearched {
                ContentUnavailableView {
                    Label("No results", systemImage: "magnifyingglass")
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Search your library",
                    systemImage: "magnifyingglass",
                    description: Text("Find photos by place, object, camera, or natural language.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            resultsGrid
        }
    }

    private var resultsGrid: some View {
        ScrollView {
            // Mirrors the Photos timeline grid: LazyVStack + LazyVGrid with 2pt
            // seams and a 4pt horizontal inset — no count header above the grid.
            LazyVStack(alignment: .leading, spacing: PVSpacing.s2) {
                if vm.isFilterActive {
                    activeFiltersBar
                        .padding(.horizontal, PVSpacing.s4)
                        .padding(.bottom, PVSpacing.s8)
                }
                LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                    ForEach(vm.results) { item in
                        AssetThumbnailCell(
                            asset: item,
                            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
                            token: auth.accessToken,
                            onTap: { openViewer(for: item) }
                        )
                        .buttonStyle(.plain)
                        .onAppear {
                            // AC-406: trigger next page when the last cell appears.
                            if item.id == vm.results.last?.id {
                                Task { await vm.loadMore() }
                            }
                        }
                    }
                }
                .padding(.horizontal, PVSpacing.s4)
                if vm.isLoading {
                    ProgressView()
                        .padding(.vertical, PVSpacing.s12)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var exploreView: some View {
        // Distinguish "loading first page" from "genuinely empty" so the user
        // sees a spinner on first open instead of the empty-state.
        if vm.explorePlaces.isEmpty && !vm.isLoading {
            ContentUnavailableView(
                "No places yet",
                systemImage: "mappin.and.ellipse",
                description: Text("Photos with a recognized location will appear here as places you can explore.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.explorePlaces.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: PVSpacing.s12) {
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
                        .disabled(vm.isLoading)
                    }
                }
                .padding(.horizontal, PVSpacing.s12)
                .padding(.vertical, PVSpacing.s8)
            }
            .refreshable { await vm.refreshExplore() }
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: PVSpacing.s12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.pvTitle)
                .foregroundStyle(Color.immichWarning)
            Text(msg)
                .font(.pvBody)
                .foregroundStyle(Color.textSecondaryPV)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-width hero card for one place: a 3:2 representative photo with a
/// darkened bottom gradient and overlaid flag + city + state/country + photo
/// count + most-recent date. The thumbnail URL is precomputed once (preview
/// size for sharper hero imagery than the grid thumbnail).
private struct ExplorePlaceCard: View {
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
        ZStack(alignment: .bottomLeading) {
            AuthenticatedAsyncImage(url: url, token: token)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipped()

            // Legibility gradient under the text.
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 140)
            .allowsHitTesting(false)

            // Overlaid metadata.
            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                Text(headline)
                    .font(.pvH4)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(radius: 4)
                if !place.subtitle.isEmpty {
                    Text(place.subtitle)
                        .font(.pvSubhead)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Text(footer)
                    .font(.pvCaption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(PVSpacing.s12)
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
    private var footer: String {
        var parts: [String] = []
        if let count = place.photoCount {
            parts.append("\(count) photos")
        } else {
            parts.append("·") // count still loading
        }
        if let date = place.date {
            parts.append(date.formatted(.dateTime.month(.abbreviated).year()))
        }
        return parts.joined(separator: "  ·  ")
    }
}
