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
            _ = try await client.removeAssetsFromAlbum(albumId: albumId, dto: BulkIdsDto(ids: ids))
            let removeSet = Set(ids)
            assets.removeAll { removeSet.contains($0.id) }
            loadedIds.subtract(removeSet)
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

    /// Deletes all selected assets from the library. On success removes them
    /// from `assets` + `loadedIds` and exits selection mode. On throw, state is
    /// preserved so the user can retry (actionErrorMessage set, selection kept).
    func deleteSelected() async {
        guard !selectedIds.isEmpty else { return }
        let ids = Array(selectedIds)
        do {
            // MUST throw-or-succeed before mutating anything.
            try await client.deleteAssets(ids: ids, force: false)
            let removeSet = Set(ids)
            assets.removeAll { removeSet.contains($0.id) }
            loadedIds.subtract(removeSet)
            exitSelectionMode()
        } catch {
            actionErrorMessage = error.userFacingMessage
        }
    }

    // MARK: - Load (AC-508)

    /// Two-phase load: album metadata (try-then-mutate `album`) THEN assets
    /// via searchMetadata (try-then-mutate `assets` independently). A failure
    /// in the second phase still leaves `album` populated.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        // Selection is scoped to the current asset list; a reload starts clean.
        exitSelectionMode()

        // Phase 1: album metadata.
        do {
            album = try await client.getAlbum(id: albumId)
            loadErrorMessage = nil
        } catch {
            // Album fetch failed: nothing else to do.
            loadErrorMessage = error.userFacingMessage
            return
        }

        // Phase 2: assets via search (albumIds filter).
        await fetchAssets()
    }

    private func fetchAssets() async {
        do {
            let dto = MetadataSearchDto(albumIds: [albumId], size: 1000)
            let response = try await client.searchMetadata(dto: dto)
            applyAssets(response.assets.items, append: false)
        } catch {
            // Album metadata already populated; surface asset-fetch error but
            // keep `album` intact (try-then-mutate discipline).
            loadErrorMessage = error.userFacingMessage
        }
    }

    private func applyAssets(_ dtos: [AssetResponseDto], append: Bool) {
        if !append {
            assets = []
            loadedIds = []
        }
        for dto in dtos where !loadedIds.contains(dto.id) {
            loadedIds.insert(dto.id)
            assets.append(AssetReactItem(from: dto))
        }
    }

    // MARK: - Add assets (AC-509)

    func addAssets(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            _ = try await client.addAssetsToAlbum(albumId: albumId, dto: BulkIdsDto(ids: ids))
            // Refresh assets from server after a successful add.
            await fetchAssets()
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.userFacingMessage
        }
    }

    // MARK: - Remove assets (AC-510)

    func removeAssets(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            _ = try await client.removeAssetsFromAlbum(albumId: albumId, dto: BulkIdsDto(ids: ids))
            // try-then-mutate: update local list only on success.
            let removeSet = Set(ids)
            assets.removeAll { removeSet.contains($0.id) }
            loadedIds.subtract(removeSet)
            // Keep the selection set consistent when a selected asset is
            // removed via the context menu (audit fix — stale "N selected").
            selectedIds.subtract(removeSet)
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.userFacingMessage
        }
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
