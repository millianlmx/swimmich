import SwiftUI

/// Identifiable wrapper for the "Shared With" sheet — `.sheet(item:)` requires
/// a non-optional item at render time, guaranteeing the sheet never presents
/// an empty body (the VM is built when the menu item is tapped).
private struct AlbumShareSheetItem: Identifiable {
    let id = UUID()
    let vm: AlbumShareViewModel
}

/// Identifiable wrapper for the Activity sheet — same pattern as the share
/// sheet so the VM is built on tap, never while the row renders.
private struct ActivityFeedSheetItem: Identifiable {
    let id = UUID()
    let vm: ActivityFeedViewModel
}

/// Album detail screen (AC-508..AC-513). A Photos-style stretchy parallax hero
/// (album cover + overlaid title/count) sits above a 3-column photo grid with a
/// "Photos" section header. Toolbar menu offers share-link management + delete;
/// per-asset context menu offers "Remove from album" (AC-510).
struct AlbumDetailView: View {
    @Environment(AuthViewModel.self) private var auth
    @State private var vm: AlbumDetailViewModel

    @State private var presentingShare = false
    @State private var presentingEditAlbum = false
    @State private var shareSheetItem: AlbumShareSheetItem?
    @State private var presentingDeleteConfirm = false
    @State private var pendingRemoveAssetId: String?
    @State private var pendingRemoveSelected = false
    @State private var pendingDeleteSelected = false
    @State private var presentAlbumPicker = false // Add selected assets to another album
    @State private var activityFeedItem: ActivityFeedSheetItem?
    @State private var roadTripVM: RoadTripViewModel?
    @State private var presentingRoadTrip = false
    @State private var lastRemoveTick = 0
    @State private var lastDeleteTick = 0
    @State private var lastFavoriteTick = 0
    @State private var lastSelectionTick = 0
    @State private var viewerItem: PhotoViewerItem?
    /// True from the moment the viewer is requested until it is dismissed, so
    /// an action error is shown in the viewer's banner, then in the album alert.
    @State private var viewerOnScreen = false
    /// What the photo viewer needs to grow out of a thumbnail and shrink back
    /// onto it (L-14): the thumbnails' frames and the scroll owed on close.
    @State private var zoomSource = ViewerZoomSource()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3)

    /// The album as known by the grid. Rendered immediately on the first frame
    /// (hero cover + title) so the zoom-open transition lands on real content,
    /// not a spinner; the freshly-fetched `vm.album` replaces it once loaded.
    private let initialAlbum: AlbumResponseDto

    /// Gated actions for `surface`, recomputed on every render from the view
    /// model (role + owned selection); never cached in `@State`.
    private func allowed(on surface: AlbumDetailSurface) -> Set<AlbumDetailAction> {
        vm.allowedActions(on: surface, currentUserId: auth.userId, fallback: initialAlbum)
    }

    /// Reflects the saved order: a refused save leaves the old choice selected.
    private var orderBinding: Binding<AssetOrder> {
        Binding(
            get: { vm.albumOrder },
            set: { order in Task { await vm.setAlbumOrder(order) } }
        )
    }

    init(
        album: AlbumResponseDto,
        client: any ImmichClient = DependencyContainer.shared.libraryClient
    ) {
        self.initialAlbum = album
        _vm = State(initialValue: AlbumDetailViewModel(client: client, albumId: album.id))
    }

    var body: some View {
        Group {
            if vm.isDeleted {
                ContentUnavailableView("Album Deleted", systemImage: "trash")
            } else if let album = vm.album {
                VStack(spacing: 0) {
                    refreshStatus
                    content(for: album)
                }
            } else if case .error(let message) = vm.albumState {
                errorState(message)
            } else {
                // First frame: hero renders from the grid-known DTO so the zoom
                // transition lands on real content; skeleton below while loading.
                loadingContent
            }
        }
        .navigationTitle(vm.selectionMode ? "\(vm.selectedIds.count) selected" : (vm.album?.albumName ?? initialAlbum.albumName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if vm.selectionMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        vm.exitSelectionMode()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task {
                            let target = !vm.selectedIds.allSatisfy { id in
                                vm.assets.first { $0.id == id }?.isFavorite ?? false
                            }
                            // Exit only on success (retry keeps selection) —
                            // parity with Timeline's favorite button (audit fix).
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

                    Button {
                        presentAlbumPicker = true
                    } label: {
                        Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(vm.selectedIds.isEmpty)

                    if allowed(on: .selectionBar).contains(.setCover) {
                        Button {
                            guard vm.selectedIds.count == 1, let first = vm.selectedIds.first else { return }
                            Task {
                                // Exit only on success (retry keeps selection).
                                if await vm.setCover(assetId: first) {
                                    vm.exitSelectionMode()
                                }
                            }
                        } label: {
                            Label("Set as Cover", systemImage: "photo.badge.checkmark")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(vm.selectedIds.count != 1)
                    }

                    Button {
                        presentRoadTrip(assets: vm.assets.filter { vm.selectedIds.contains($0.id) })
                    } label: {
                        Label("Road Trip", systemImage: "car.fill")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(vm.selectedIds.isEmpty)
                }
                // Native trailing ellipsis menu — Photos-parity bulk actions.
                // Not rendered when the user has nothing to do in it.
                let menuActions = allowed(on: .selectionMenu)
                if !menuActions.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if menuActions.contains(.removeFromAlbum) {
                                Button(role: .destructive) {
                                    pendingRemoveSelected = true
                                } label: {
                                    Label {
                                        Text("Remove from Album")
                                            .foregroundStyle(Color.red)
                                    } icon: {
                                        Image(systemName: "rectangle.stack.badge.minus")
                                            .foregroundStyle(Color.red)
                                    }
                                }
                                .tint(.red)
                                .disabled(vm.selectedIds.isEmpty)
                            }

                            if menuActions.contains(.deleteAssets) {
                                Button(role: .destructive) {
                                    pendingDeleteSelected = true
                                } label: {
                                    Label {
                                        Text("Delete")
                                            .foregroundStyle(Color.red)
                                    } icon: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(Color.red)
                                    }
                                }
                                .tint(.red)
                                .disabled(vm.selectedIds.isEmpty)
                            }
                        } label: {
                            Label("Album actions", systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                        }
                        .tint(.primary)
                    }
                }
            } else if !vm.isDeleted {
                // Native trailing ellipsis menu — Apple Files parity. Bare
                // `ellipsis` glyph (3 horizontal dots, no circle), the system
                // dropdown chrome. The zoom-transition toolbar lag is avoided
                // upstream by gating `.navigationTransition(.zoom)` to iOS 27+
                // (see AlbumsView); on iOS 26 this screen uses a standard push,
                // so the bar (back chevron + title + this menu) renders as one.
                ToolbarItem(placement: .topBarTrailing) {
                    let albumActions = allowed(on: .albumMenu)
                    Menu {
                        Button {
                            vm.enterSelectionMode()
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                                .foregroundStyle(Color.primary)
                        }
                        .tint(Color.primary)
                        if albumActions.contains(.editAlbum) {
                            Divider()
                            Button {
                                presentingEditAlbum = true
                            } label: {
                                Label("Edit Album", systemImage: "pencil")
                                    .foregroundStyle(Color.primary)
                            }
                            .tint(Color.primary)
                            .accessibilityIdentifier("albumEditAction")
                        }
                        Divider()
                        Button {
                            presentingShare = true
                        } label: {
                            Label("Shared Links", systemImage: "square.and.arrow.up")
                                .foregroundStyle(Color.primary)
                        }
                        .tint(Color.primary)
                        Button {
                            activityFeedItem = ActivityFeedSheetItem(
                                vm: ActivityFeedViewModel(
                                    client: DependencyContainer.shared.client,
                                    albumId: vm.albumId,
                                    currentUserId: auth.userId ?? ""
                                )
                            )
                        } label: {
                            Label("Activity", systemImage: "bubble.left.and.bubble.right")
                                .foregroundStyle(Color.primary)
                        }
                        .tint(Color.primary)
                        Button {
                            presentRoadTrip(assets: vm.assets)
                        } label: {
                            Label("Road Trip", systemImage: "car.fill")
                                .foregroundStyle(Color.primary)
                        }
                        .tint(Color.primary)
                        if !albumActions.isEmpty {
                            Divider()
                        }
                        if albumActions.contains(.changeOrder) {
                            Menu {
                                Picker("Sort Order", selection: orderBinding) {
                                    Text("Newest First")
                                        .tag(AssetOrder.desc)
                                        .accessibilityIdentifier("albumOrderNewest")
                                    Text("Oldest First")
                                        .tag(AssetOrder.asc)
                                        .accessibilityIdentifier("albumOrderOldest")
                                }
                                .pickerStyle(.inline)
                            } label: {
                                Label("Sort Order", systemImage: "arrow.up.arrow.down")
                                    .foregroundStyle(Color.primary)
                            }
                            .tint(Color.primary)
                            .accessibilityIdentifier("albumOrderMenu")
                        }
                        if albumActions.contains(.sharedWith) {
                            Button {
                                shareSheetItem = AlbumShareSheetItem(
                                    vm: vm.makeShareViewModel(
                                        currentUserId: auth.userId ?? "",
                                        isAdmin: auth.isAdmin
                                    )
                                )
                            } label: {
                                Label("Shared With", systemImage: "person.2")
                                    .foregroundStyle(Color.primary)
                            }
                            .tint(Color.primary)
                        }
                        if albumActions.contains(.deleteAlbum) {
                            Divider()
                            // Forced red: the menu-level `.tint(.primary)` below can
                            // override the destructive role on iOS 26, so the icon
                            // AND the title carry their own explicit red style.
                            Button(role: .destructive) {
                                presentingDeleteConfirm = true
                            } label: {
                                Label {
                                    Text("Delete Album")
                                        .foregroundStyle(Color.red)
                                } icon: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(Color.red)
                                }
                            }
                            .tint(Color.red)
                        }
                    } label: {
                        Label("Album actions", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("albumActionsMenu")
                }
            }
        }
        .task {
            await vm.load()
            await vm.probeServerVersionIfEditor(currentUserId: auth.userId)
        }
        .sheet(isPresented: $presentingShare) {
            SharedLinkSheet(vm: vm)
        }
        .sheet(isPresented: $presentingEditAlbum) {
            EditAlbumSheet(vm: vm)
        }
        .sheet(item: $shareSheetItem, onDismiss: {
            Task { await vm.refreshAlbum() }
        }) { item in
            AlbumShareSheet(vm: item.vm)
        }
        .sheet(item: $activityFeedItem) { item in
            ActivityFeedSheet(vm: item.vm)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Delete this album? The photos themselves are not deleted.",
            isPresented: $presentingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) {
                Task {
                    await vm.deleteAlbum()
                    if vm.isDeleted { lastDeleteTick &+= 1 }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Error", isPresented: Binding(
            get: { vm.actionErrorMessage != nil && !viewerOnScreen },
            set: { if !$0 { vm.actionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.actionErrorMessage ?? "")
        }
        .alert("Delete \(vm.ownedSelectedIds(currentUserId: auth.userId).count) asset(s)?", isPresented: $pendingDeleteSelected) {
            Button("Delete", role: .destructive) {
                Task {
                    await vm.deleteSelected(currentUserId: auth.userId)
                    lastDeleteTick &+= 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them from your library. Action cannot be undone.")
        }
        .alert(
            "Remove \(vm.selectedIds.count) photo\(vm.selectedIds.count == 1 ? "" : "s") from this album?",
            isPresented: $pendingRemoveSelected
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    await vm.removeSelected()
                    lastRemoveTick &+= 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them from the album. The photos stay in your library.")
        }
        .sheet(isPresented: $presentAlbumPicker) {
            AddToAlbumPickerSheet(selectedAssetIds: vm.selectedIds) {
                vm.exitSelectionMode()
            }
        }
        .appSensoryFeedback(.warning, trigger: lastDeleteTick)
        .appSensoryFeedback(.success, trigger: lastRemoveTick)
        .appSensoryFeedback(.success, trigger: vm.album?.albumThumbnailAssetId)
        .appSensoryFeedback(.selection, trigger: vm.selectionMode)
        .appSensoryFeedback(.selection, trigger: lastSelectionTick)
        .onAppear {
            zoomSource.orderedIDs = { [vm = self.vm] in vm.assets.map(\.id) }
        }
        .photoViewer(
            item: $viewerItem,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken,
            onToggleFavorite: { asset, value in
                Task { await vm.setFavorite(id: asset.id, isFavorite: value) }
            },
            onDelete: { asset in
                Task { await vm.delete(id: asset.id) }
            },
            onArchive: { asset, archive in
                await vm.setArchived(id: asset.id, archived: archive, handOffError: viewerItem != nil)
            },
            onDismiss: { viewerOnScreen = false },
            zoomSource: zoomSource
        )
        .fullScreenCover(isPresented: $presentingRoadTrip) {
            if let roadTripVM {
                RoadTripView(vm: roadTripVM)
            }
        }
    }

    /// Builds the road-trip VM for the given assets and presents it full-screen.
    private func presentRoadTrip(assets: [AssetReactItem]) {
        guard !assets.isEmpty else { return }
        let baseURL = auth.baseURL ?? URL(string: "https://example.com")!
        roadTripVM = DependencyContainer.shared.makeRoadTripViewModel(
            albumId: vm.albumId,
            selectedAssetIds: Set(assets.map(\.id)),
            albumTitle: vm.album?.albumName ?? initialAlbum.albumName,
            baseURL: baseURL,
            token: auth.accessToken
        )
        presentingRoadTrip = true
    }

    /// Album unknown and its read failed. The `ScrollView` carries the same
    /// `.refreshable` as the grid, so a pull from here keeps the error up.
    private func errorState(_ message: String) -> some View {
        ScrollView {
            PVErrorStateView(
                title: "Couldn't load album",
                message: message,
                identifierPrefix: "albumDetail",
                retry: { Task { await vm.reload() } }
            )
            .containerRelativeFrame(.vertical)
        }
        .refreshable { await vm.refresh() }
    }

    /// Opens the Photos-style viewer at `item`, paging through album order.
    private func openViewer(for item: AssetReactItem) {
        guard let idx = vm.assets.firstIndex(where: { $0.id == item.id }) else { return }
        zoomSource.presentInstantly {
            viewerOnScreen = true
            viewerItem = PhotoViewerItem(assets: vm.assets, index: idx)
        }
    }

    // MARK: - Cell container — navigation vs selection-aware tap

    @ViewBuilder
    private func cellView(for item: AssetReactItem) -> some View {
        let cell = AssetThumbnailCell(
            asset: item,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken,
            selectionMode: vm.selectionMode,
            isSelected: vm.selectedIds.contains(item.id),
            onTap: {
                if vm.selectionMode {
                    vm.toggleSelection(id: item.id)
                    lastSelectionTick &+= 1
                } else {
                    openViewer(for: item)
                }
            }
        )
        .buttonStyle(.plain)

        if vm.selectionMode {
            // Context menu suppressed in selection mode: long-press must toggle,
            // and "Remove" mid-selection would corrupt the selection set
            // (audit fix — stale selectedIds after removeAssets).
            cell
                .onLongPressGesture(minimumDuration: 0.4) {
                    vm.toggleSelection(id: item.id)
                    lastSelectionTick &+= 1
                }
        } else {
            let cellActions = allowed(on: .assetContextMenu)
            if cellActions.isEmpty {
                // Nothing to offer (viewer): no context menu, long-press selects.
                cell
                    .onLongPressGesture(minimumDuration: 0.4) {
                        vm.enterSelectionMode()
                        vm.toggleSelection(id: item.id)
                        lastSelectionTick &+= 1
                    }
            } else {
                cell
                    .contextMenu {
                        if cellActions.contains(.setCover) {
                            Button {
                                Task { await vm.setCover(assetId: item.id) }
                            } label: {
                                Label("Set as Cover", systemImage: "photo.badge.checkmark")
                            }
                        }
                        if cellActions.contains(.removeFromAlbum) {
                            Button(role: .destructive) {
                                pendingRemoveAssetId = item.id
                            } label: {
                                Label("Remove from Album", systemImage: "rectangle.stack.badge.minus")
                            }
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.4) {
                        vm.enterSelectionMode()
                        vm.toggleSelection(id: item.id)
                        lastSelectionTick &+= 1
                    }
            }
        }
    }

    private var coverAssetId: String? {
        (vm.album ?? initialAlbum).albumThumbnailAssetId ?? vm.assets.first?.id
    }

    /// First-frame layout: hero from the grid-known album + skeleton grid, so
    /// the zoom-open lands on the real hero and the layout does not jump when
    /// the network resolves.
    @ViewBuilder
    private var loadingContent: some View {
        ScrollView {
            heroHeader(for: initialAlbum)

            HStack {
                Text("Photos")
                    .font(.pvCaption)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.textSecondaryPV)
                Spacer()
            }
            .padding(.horizontal, PVSpacing.s4)
            .padding(.top, PVSpacing.s8)
            .padding(.bottom, PVSpacing.s2)

            PVSkeletonGrid(rows: 4, columnCount: 3)
                .padding(.horizontal, PVSpacing.s4)
                .pvLoadingIndicator("albumDetailLoading")
        }
    }

    @ViewBuilder
    private func content(for album: AlbumResponseDto) -> some View {
        ScrollViewReader { proxy in
            // One ScrollView through the loading, error, empty and grid states
            // of the photos: a state change must not cancel the task of a
            // pull-to-refresh in flight.
            ScrollView {
                heroHeader(for: album)
                photosSection
            }
            .refreshable { await vm.refresh() }
            // D6: tap on empty grid area exits selection mode. Cell taps win
            // via their own onTapGesture (hit-tested first).
            .onTapGesture {
                if vm.selectionMode { vm.exitSelectionMode() }
            }
            .animation(PVMotion.standard, value: vm.selectionMode)
            .alert(
                "Remove this photo from the album?",
                isPresented: Binding(
                    get: { pendingRemoveAssetId != nil },
                    set: { if !$0 { pendingRemoveAssetId = nil } }
                )
            ) {
                Button("Remove", role: .destructive) {
                    if let id = pendingRemoveAssetId {
                        Task {
                            await vm.removeAssets(ids: [id])
                            pendingRemoveAssetId = nil
                            lastRemoveTick &+= 1
                        }
                    }
                }
                Button("Cancel", role: .cancel) { pendingRemoveAssetId = nil }
            } message: {
                Text("The photo stays in your library.")
            }
            .viewerZoomViewport(zoomSource)
            .viewerZoomReveal(zoomSource, proxy: proxy)
        }
    }

    /// "Photos" section header — Apple Photos style.
    private var photosHeader: some View {
        HStack {
            Text("Photos")
                .font(.pvCaption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .foregroundStyle(Color.textSecondaryPV)
            Spacer()
        }
        .padding(.horizontal, PVSpacing.s4)
        .padding(.top, PVSpacing.s8)
        .padding(.bottom, PVSpacing.s2)
    }

    /// Below the hero: what the photos' own read says (`assetsState`).
    @ViewBuilder
    private var photosSection: some View {
        switch vm.assetsState {
        case .loading:
            photosHeader
            PVSkeletonGrid(rows: 4, columnCount: 3)
                .padding(.horizontal, PVSpacing.s4)
                .pvLoadingIndicator("albumDetailLoading")
        case .error(let message):
            PVErrorStateView(
                title: "Couldn't load photos",
                message: message,
                identifierPrefix: "albumDetail",
                retry: { Task { await vm.reload() } }
            )
        case .empty:
            ContentUnavailableView(
                "No Photos",
                systemImage: "photo",
                description: Text("Add photos from the Timeline using “Add to Album”.")
            )
            .padding(.top, PVSpacing.s24)
            .accessibilityIdentifier("albumDetailEmptyState")
        case .data:
            photosHeader
            photoGrid
        }
    }

    private var photoGrid: some View {
        LazyVStack(alignment: .leading, spacing: PVSpacing.s2) {
            LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                ForEach(vm.assets, id: \.id) { item in
                    cellView(for: item)
                        .viewerZoomTile(id: item.id, source: zoomSource)
                        .id(item.id)
                        .onAppear {
                            Task { await vm.loadMoreIfNeeded(currentItemId: item.id) }
                        }
                }
            }
            .padding(.horizontal, PVSpacing.s4)

            switch vm.gridFooter {
            case .none:
                EmptyView()
            case .error(let message):
                InlineErrorBadge(message: message, retry: { Task { await vm.loadMore() } })
                    .padding(.horizontal, PVSpacing.s4)
            case .loadingMore:
                // Recreated on every `gridEndRevision`: the lazy stack only
                // builds the footer, and so only fires its `onAppear`, when it
                // is on screen after layout. An `onChange` ran before layout
                // and chained pages off-screen. No `.task(id:)`: it would
                // cancel the request in flight.
                ProgressView()
                    .padding(.vertical, PVSpacing.s12)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("albumLoadMore")
                    .onAppear { Task { await vm.loadMore() } }
                    .id(vm.gridEndRevision)
            }
        }
    }

    /// Above the scroll view, while the album is shown: the banner of a failed
    /// read (data kept), or a spinner standing in for it during its "Try Again".
    @ViewBuilder
    private var refreshStatus: some View {
        if vm.loadErrorMessage != nil, vm.assetsState != .loading,
           vm.albumState == .data(.reloading) || vm.assetsState == .data(.reloading) {
            ProgressView()
                .padding(PVSpacing.s8)
                .pvLoadingIndicator("albumDetailLoading")
        } else if let message = refreshErrorMessage {
            InlineErrorBadge(message: message, retry: { Task { await vm.reload() } })
                .padding(PVSpacing.s16)
                .accessibilityIdentifier("albumDetailRefreshError")
        }
    }

    /// The failure of a read that left data in place: the album's, else the photos'.
    private var refreshErrorMessage: String? {
        if case .data(.failed(let message)) = vm.albumState { return message }
        if case .data(.failed(let message)) = vm.assetsState { return message }
        return nil
    }

    /// Stretchy parallax hero: the album cover scales up when over-scrolled at
    /// the top, with the title + count overlaid on a legibility gradient. Pairs
    /// with `AlbumsView`'s matched source for the zoom-morph open/close.
    @ViewBuilder
    private func heroHeader(for album: AlbumResponseDto) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if let coverId = coverAssetId {
                        AuthenticatedAsyncImage(
                            url: ImmichAssetURL.thumbnail(assetId: coverId, thumbhash: "", baseURL: auth.baseURL ?? URL(string: "https://example.com")!),
                            token: auth.accessToken
                        )
                    } else {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.textSecondaryPV)
                    }
                }
                .scrollTransition { content, phase in
                    // Stretchy-header: scale up beyond bounds when pulled down.
                    content
                        .scaleEffect(phase.isIdentity ? 1 : 1.35, anchor: .top)
                        .opacity(phase.isIdentity ? 1 : 0.92)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .allowsHitTesting(false)
                }
                .clipped()

            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                Text(album.albumName)
                    .accessibilityIdentifier("albumHeroTitle")
                    .font(.pvTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                // While loading, the grid-known count is authoritative; once
                // loaded the fetched asset list wins (matches grid contents).
                Text("\(vm.displayedPhotoCount(fallback: album.assetCount)) Photos")
                    .font(.pvSubhead)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                collaboratorAvatars(for: album)
            }
            .padding(PVSpacing.s16)
        }
    }

    /// Photos-style overlapping avatar stack of the album's collaborators
    /// (self excluded), with a "+N" overflow badge. Nothing when not shared.
    @ViewBuilder
    private func collaboratorAvatars(for album: AlbumResponseDto) -> some View {
        let others = album.albumUsers.filter { $0.user.id != auth.userId }
        if !others.isEmpty {
            HStack(spacing: -PVSpacing.s8) {
                ForEach(others.prefix(4), id: \.user.id) { entry in
                    UserAvatarCircle(user: entry.user, size: 24, baseURL: auth.baseURL, token: auth.accessToken)
                        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                }
                if others.count > 4 {
                    Text("+\(others.count - 4)")
                        .font(.pvCaption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.45), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 3)
        }
    }
}
