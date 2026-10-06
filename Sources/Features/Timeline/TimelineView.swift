import SwiftUI

/// Main photo-grid timeline — Apple-Photos-grade premium experience.
///
/// Visual layers (AC-V01..V07):
/// - Large "Photos" title (collapsing); selection overrides to "X selected".
/// - SF Symbol toolbar (xmark cancel; selection-mode favorite/delete/add-to-album).
/// - Photos-style pinch-to-zoom grid (2-7 columns) via `TimelineGridZoom`.
/// - Skeleton shimmer grid for loading (4×3 initial, 1×3 load-more).
/// - `ContentUnavailableView` empty + error states.
/// - Human-relative date headers via `DateHeaderFormatter`.
/// - Spring-animated selection mode w/ pro cell treatment (scale, tint, symbol morph).
/// - Pull-to-refresh, scroll-to-top, pinned headers, sensoryFeedback.
struct TimelineView: View {
    @Environment(UploadViewModel.self) private var upload
    @State private var vm: TimelineViewModel
    /// Stack hub state, borrowed from the root so a stack opened from a tile is
    /// the same object the «Me» hub shows (and vice versa).
    let stacks: StacksViewModel
    /// The process-wide download queue (gap G10), handed down by the root for
    /// the same reason as `stacks`: the mass action must feed the very queue
    /// the floating panel projects — never a second instance built here.
    let downloads: DownloadQueueViewModel
    /// Per-asset troubleshooter (gap G24), handed down by the root like
    /// `downloads`: the page opened from the viewer must be the instance the
    /// composition root owns, never one built here.
    let troubleshoot: AssetTroubleshootViewModel
    @Binding var scrollTargetID: String?
    @Binding var scrollTargetDay: String?
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.openProfile) private var openProfile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// App preferences (gap G22): the persisted density and grouping live in
    /// the store, so the pinch gesture, the Preferences stepper and this grid
    /// all drive one value.
    @Environment(AppSettingsStore.self) private var appSettings

    // Grid zoom (Photos-style pinch): 2-7 columns. `baseColumns` is the density
    // with no gesture on it — seeded once from the store and re-seeded when the
    // Preferences stepper changes it — and it is what the pinch math measures
    // against. `columnCount` is the live value; `gridScale` persists the
    // committed zoom between gestures, the live pinch multiplier folding in
    // during `MagnifyGesture.onChanged`.
    private let minColumnCount = 2
    private let maxColumnCount = 7
    @State private var baseColumns = 3
    @State private var columnCount = 3
    @State private var gridScale: CGFloat = 1.0

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: columnCount)
    }

    // UI-only haptic / scroll state (not VM concerns).
    // Pinned header shows the day group whose grid currently owns the top
    // edge; month-year derives from it (flips only on month change).
    @State private var pinnedDay: String?
    @State private var showScrollToTop = false
    @State private var lastFavoriteTick = 0
    @State private var lastDeleteTick = 0
    @State private var lastSelectionTick = 0
    @State private var pendingDeleteSelected = false
    @State private var pendingDeleteSingleID: String?
    @State private var presentAlbumPicker = false // AC-515 — Add to Album sheet
    @State private var viewerItem: PhotoViewerItem? // Full-screen photo viewer
    /// Stack opened from a stacked tile (grid → stack detail). Nil = no push.
    @State private var openedStackID: String?
    @State private var scrollPosition = ScrollPosition()

    init(
        vm: TimelineViewModel,
        stacks: StacksViewModel,
        downloads: DownloadQueueViewModel,
        troubleshoot: AssetTroubleshootViewModel? = nil,
        scrollTargetID: Binding<String?> = .constant(nil),
        scrollTargetDay: Binding<String?> = .constant(nil)
    ) {
        _vm = State(initialValue: vm)
        self.stacks = stacks
        self.downloads = downloads
        // Defaulted so a preview or a test can build the timeline without the
        // composition root; the app always passes the root's instance.
        self.troubleshoot = troubleshoot ?? DependencyContainer.shared.makeAssetTroubleshootViewModel()
        _scrollTargetID = scrollTargetID
        _scrollTargetDay = scrollTargetDay
    }

    var body: some View {
        @Bindable var auth = auth
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // Top sentinel — when it scrolls off, show the ↑ button.
                    Color.clear
                        .frame(height: 1)
                        .id("top")
                        .onAppear { showScrollToTop = false }
                        .onDisappear { showScrollToTop = true }

                    content
                }
                .scrollPosition($scrollPosition)
                .coordinateSpace(name: Self.scrollSpaceName)
                .onPreferenceChange(PinnedDayPreferenceKey.self) { frames in
                    pinnedDay = PinnedHeaderResolver.currentDay(from: frames)
                }
                // Photos-style pinned year + day (D8): floats over the grid,
                // top-left, no background — photos slide beneath. White text +
                // subtle shadow keeps it readable over any photo (Photos app
                // look). Year flips only at year boundaries; day per day.
                .overlay(alignment: .topLeading) {
                    if let day = pinnedDay, !vm.selectionMode {
                        VStack(alignment: .leading, spacing: PVSpacing.s2) {
                            // Under `.month` grouping the pin IS a month key
                            // ("YYYY-MM"), and the label is the one the builder
                            // already produced — one formatting path, so the
                            // sticky header can never word a month differently
                            // from the banner behind it. Under `.day` nothing
                            // changes. Under `.none` no group reports a frame,
                            // so `pinnedDay` stays nil and this whole overlay is
                            // gone — which is the point of a flat timeline.
                            // The IDs are what an XCUITest scenario asserts the
                            // grouping on (settings-parity): the copy below is
                            // localized, so a scenario reading the text would
                            // tie itself to the device's language. They sit on
                            // the two Texts, never on the VStack: an identifier
                            // on a container overwrites every descendant's.
                            if appSettings.groupBy == .month {
                                Text(pinnedMonthDisplay ?? day)
                                    .font(.pvTitle)
                                    .foregroundStyle(Color.white)
                                    .accessibilityIdentifier("timelinePinnedMonthHeader")
                            } else {
                                Text(DateHeaderFormatter.yearString(for: day))
                                    .font(.pvTitle)
                                    .foregroundStyle(Color.white)
                                    .accessibilityIdentifier("timelinePinnedYearHeader")
                                Text(DateHeaderFormatter.dayMonthString(for: day))
                                    .font(.pvSubhead.weight(.bold))
                                    .foregroundStyle(Color.white)
                                    .accessibilityIdentifier("timelinePinnedDayHeader")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, PVSpacing.s16)
                        .padding(.trailing, PVSpacing.s4)
                        .padding(.top, PVSpacing.s8)
                        .padding(.bottom, PVSpacing.s4)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1) // DS-exempt: contrast over photos
                        .accessibilityAddTraits(.isHeader)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Profile avatar + the explicit "Select" entry point
                    // (Photos-style): a liquid glass pill that rides alongside
                    // the pinned date header. Long-press entry still works;
                    // this makes selection discoverable for mass/bulk actions.
                    // Hidden once selection mode is active (toolbar takes over).
                    if !vm.selectionMode {
                        HStack(spacing: PVSpacing.s8) {
                            if !vm.items.isEmpty {
                                GlassEffectContainer {
                                    Button {
                                        vm.enterSelectionMode()
                                    } label: {
                                        Text("Select")
                                            .font(.pvHeadline)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, PVSpacing.s16)
                                            .padding(.vertical, PVSpacing.s8)
                                            .glassEffect(.regular, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .accessibilityIdentifier("selectButton")
                            }
                            ProfileAvatarButton { openProfile() }
                                .overlay { avatarBackupRing }
                        }
                        .padding(.trailing, PVSpacing.s16)
                        .padding(.top, PVSpacing.s8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .refreshable { await vm.refresh() }
                // Cross-tab "view in timeline" teleport: jump to the target
                // day when the asset isn't already loaded, then scroll to it.
                .onChange(of: scrollTargetID) { _, newID in
                    guard let newID else { return }
                    if vm.items.contains(where: { $0.id == newID }) {
                        attemptTimelineScroll(proxy: proxy)
                    } else {
                        Task {
                            await vm.jump(toDay: scrollTargetDay ?? "")
                            attemptTimelineScroll(proxy: proxy)
                        }
                    }
                }
                .onChange(of: vm.items.count) { _, _ in
                    if scrollTargetID != nil { attemptTimelineScroll(proxy: proxy) }
                }
                .scrollDismissesKeyboard(.immediately)
                // D7: Photos-style pinch-to-zoom grid. Simultaneous so it never
                // blocks tap/long-press/scroll. `gridScale` commits on end, so
                // the zoom level persists across gestures (Photos behavior).
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            columnCount = TimelineGridZoom.columns(
                                forEffectiveScale: TimelineGridZoom.effectiveScale(
                                    base: gridScale,
                                    magnification: value.magnification,
                                    defaultColumns: baseColumns,
                                    minColumns: minColumnCount,
                                    maxColumns: maxColumnCount
                                ),
                                defaultColumns: baseColumns,
                                minColumns: minColumnCount,
                                maxColumns: maxColumnCount
                            )
                        }
                        .onEnded { value in
                            gridScale = TimelineGridZoom.effectiveScale(
                                base: gridScale,
                                magnification: value.magnification,
                                defaultColumns: baseColumns,
                                minColumns: minColumnCount,
                                maxColumns: maxColumnCount
                            )
                            // The gesture is the writer of the setting too: what
                            // the pinch commits is what the next launch (and the
                            // Preferences stepper) shows.
                            appSettings.tilesPerRow = columnCount
                        }
                )
                // D6: tap on empty grid area exits selection mode. Cell taps
                // win via their own onTapGesture (hit-tested first).
                .onTapGesture {
                    if vm.selectionMode { vm.exitSelectionMode() }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showScrollToTop && !vm.selectionMode {
                        Button {
                            withAnimation(PVMotion.adaptive(PVMotion.gentle, reduceMotion: reduceMotion)) {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.pvHeadline)
                                .foregroundStyle(Color.immichPrimary)
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                                .pvFloatingShadow()
                        }
                        .accessibilityLabel(String(localized: "Scroll to top"))
                        .padding(.trailing, PVSpacing.s16)
                        .padding(.bottom, PVSpacing.s24)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .navigationTitle(vm.selectionMode ? Text("\(vm.selectedIds.count) selected") : Text(verbatim: ""))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                // Photos-style: no top bar normally (photos start right under
                // the island); the bar returns in selection mode for the
                // xmark + favorite/delete/add-to-album controls.
                .toolbar(vm.selectionMode ? .visible : .hidden, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            }
            .navigationDestination(item: $openedStackID) { stackId in
                StackDetailView(stackId: stackId, vm: stacks)
            }
            .appSensoryFeedback(.selection, trigger: vm.selectionMode)
            .appSensoryFeedback(.selection, trigger: lastSelectionTick)
            .appSensoryFeedback(.success, trigger: lastFavoriteTick)
            .appSensoryFeedback(.warning, trigger: lastDeleteTick)
            // Spring on selection-mode transitions (AC-V04).
            .animation(PVMotion.standard, value: vm.selectionMode)
        }
        .task {
            if vm.items.isEmpty {
                await vm.load()
            }
        }
        // Seed the grid from the persisted density, once. `baseColumns` is the
        // pinch's reference and `columnCount` is what the grid draws; both start
        // at the stored value so a relaunch comes back at the density the user
        // left (3 when nothing was ever stored).
        .onAppear {
            let stored = appSettings.tilesPerRow
            baseColumns = stored
            columnCount = stored
            gridScale = 1
        }
        // A change made in Preferences lands without a relaunch: the stepper
        // writes the same property the pinch does, and the grid re-seeds itself.
        .onChange(of: appSettings.tilesPerRow) { _, newValue in
            guard newValue != columnCount else { return }
            baseColumns = newValue
            columnCount = newValue
            gridScale = TimelineGridZoom.scale(forColumnCount: newValue, defaultColumns: newValue)
        }
        .alert("Delete \(vm.selectedIds.count) asset(s)?", isPresented: $pendingDeleteSelected) {
            Button("Delete", role: .destructive) {
                Task {
                    await vm.deleteSelected()
                    lastDeleteTick &+= 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them from your library. Action cannot be undone.")
        }
        // D3: surface VM errors (favorite/delete/load failures) — never swallow silently.
        .alert("Something went wrong", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: vm.errorMessage ?? "")
        }
        // D5: single-asset context-menu delete confirmation.
        .alert("Delete this asset?", isPresented: Binding(
            get: { pendingDeleteSingleID != nil },
            set: { if !$0 { pendingDeleteSingleID = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteSingleID {
                    Task {
                        await vm.delete(id: id)
                        lastDeleteTick &+= 1
                    }
                }
                pendingDeleteSingleID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteSingleID = nil }
        } message: {
            Text("This removes it from your library. Action cannot be undone.")
        }
        // AC-515 — Add to Album picker (shares AlbumsViewModel via environment, FM-3).
        .sheet(isPresented: $presentAlbumPicker) {
            AddToAlbumPickerSheet(selectedAssetIds: vm.selectedIds) {
                vm.exitSelectionMode()
            }
        }
        // Full-screen photo viewer (tap any photo → Photos-style browse/zoom).
        .photoViewer(
            item: $viewerItem,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken,
            troubleshoot: troubleshoot,
            onToggleFavorite: { asset in
                Task {
                    await vm.toggleFavorite(id: asset.id)
                    lastFavoriteTick &+= 1
                }
            },
            onDelete: { asset in
                Task { await vm.delete(id: asset.id) }
            },
            onArchive: { asset in
                Task { await vm.archive(id: asset.id) }
            }
        )
    }

    // MARK: - Backup progress ring (AC-BK05/BK06)
    // Backup progress as a circular ring around the profile avatar, on every
    // device. iOS never shows an app's OWN Live Activity in the Dynamic
    // Island while that app is frontmost — and this ring is only ever visible
    // while the app IS frontmost — so the ring and the island never compete:
    // island (or notification panel) out of app, ring in app. The ring
    // vanishes the moment the run finishes.
    @ViewBuilder
    private var avatarBackupRing: some View {
        let engine = upload.engine
        if engine.phase == .checking || engine.phase == .uploading {
            Circle()
                .trim(from: 0, to: max(0.02, engine.progressFraction))
                .stroke(
                    LinearGradient(
                        colors: [Color.immichPrimary, Color.immichPrimary.opacity(0.55)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 36, height: 36)
                .rotationEffect(.degrees(-90))
                .animation(
                    reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.15),
                    value: engine.progressFraction
                )
                .accessibilityLabel("Backing up — \(engine.progressPercent) percent")
        }
    }

    // MARK: - Content (skeleton / empty / grid)

    @ViewBuilder
    private var content: some View {
        if vm.items.isEmpty {
            if vm.isLoading {
                PVSkeletonGrid(rows: 4, columnCount: columnCount)
                    .padding(.horizontal, PVSpacing.s4)
                    .padding(.top, PVSpacing.s4)
            } else if vm.errorMessage != nil {
                ContentUnavailableView {
                    Label("Couldn't load photos", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(verbatim: vm.errorMessage ?? "")
                } actions: {
                    Button("Try Again") { Task { await vm.refresh() } }
                        .buttonStyle(PVPrimaryButtonStyle())
                }
                .padding(.top, 80)
            } else {
                ContentUnavailableView {
                    Label("No Photos", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Photos you upload to Immich will appear here.")
                } actions: {
                    Button("Refresh") { Task { await vm.refresh() } }
                }
                .padding(.top, 80)
            }
        } else {
            // Continuous grid (Photos-style): ONE LazyVGrid across all day
            // groups so rows always fill completely — no empty trailing cells
            // from per-day grid restarts. No per-day labels: the floating
            // month/day header is driven by the first item cell of each day.
            LazyVStack(alignment: .leading, spacing: PVSpacing.s2) {
                LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                    ForEach(timelineSections) { section in
                        switch section {
                        case .monthHeader(_, _):
                            // Month banner retired — the sticky header carries it.
                            EmptyView()

                        case .dayGroup(let group):
                            // The day group is what the sticky header follows.
                            sectionCells(group.items, pinKey: group.day)

                        case .monthGroup(let month, let items):
                            // One group per month, so the header follows the
                            // month key the builder produced.
                            sectionCells(items, pinKey: month)

                        case .flat(let items):
                            // Flat: nothing to pin, so nothing reports a frame
                            // and the sticky header stays away.
                            sectionCells(items, pinKey: nil)
                        }
                    }
                }
                .padding(.horizontal, PVSpacing.s4)
                if vm.canLoadMore {
                    PVSkeletonGrid(rows: 1, columnCount: columnCount)
                        .padding(.horizontal, PVSpacing.s4)
                        .padding(.top, PVSpacing.s4)
                }
            }
        }
    }

    // MARK: - Timeline sections (month interleaving)

    /// Typealias so the View reads the builder's `Section` enum without
    /// re-declaring it (single source of truth in `TimelineSectionBuilder`).
    private typealias TimelineSection = TimelineSectionBuilder.Section

    /// The sections for the current grouping. Memoized on the VM (audit P1) so
    /// the section pipeline runs only when `items` or the grouping changes, not
    /// on every body evaluation.
    private var timelineSections: [TimelineSection] {
        vm.timelineSections(groupBy: appSettings.groupBy)
    }

    /// The banner text of the pinned month (`.month` grouping), read out of the
    /// builder's own output so the sticky header and the banner behind it use
    /// the same string. `nil` while nothing is pinned.
    private var pinnedMonthDisplay: String? {
        guard let pin = pinnedDay else { return nil }
        for section in timelineSections {
            if case .monthHeader(let month, let display) = section, month == pin { return display }
        }
        return nil
    }

    /// One run of cells inside the single shared grid. `pinKey` is what the
    /// sticky header follows — the day under `.day`, the month under `.month` —
    /// and `nil` reports nothing at all, which is how a flat timeline ends up
    /// with no floating header.
    @ViewBuilder
    private func sectionCells(_ items: [AssetReactItem], pinKey: String?) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            cellView(for: item)
                .id(item.id)
                .task {
                    // Global last-item trigger — stays correct
                    // under section restructure because the
                    // id compared is the VM's flat last id.
                    if item.id == vm.items.last?.id {
                        await vm.loadMore()
                    }
                    // First-item trigger — loads the NEWER
                    // bucket when scrolling up after a jump,
                    // re-anchoring so the view doesn't jump.
                    if item.id == vm.items.first?.id {
                        let previousFirst = vm.items.first?.id
                        await vm.loadNewer()
                        if let previousFirst {
                            scrollPosition.scrollTo(id: previousFirst, anchor: .top)
                        }
                    }
                }
                // First cell of each group reports where the group starts
                // (its grid position) so the floating header resolves the
                // current day — or month.
                .background {
                    if index == 0, let pinKey {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PinnedDayPreferenceKey.self,
                                value: [pinKey: proxy.frame(in: .named(Self.scrollSpaceName)).minY]
                            )
                        }
                    }
                }
        }
    }

    // MARK: - Cell container — navigation vs selection-aware tap

    @ViewBuilder
    private func cellView(for item: AssetReactItem) -> some View {
        let cell = AssetThumbnailCell(
            asset: item,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken,
            isCompact: columnCount >= 6,
            selectionMode: vm.selectionMode,
            isSelected: vm.selectedIds.contains(item.id),
            onTap: {
                if vm.selectionMode {
                    vm.toggleSelection(id: item.id)
                    lastSelectionTick &+= 1
                } else if let stackId = item.stackId {
                    // The bucket holds only stack primaries: opening the flat
                    // pager here would skip the photos behind the cover.
                    openedStackID = stackId
                } else {
                    openViewer(for: item)
                }
            },
            onToggleFavorite: {
                Task {
                    await vm.toggleFavorite(id: item.id)
                    lastFavoriteTick &+= 1
                }
            },
            onDelete: {
                pendingDeleteSingleID = item.id
            },
            onArchive: {
                Task {
                    await vm.archive(id: item.id)
                }
            },
            onMoveToLockedFolder: {
                Task {
                    await vm.moveToLockedFolder(id: item.id)
                }
            }
        )
        .buttonStyle(.plain)

        if vm.selectionMode {
            cell
                .onLongPressGesture(minimumDuration: 0.4) {
                    vm.toggleSelection(id: item.id)
                    lastSelectionTick &+= 1
                }
        } else {
            cell
                .onLongPressGesture(minimumDuration: 0.4) {
                    vm.enterSelectionMode()
                    vm.toggleSelection(id: item.id)
                    lastSelectionTick &+= 1
                }
        }
    }

    // MARK: - Full-screen photo viewer

    /// Opens the Photos-style viewer at `item`, paging through the flat
    /// timeline order (matches grid visual order — `groupedByDay` preserves it).
    private func openViewer(for item: AssetReactItem) {
        guard let idx = vm.items.firstIndex(where: { $0.id == item.id }) else { return }
        viewerItem = PhotoViewerItem(assets: vm.items, index: idx)
    }

    /// Scrolls the timeline to `scrollTargetID` once that asset is loaded, then
    /// clears the target. Best-effort: only instantiated lazy cells respond to
    /// `scrollTo`, so a target far outside the loaded window stays a no-op.
    private func attemptTimelineScroll(proxy: ScrollViewProxy) {
        guard let target = scrollTargetID,
              vm.items.contains(where: { $0.id == target }) else { return }
        withAnimation(PVMotion.adaptive(PVMotion.gentle, reduceMotion: reduceMotion)) {
            proxy.scrollTo(target, anchor: .top)
        }
        scrollTargetID = nil
    }

    // MARK: - Toolbar — swaps between normal + selection modes (SF Symbols, V03)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if vm.selectionMode {
                Button {
                    vm.exitSelectionMode()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if vm.selectionMode {
                Button {
                    Task {
                        let target = !vm.selectedIds.allSatisfy { id in
                            vm.items.first { $0.id == id }?.isFavorite ?? false
                        }
                        // Exit only on success so a failed batch keeps the
                        // selection intact for retry (audit fix — mirrors
                        // deleteSelected's try-then-mutate discipline).
                        if await vm.batchSetFavorite(vm.selectedIds, favorite: target) {
                            vm.exitSelectionMode()
                        }
                        lastFavoriteTick &+= 1
                    }
                } label: {
                    Label("Favorite", systemImage: "heart")
                        .labelStyle(.iconOnly)
                }
                .disabled(vm.selectedIds.isEmpty)

                Button(role: .destructive) {
                    pendingDeleteSelected = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .disabled(vm.selectedIds.isEmpty)
                // Matched by identifier in `ReadOnlyModeUITests`: the label is
                // translated, and the scenario taps this one control to attempt a
                // write the read-only guard must refuse.
                .accessibilityIdentifier("deleteSelectedButton")

                // AC-515 — Add to Album. Opens picker sheet w/ selected assets.
                Button {
                    presentAlbumPicker = true
                } label: {
                    Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .disabled(vm.selectedIds.isEmpty)
                .accessibilityIdentifier("addToAlbumButton")

                // Archive selected assets — bulk visibility "archive".
                Button {
                    Task {
                        await vm.archiveSelected()
                    }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                        .labelStyle(.iconOnly)
                }
                .disabled(vm.selectedIds.isEmpty)
                .accessibilityIdentifier("archiveButton")

                // Locked folder (gap G12) — bulk visibility "locked". The
                // assets leave the grid here and are the folder's business
                // from now on; the filter menu deliberately stays without a
                // "locked" entry (the folder is not a timeline view).
                Button {
                    Task {
                        await vm.moveSelectedToLockedFolder()
                    }
                } label: {
                    Label("Move to Locked Folder", systemImage: "lock")
                        .labelStyle(.iconOnly)
                }
                .disabled(vm.selectedIds.isEmpty)
                .accessibilityIdentifier("moveToLockedFolderButton")

                // Stack selected assets (gap #1) — 2+ required.
                Button {
                    Task {
                        await vm.stackSelected()
                    }
                } label: {
                    Label("Stack", systemImage: "square.stack.3d.up")
                        .labelStyle(.iconOnly)
                }
                .disabled(vm.selectedIds.count < 2)
                .accessibilityIdentifier("stackButton")

                // Download selected (gap G10) — a batch goes to the process-wide
                // queue, which announces it to the server before streaming
                // (the server refuses a batch it was never told about). The
                // selection is the grid's, in grid order.
                Button {
                    Task {
                        await downloads.enqueue(assets: vm.items.filter { vm.selectedIds.contains($0.id) })
                        vm.exitSelectionMode()
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .labelStyle(.iconOnly)
                }
                .disabled(vm.selectedIds.isEmpty)
                .accessibilityIdentifier("downloadSelectionButton")
            } else {
                // AC-1010 — timeline filter menu (All / Favorites / Archived).
                Menu {
                    Button {
                        Task { await vm.setFilter(isFavorite: nil, visibility: nil) }
                    } label: {
                        if vm.filterIsFavorite == nil && vm.filterVisibility == nil {
                            Label("All", systemImage: "checkmark")
                        } else {
                            Text("All")
                        }
                    }
                    Button {
                        Task { await vm.setFilter(isFavorite: true, visibility: nil) }
                    } label: {
                        if vm.filterIsFavorite == true {
                            Label("Favorites", systemImage: "checkmark")
                        } else {
                            Text("Favorites")
                        }
                    }
                    Button {
                        Task { await vm.setFilter(isFavorite: nil, visibility: "archive") }
                    } label: {
                        if vm.filterVisibility == "archive" {
                            Label("Archived", systemImage: "checkmark")
                        } else {
                            Text("Archived")
                        }
                    }
                    Button {
                        Task { await vm.setFilter(isFavorite: nil, visibility: nil, withPartners: true) }
                    } label: {
                        if vm.filterWithPartners == true {
                            Label("Shared with you", systemImage: "checkmark")
                        } else {
                            Text("Shared with you")
                        }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("filterMenu")
            }
        }
    }
}

// MARK: - Pinned header support

/// Coordinate space each day grid reports its top edge into.
private extension TimelineView {
    static let scrollSpaceName = "timeline"
}

/// Collects each visible day grid's top edge (`minY`) in the timeline's
/// coordinate space. LazyVStack instantiates only on-screen grids, so the
/// dictionary stays small; `PinnedHeaderResolver` turns it into a day.
private struct PinnedDayPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
