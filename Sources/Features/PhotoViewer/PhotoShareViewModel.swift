import Foundation
import Observation

/// Backs the viewer's share sheet.
///
/// Two flows, mirroring the Immich share model:
/// 1. **Shared album** — create a new album pre-shared with selected instance
///    users (`createAlbum` + `albumUsers`), or add the photo to an existing
///    shared album (`addAssetsToAlbum`).
/// 2. **Public link** — an INDIVIDUAL shared link for the asset with
///    permission toggles (`allowDownload` / `showMetadata`).
///
/// Constructor-injected client + baseURL so every flow is unit-testable
/// (mirrors the other ViewModels). @MainActor: all state drives SwiftUI.
@MainActor
@Observable
final class PhotoShareViewModel {
    let asset: AssetReactItem
    let client: any ImmichClient
    let baseURL: URL
    /// `ServerConfigDto.externalDomain` — empty when the server advertises none.
    let externalDomain: String

    var users: [UserResponseDto] = []
    var albums: [AlbumResponseDto] = []
    var selectedUserIds: Set<String> = []
    var albumName = ""
    var linkURL: String?
    var allowDownload = true
    var showMetadata = true
    var isBusy = false
    var errorMessage: String?
    var lastCreatedAlbumId: String?
    var lastAddedAlbumId: String?

    /// Test-visible capture of the exact payloads dispatched.
    private(set) var lastCreateAlbumDto: CreateAlbumDto?
    private(set) var lastAddAlbumId: String?
    private(set) var lastCreateLinkDto: SharedLinkCreateDto?

    init(asset: AssetReactItem, client: any ImmichClient, baseURL: URL, externalDomain: String = "") {
        self.asset = asset
        self.client = client
        self.baseURL = baseURL
        self.externalDomain = externalDomain
    }

    /// Albums that are shared (`shared == true`) — candidates for "add to an
    /// existing shared album".
    var sharedAlbums: [AlbumResponseDto] {
        albums.filter(\.shared)
    }

    /// Loads users (self excluded) + albums. Loads independently so a
    /// 403/admin-gated user list doesn't break the album flow.
    func load() async {
        isBusy = true
        do {
            users = try await client.getUsers().filter { $0.id != asset.ownerId }
        } catch let e {
            errorMessage = e.userFacingMessage
        }
        do {
            albums = try await client.getAlbums()
        } catch let e {
            errorMessage = e.userFacingMessage
        }
        isBusy = false
    }

    func toggleUser(_ id: String) {
        if selectedUserIds.contains(id) {
            selectedUserIds.remove(id)
        } else {
            selectedUserIds.insert(id)
        }
    }

    /// Creates a new album containing the photo, shared with the selected
    /// users as EDITORs (Immich ≥ 1.109).
    func createSharedAlbum() async {
        let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !selectedUserIds.isEmpty else { return }
        isBusy = true
        errorMessage = nil
        do {
            let dto = CreateAlbumDto(
                albumName: trimmed,
                description: nil,
                assetIds: [asset.id],
                albumUsers: selectedUserIds.map { AlbumUserDto(userId: $0, role: .editor) }
            )
            lastCreateAlbumDto = dto
            let album = try await client.createAlbum(dto: dto)
            lastCreatedAlbumId = album.id
            albumName = ""
            selectedUserIds = []
        } catch let e {
            errorMessage = e.userFacingMessage
        }
        isBusy = false
    }

    /// Adds the photo to an existing (shared) album.
    func addToAlbum(id: String) async {
        isBusy = true
        errorMessage = nil
        do {
            lastAddAlbumId = id
            _ = try await client.addAssetsToAlbum(albumId: id, dto: BulkIdsDto(ids: [asset.id]))
            lastAddedAlbumId = id
        } catch let e {
            errorMessage = e.userFacingMessage
        }
        isBusy = false
    }

    /// Creates an INDIVIDUAL public link honoring the permission toggles.
    func createPublicLink() async {
        isBusy = true
        errorMessage = nil
        do {
            let dto = SharedLinkCreateDto(
                type: .individual,
                assetIds: [asset.id],
                allowDownload: allowDownload,
                showMetadata: showMetadata
            )
            lastCreateLinkDto = dto
            let link = try await client.createSharedLink(dto: dto)
            // Same builder as the Shared tab: a server behind a reverse proxy
            // must hand out its public domain, not the address the app dials.
            linkURL = SharedLinkURL(serverURL: baseURL, externalDomain: externalDomain)
                .urlString(slug: link.slug, key: link.key)
        } catch let e {
            errorMessage = e.userFacingMessage
        }
        isBusy = false
    }
}
