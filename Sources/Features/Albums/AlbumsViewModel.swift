import Foundation

/// View model for the Albums tab (AC-506, AC-507).
/// Lists the user's albums + supports creation. Shared across the Albums tab
/// and the Timeline "Add to Album" picker (FM-3 mitigation — single source of
/// truth propagated via `.environment(AlbumsViewModel.self)`).
@MainActor
@Observable
final class AlbumsViewModel {
    private let client: any ImmichClient

    var albums: [AlbumResponseDto] = []
    var isLoading = false
    var loadErrorMessage: String?
    var actionErrorMessage: String?
    var isCreating = false

    init(client: any ImmichClient) {
        self.client = client
    }

    // MARK: - Load (AC-506)

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.getAlbums()
            // try-then-mutate: only mutate on success.
            albums = result
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = error.userFacingMessage
        }
    }

    func refresh() async {
        await load()
    }

    // MARK: - Create (AC-507)

    func createAlbum(name: String, description: String? = nil, assetIds: [String]? = nil) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            actionErrorMessage = String(localized: "Album name cannot be empty.")
            return
        }
        isCreating = true
        defer { isCreating = false }
        let dto = CreateAlbumDto(albumName: trimmed, description: description, assetIds: assetIds)
        do {
            let created = try await client.createAlbum(dto: dto)
            // try-then-mutate: append only on success.
            albums.append(created)
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.userFacingMessage
        }
    }

    // MARK: - Add assets (V1.5 polish — AC-704)

    /// Adds assets to an existing album. Used by `AddToAlbumPickerSheet` to avoid
    /// instantiating a throwaway `AlbumDetailViewModel` (which triggers a wasted
    /// `searchMetadata` round-trip per add). NO asset refresh — caller refreshes the
    /// shared albums list via `refresh()` if needed.
    func addAssets(ids: [String], toAlbumId albumId: String) async {
        guard !ids.isEmpty else { return }
        // SUG-1: clear any stale actionErrorMessage so the picker's nil-check reflects THIS call.
        actionErrorMessage = nil
        do {
            _ = try await client.addAssetsToAlbum(albumId: albumId, dto: BulkIdsDto(ids: ids))
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.userFacingMessage
        }
    }
}
