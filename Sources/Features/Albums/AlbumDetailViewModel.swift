import Foundation

/// View model for a single album's detail screen (AC-508..AC-513).
///
/// FM-2 mitigation: the Immich server's `AlbumResponseDto` does NOT include an
/// `assets` array, so album assets are fetched separately via
/// `searchMetadata(albumIds:[albumId])` (reuses the existing search endpoint,
/// no new server endpoint needed).
@MainActor
@Observable
final class AlbumDetailViewModel {
    private let client: any ImmichClient
    let albumId: String

    var album: AlbumResponseDto?
    var assets: [AssetReactItem] = []
    private var loadedIds: Set<String> = []
    var sharedLinks: [SharedLinkResponseDto] = []

    // Pre-load state: true from init so the first rendered frame shows the
    // spinner, not the "Album Unavailable" fallback (`.task` runs after the
    // initial body evaluation). `load()` re-sets it and clears it on exit.
    var isLoading = true
    var loadErrorMessage: String?
    var actionErrorMessage: String?
    var isDeleted = false

    // MARK: - Pagination state

    /// Items per `POST /api/search/metadata` page. Fixed.
    static let pageSize = 1000

    /// True while the server announced a next page that is still to be requested.
    private(set) var hasMorePages = false
    private(set) var isLoadingMore = false
    /// Error of a next-page request, distinct from `loadErrorMessage` (album / page 1).
    var loadMoreErrorMessage: String?
    /// Changes whenever the end of the grid may have moved, so the footer
    /// spinner can re-trigger `loadMore()` while the user already sits at the bottom.
    private(set) var gridEndRevision = 0

    enum GridFooter: Equatable {
        case none
        case loadingMore
        case error(String)
    }

    var gridFooter: GridFooter {
        if let message = loadMoreErrorMessage { return .error(message) }
        return hasMorePages ? .loadingMore : .none
    }

    private var nextPage: Int?
    /// Direction sent by the page 1 that established the current grid; later
    /// pages reuse it so a mid-pagination album refresh never mixes two orders.
    private var pageOrder: String?
    /// Local removals since the last page that advanced the pagination. The
    /// server paginates by offset, so each one shifts the next page by one photo.
    private var removedSinceLastPage = 0
    /// Ids removed locally since the last applied page 1 (never re-inserted).
    private var removedIdsSinceLoad: Set<String> = []
    private var removalsInFlight = 0
    private var removalEpoch = 0
    private var loadGeneration = 0
    private var isFetchingFirstPage = false

    init(client: any ImmichClient, albumId: String) {
        self.client = client
        self.albumId = albumId
    }

    // MARK: - Selection mode (AC-201 parity)

    /// True while the grid is in multi-select mode (Select button or long-press
    /// entry). Drives per-cell checkmark overlays + the selection toolbar.
    var selectionMode: Bool = false

    /// Ids the user has checked while in selection mode. Keyed by id so it
    /// stays stable across asset-list mutations.
    var selectedIds: Set<String> = []

    func enterSelectionMode() { selectionMode = true }

    func exitSelectionMode() {
        selectionMode = false
        selectedIds.removeAll()
    }

    /// Toggles membership of `id` in `selectedIds`.
    func toggleSelection(id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    // MARK: - Bulk actions (selection toolbar)

    /// Removes all selected assets from the album, then exits selection mode.
    /// On throw, selection state is preserved so the user can retry.
    func removeSelected() async {
        guard !selectedIds.isEmpty else { return }
        let ids = Array(selectedIds)
        do {
            let results = try await trackingRemoval {
                try await client.removeAssetsFromAlbum(albumId: albumId, dto: BulkIdsDto(ids: ids))
            }
            let removeSet = removedIds(results)
            removeLocally(removeSet)
            exitSelectionMode()
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.userFacingMessage
        }
    }

    /// Sets favorite uniformly across `ids` (skips ids already in the target
    /// state). Same try-then-mutate discipline as `removeAssets`; first throw
    /// stops the batch and surfaces `actionErrorMessage` without mutating the rest.
    /// - Returns: `true` on full success, `false` on error — callers exit
    ///   selection mode only on success (audit fix).
    @MainActor
    @discardableResult
    func batchSetFavorite(_ ids: Set<String>, favorite value: Bool) async -> Bool {
        for id in ids {
            guard let current = assets.first(where: { $0.id == id }), current.isFavorite != value else { continue }
            do {
                _ = try await client.updateAsset(id: id, dto: UpdateAssetDto(isFavorite: value))
                if let idx = assets.firstIndex(where: { $0.id == id }) {
                    assets[idx] = current.with(isFavorite: value)
                }
            } catch {
                actionErrorMessage = error.userFacingMessage
                return false
            }
        }
        return true
    }

    /// Moves to the trash the selected assets the current user owns (the server
    /// refuses the whole request when one id is not owned). Other members'
    /// photos stay in `assets`. On success removes them from `assets` +
    /// `loadedIds` and exits selection mode; on throw, state is preserved so the
    /// user can retry (actionErrorMessage set, selection kept).
    /// - Returns: the ids actually removed from `assets`.
    @discardableResult
    func deleteSelected(currentUserId: String?) async -> Set<String> {
        let ids = ownedSelectedIds(currentUserId: currentUserId)
        guard !ids.isEmpty else { return [] }
        do {
            // MUST throw-or-succeed before mutating anything.
            try await trackingRemoval { try await client.deleteAssets(ids: ids, force: false) }
            let removed = removeLocally(Set(ids))
            exitSelectionMode()
            actionErrorMessage = nil
            return removed
        } catch {
            actionErrorMessage = error.userFacingMessage
            return []
        }
    }

    /// Ids of the selected assets present in `assets` that the current user
    /// owns, in `assets` order. A nil/empty user id or an empty asset `ownerId`
    /// (offline items) is never "owned". Pure.
    func ownedSelectedIds(currentUserId: String?) -> [String] {
        guard let currentUserId, !currentUserId.isEmpty else { return [] }
        return assets
            .filter { selectedIds.contains($0.id) && !$0.ownerId.isEmpty && $0.ownerId == currentUserId }
            .map(\.id)
    }

    /// Single point of local removal. Returns the ids actually removed from
    /// `assets`; they count as removals for the pagination offset (the server
    /// paginates by offset, so each one shifts the next page).
    @discardableResult
    func removeLocally(_ ids: Set<String>) -> Set<String> {
        let removed = ids.intersection(assets.map(\.id))
        assets.removeAll { removed.contains($0.id) }
        loadedIds.subtract(removed)
        removedSinceLastPage += removed.count
        removedIdsSinceLoad.formUnion(removed)
        if !removed.isEmpty { gridEndRevision += 1 }
        return removed
    }

    /// Wraps the network call of a removal. A page request that overlaps one
    /// cannot know whether the server processed it before or after the removal.
    private func trackingRemoval<T>(_ op: () async throws -> T) async rethrows -> T {
        removalsInFlight += 1
        removalEpoch &+= 1
        defer {
            removalsInFlight -= 1
            removalEpoch &+= 1
            if removalsInFlight == 0 { gridEndRevision += 1 }
        }
        return try await op()
    }

    // MARK: - Permissions

    /// Role-derived permissions; before `load()` the role comes from `fallback`.
    func permissions(currentUserId: String?, fallback: AlbumResponseDto) -> AlbumDetailPermissions {
        AlbumDetailPermissions(album: album ?? fallback, userId: currentUserId)
    }

    /// Actions rendered on `surface`. The owned-selection count is computed
    /// here, never supplied by the caller.
    func allowedActions(
        on surface: AlbumDetailSurface,
        currentUserId: String?,
        fallback: AlbumResponseDto
    ) -> Set<AlbumDetailAction> {
        permissions(currentUserId: currentUserId, fallback: fallback)
            .allowedActions(
                on: surface,
                ownedSelectionCount: ownedSelectedIds(currentUserId: currentUserId).count
            )
    }

    // MARK: - Load (AC-508)

    /// Two-phase load: album metadata (try-then-mutate `album`) THEN page 1 of
    /// the assets via searchMetadata. A failure in the second phase still
    /// leaves `album` populated. Later pages come from `loadMore()`.
    func load() async {
        loadGeneration += 1
        let g = loadGeneration
        isLoading = true
        isLoadingMore = false

        // Selection is scoped to the current asset list; a reload starts clean.
        exitSelectionMode()

        // Phase 1: album metadata.
        do {
            let fetched = try await client.getAlbum(id: albumId)
            guard g == loadGeneration else { return }
            album = fetched
            loadErrorMessage = nil
        } catch {
            guard g == loadGeneration else { return }
            loadErrorMessage = error.userFacingMessage
            isLoading = false
            return
        }

        // Phase 2: page 1 via search (albumIds filter).
        await fetchFirstPage(generation: g)
    }

    /// Requests page 1 with the album's current order and replaces the grid.
    /// Ignored (no mutation) when a newer load started meanwhile.
    private func fetchFirstPage(generation g: Int) async {
        let order = album?.order?.rawValue
        let epoch = removalEpoch
        let before = removedIdsSinceLoad
        isFetchingFirstPage = true
        defer {
            if g == loadGeneration {
                isFetchingFirstPage = false
                isLoading = false
            }
        }
        do {
            let response = try await client.searchMetadata(dto: pageDto(page: 1, order: order))
            guard g == loadGeneration else { return }
            removedIdsSinceLoad.subtract(before)
            assets = []
            loadedIds = []
            append(response.assets.items.filter { !removedIdsSinceLoad.contains($0.id) })
            pageOrder = order
            if removalEpoch != epoch || removalsInFlight > 0 {
                // A removal crossed this request: re-request page 1, duplicates are absorbed.
                nextPage = 1
                hasMorePages = true
            } else {
                nextPage = response.assets.nextPage.flatMap(Int.init)
                hasMorePages = nextPage != nil
            }
            removedSinceLastPage = 0
            loadMoreErrorMessage = nil
            loadErrorMessage = nil
            gridEndRevision += 1
        } catch {
            guard g == loadGeneration else { return }
            // Album metadata already populated; surface the error but keep
            // `album` and the grid intact (try-then-mutate discipline).
            loadErrorMessage = error.userFacingMessage
        }
    }

    private func pageDto(page: Int, order: String?) -> MetadataSearchDto {
        MetadataSearchDto(albumIds: [albumId], order: order, page: page, size: Self.pageSize)
    }

    private func append(_ dtos: [AssetResponseDto]) {
        for dto in dtos where !loadedIds.contains(dto.id) {
            loadedIds.insert(dto.id)
            assets.append(AssetReactItem(from: dto))
        }
    }

    // MARK: - Next pages (scroll)

    /// Requests the next page when `currentItemId` is the last photo of the grid.
    func loadMoreIfNeeded(currentItemId: String) async {
        guard let last = assets.last, last.id == currentItemId else { return }
        await loadMore()
    }

    /// Requests the next page. No-op while a (re)load, another page or a removal
    /// is in flight, or when the server announced no further page. The page
    /// asked for is the one holding the real boundary once local removals are
    /// subtracted; the overlap is absorbed by `loadedIds`. A response that
    /// crossed a removal is discarded and requested again from the same boundary.
    func loadMore() async {
        guard !isLoading, !isFetchingFirstPage, !isLoadingMore, removalsInFlight == 0,
              hasMorePages, let next = nextPage else { return }
        isLoadingMore = true
        let g = loadGeneration
        let removed = removedSinceLastPage
        let epoch = removalEpoch
        let page = max(1, ((next - 1) * Self.pageSize - removed) / Self.pageSize + 1)
        do {
            let response = try await client.searchMetadata(dto: pageDto(page: page, order: pageOrder))
            guard g == loadGeneration else { return }
            if removalEpoch == epoch && removalsInFlight == 0 {
                append(response.assets.items)
                nextPage = response.assets.nextPage.flatMap(Int.init)
                hasMorePages = nextPage != nil
                removedSinceLastPage = max(0, removedSinceLastPage - removed)
            }
            loadMoreErrorMessage = nil
            isLoadingMore = false
            gridEndRevision += 1
        } catch {
            guard g == loadGeneration else { return }
            loadMoreErrorMessage = error.userFacingMessage
            isLoadingMore = false
        }
    }

    /// Photo count for the header: the server total (minus local removals) while
    /// pages remain, never less than what is loaded; the loaded count once complete.
    func displayedPhotoCount(fallback: Int) -> Int {
        guard let album else { return fallback }
        guard hasMorePages else { return assets.count }
        return max(assets.count, album.assetCount - removedIdsSinceLoad.count)
    }

    // MARK: - In-place updates (viewer)

    /// Favorite toggled from the viewer: patched in place, no reload.
    @discardableResult
    func setFavorite(id: String, isFavorite: Bool) async -> Bool {
        do {
            _ = try await client.updateAsset(id: id, dto: UpdateAssetDto(isFavorite: isFavorite))
            if let idx = assets.firstIndex(where: { $0.id == id }) {
                assets[idx] = assets[idx].with(isFavorite: isFavorite)
            }
            actionErrorMessage = nil
            return true
        } catch {
            actionErrorMessage = error.userFacingMessage
            return false
        }
    }

    /// Trashes one photo from the viewer; it leaves the grid and counts as a removal.
    @discardableResult
    func delete(id: String) async -> Bool {
        do {
            try await trackingRemoval { try await client.deleteAssets(ids: [id], force: false) }
            removeLocally([id])
            actionErrorMessage = nil
            return true
        } catch {
            actionErrorMessage = error.userFacingMessage
            return false
        }
    }

    /// Archives / unarchives one photo from the viewer. The photo stays in the
    /// album (the server keeps archived photos in it) with its visibility updated.
    /// - Returns: the error message on failure (shown in the viewer when
    ///   `handOffError`, else also in `actionErrorMessage`), nil on success.
    func setArchived(id: String, archived: Bool, handOffError: Bool) async -> String? {
        let visibility: AssetVisibility = archived ? .archive : .timeline
        do {
            try await client.bulkUpdateAssets(dto: AssetBulkUpdateDto(ids: [id], visibility: visibility))
            if let idx = assets.firstIndex(where: { $0.id == id }) {
                assets[idx] = assets[idx].with(visibility: visibility.rawValue)
            }
            return nil
        } catch {
            let message = error.userFacingMessage
            actionErrorMessage = handOffError ? nil : message
            return message
        }
    }

    // MARK: - Add assets (AC-509)

    func addAssets(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            _ = try await client.addAssetsToAlbum(albumId: albumId, dto: BulkIdsDto(ids: ids))
        } catch {
            actionErrorMessage = error.userFacingMessage
            return
        }
        // Restart from page 1 with the album's current order; any page still in flight is dropped.
        loadGeneration += 1
        isLoadingMore = false
        await fetchFirstPage(generation: loadGeneration)
        actionErrorMessage = nil
    }

    // MARK: - Remove assets (AC-510)

    func removeAssets(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            let results = try await trackingRemoval {
                try await client.removeAssetsFromAlbum(albumId: albumId, dto: BulkIdsDto(ids: ids))
            }
            // try-then-mutate: update local list only on success.
            let removeSet = removedIds(results)
            removeLocally(removeSet)
            // Keep the selection set consistent when a selected asset is
            // removed via the context menu (audit fix — stale "N selected").
            selectedIds.subtract(removeSet)
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.userFacingMessage
        }
    }

    /// Ids the server took out of the album: a success, or `not_found` (already
    /// absent). A refused entry (`no_permission`, …) stays on screen, as does an
    /// id missing from the response.
    private func removedIds(_ results: [BulkIdResponseDto]) -> Set<String> {
        Set(results.filter { $0.success || $0.error == .notFound }.map(\.id))
    }

    // MARK: - Delete album (AC-511)

    func deleteAlbum() async {
        do {
            try await client.deleteAlbum(id: albumId)
            // 204 No Content handled by sendAuthedRaw — no decode crash (AC-518).
            isDeleted = true
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.userFacingMessage
        }
    }

    // MARK: - Set cover (album cover change)

    /// Sets the album cover to `assetId` (must be a member of this album).
    /// try-then-mutate: `album` is updated only after the PATCH succeeds.
    /// - Returns: `true` on success — callers exit selection mode on success.
    @MainActor
    @discardableResult
    func setCover(assetId: String) async -> Bool {
        guard assets.contains(where: { $0.id == assetId }) else { return false }
        do {
            let updated = try await client.updateAlbum(
                id: albumId,
                dto: UpdateAlbumDto(albumName: nil, description: nil, albumThumbnailAssetId: assetId, isActivityEnabled: nil, order: nil)
            )
            album = updated
            actionErrorMessage = nil
            return true
        } catch {
            actionErrorMessage = error.userFacingMessage
            return false
        }
    }

    /// Updates the album's name, description and/or activity toggle
    /// (AC-1100). Try-then-mutate: `album` is replaced only after the PATCH
    /// succeeds. Returns success so the sheet can dismiss.
    @discardableResult
    func updateAlbumDetails(name: String?, description: String?, isActivityEnabled: Bool?) async -> Bool {
        do {
            let updated = try await client.updateAlbum(
                id: albumId,
                dto: UpdateAlbumDto(
                    albumName: name, description: description,
                    albumThumbnailAssetId: nil, isActivityEnabled: isActivityEnabled, order: nil
                )
            )
            album = updated
            actionErrorMessage = nil
            return true
        } catch {
            actionErrorMessage = error.userFacingMessage
            return false
        }
    }

    /// Refetches album metadata only (no spinner): used after the share sheet
    /// mutates `albumUsers` / roles so the detail screen stays in sync.
    func refreshAlbum() async {
        do {
            album = try await client.getAlbum(id: albumId)
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = error.userFacingMessage
        }
    }

    /// Builds a share sheet VM from the current album state (DI keeps the same
    /// client; `albumUsers` seeds the membership, `isAdmin` picks the right
    /// empty-state message when the directory is hidden).
    func makeShareViewModel(currentUserId: String, isAdmin: Bool) -> AlbumShareViewModel {
        AlbumShareViewModel(
            client: client,
            albumId: albumId,
            currentUserId: currentUserId,
            isAdmin: isAdmin,
            albumUsers: album?.albumUsers ?? []
        )
    }

    // MARK: - Shared links (AC-512, AC-513)

    func loadSharedLinks() async {
        do {
            sharedLinks = try await client.getSharedLinks(albumId: albumId)
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = error.userFacingMessage
        }
    }

    func createSharedLink(
        password: String?,
        description: String?,
        slug: String? = nil,
        expiresAt: Date? = nil
    ) async {
        let trimmedPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = (trimmedPassword?.isEmpty ?? true) ? nil : trimmedPassword
        let trimmedSlug = slug?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dto = SharedLinkCreateDto(
            type: .album,
            albumId: albumId,
            description: description,
            password: pw,
            expiresAt: expiresAt.map(SharedLinksViewModel.isoString(from:)),
            slug: (trimmedSlug?.isEmpty ?? true) ? nil : trimmedSlug
        )
        do {
            let link = try await client.createSharedLink(dto: dto)
            sharedLinks.append(link)
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.userFacingMessage
        }
    }

    func revokeSharedLink(id: String) async {
        do {
            try await client.deleteSharedLink(id: id)
            sharedLinks.removeAll { $0.id == id }
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.userFacingMessage
        }
    }

    /// Updates an existing shared link (description, password, expiry,
    /// permissions). Try-then-mutate: the row is replaced only on success.
    @discardableResult
    func updateSharedLink(id: String, dto: SharedLinkEditDto) async -> Bool {
        do {
            let updated = try await client.updateSharedLink(id: id, dto: dto)
            if let idx = sharedLinks.firstIndex(where: { $0.id == id }) {
                sharedLinks[idx] = updated
            }
            actionErrorMessage = nil
            return true
        } catch {
            actionErrorMessage = error.userFacingMessage
            return false
        }
    }
}

// MARK: - Permissions (pure predicate)

/// Actions whose availability depends on the user's album role (or, for
/// `deleteAssets`, on the photos selected). Other actions are always rendered.
enum AlbumDetailAction: Hashable {
    case editAlbum, setCover, deleteAlbum, sharedWith, removeFromAlbum, deleteAssets
}

/// Places in the album detail screen where gated actions can appear.
enum AlbumDetailSurface {
    case albumMenu, selectionBar, selectionMenu, assetContextMenu
}

/// The signed-in user's role in an album and what it allows.
struct AlbumDetailPermissions: Equatable {
    let role: AlbumUserRole

    init(album: AlbumResponseDto, userId: String?) {
        role = Self.role(of: userId, in: album)
    }

    /// v2.x: owner = `ownerId` (absent from `albumUsers`). v3+: owner is an
    /// `albumUsers` entry. Unknown or id-less users are viewers.
    static func role(of userId: String?, in album: AlbumResponseDto) -> AlbumUserRole {
        guard let userId, !userId.isEmpty else { return .viewer }
        if let ownerId = album.ownerId, !ownerId.isEmpty, ownerId == userId { return .owner }
        return album.albumUsers.first { $0.user.id == userId }?.role ?? .viewer
    }

    var canAddAssets: Bool { role == .owner || role == .editor }
    var canRemoveAssets: Bool { role == .owner || role == .editor }

    func allowedActions(on surface: AlbumDetailSurface, ownedSelectionCount: Int = 0) -> Set<AlbumDetailAction> {
        var result: Set<AlbumDetailAction> = []
        switch surface {
        case .albumMenu:
            if role == .owner { result = [.editAlbum, .sharedWith, .deleteAlbum] }
        case .selectionBar:
            if role == .owner { result = [.setCover] }
        case .selectionMenu:
            if canRemoveAssets { result.insert(.removeFromAlbum) }
            if ownedSelectionCount > 0 { result.insert(.deleteAssets) }
        case .assetContextMenu:
            if role == .owner { result.insert(.setCover) }
            if canRemoveAssets { result.insert(.removeFromAlbum) }
        }
        return result
    }
}
