import XCTest
@testable import ImmichSwiftUI

@MainActor
final class AlbumsTests: XCTestCase {

    private struct Boom: Error {}

    // MARK: - Helpers

    private func makeAlbum(id: String, name: String = "Album", count: Int = 0) -> AlbumResponseDto {
        AlbumResponseDto(
            id: id, albumName: name, description: "", createdAt: "2024-01-01T00:00:00.000Z",
            updatedAt: "2024-01-01T00:00:00.000Z", albumThumbnailAssetId: nil, shared: false,
            hasSharedLink: false, assetCount: count, isActivityEnabled: false, order: nil
        )
    }

    private func makeAssetResponseDto(id: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T00:00:00.000Z", ownerId: "owner", originalPath: "/x.jpg",
            originalFileName: "x.jpg", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z", updatedAt: "2024-07-01T00:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    private func makeSearchResponse(ids: [String]) -> SearchResponseDto {
        SearchResponseDto(assets: SearchAssetResponseDto(
            count: ids.count,
            items: ids.map { makeAssetResponseDto(id: $0) },
            nextPage: nil
        ))
    }

    private func makeSharedLink(id: String, password: String? = nil) -> SharedLinkResponseDto {
        SharedLinkResponseDto(
            id: id, description: nil, password: password, userId: "owner", key: "k\(id)",
            type: .album, createdAt: "2024-01-01T00:00:00.000Z", expiresAt: nil,
            assets: [], album: nil, allowUpload: false, allowDownload: true,
            showMetadata: true, slug: nil
        )
    }

    // MARK: - AC-506 AlbumsViewModel.load

    func test_AC_506_load_success() async {
        let mock = MockImmichClient()
        mock.albumsResponse = [makeAlbum(id: "a1"), makeAlbum(id: "a2"), makeAlbum(id: "a3")]
        let vm = AlbumsViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.albums.count, 3)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.loadErrorMessage)
    }

    func test_AC_506b_load_error() async {
        let mock = MockImmichClient()
        mock.albumsError = Boom()
        let vm = AlbumsViewModel(client: mock)
        await vm.load()
        XCTAssertTrue(vm.albums.isEmpty)
        XCTAssertNotNil(vm.loadErrorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - AC-507 AlbumsViewModel.createAlbum

    func test_AC_507_createAlbum_success() async {
        let mock = MockImmichClient()
        let vm = AlbumsViewModel(client: mock)
        await vm.createAlbum(name: "Test", description: "Desc", assetIds: ["x", "y"])
        XCTAssertEqual(vm.albums.count, 1)
        XCTAssertEqual(mock.lastCreateAlbumDto?.albumName, "Test")
        XCTAssertEqual(mock.lastCreateAlbumDto?.description, "Desc")
        XCTAssertEqual(mock.lastCreateAlbumDto?.assetIds, ["x", "y"])
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_507b_createAlbum_error() async {
        let mock = MockImmichClient()
        mock.createAlbumError = Boom()
        let vm = AlbumsViewModel(client: mock)
        await vm.createAlbum(name: "Test")
        XCTAssertTrue(vm.albums.isEmpty)
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    func test_AC_507c_createAlbum_emptyNameRejected() async {
        let mock = MockImmichClient()
        let vm = AlbumsViewModel(client: mock)
        await vm.createAlbum(name: "   ")
        XCTAssertTrue(vm.albums.isEmpty)
        XCTAssertNotNil(vm.actionErrorMessage)
        XCTAssertNil(mock.lastCreateAlbumDto) // no server call
    }

    // MARK: - AC-508 AlbumDetailViewModel.load

    func test_AC_508_detailLoad_success() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", name: "Holiday", count: 2)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["asset-1", "asset-2"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        XCTAssertEqual(vm.album?.albumName, "Holiday")
        XCTAssertEqual(vm.assets.count, 2)
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertEqual(mock.lastMetadataSearchDto?.albumIds, ["alb"]) // FM-2 dispatch via albumIds
    }

    func test_AC_508b_detailLoad_albumError() async {
        let mock = MockImmichClient()
        mock.getAlbumError = Boom()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        XCTAssertNil(vm.album)
        XCTAssertTrue(vm.assets.isEmpty)
        XCTAssertNotNil(vm.loadErrorMessage)
    }

    func test_AC_508c_detailLoad_assetsError() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", name: "Holiday")]
        mock.searchMetadataError = Boom()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        // Album populated (phase 1 success), assets empty (phase 2 throw).
        XCTAssertNotNil(vm.album)
        XCTAssertEqual(vm.album?.albumName, "Holiday")
        XCTAssertTrue(vm.assets.isEmpty)
        XCTAssertNotNil(vm.loadErrorMessage)
    }

    // MARK: - AC-509 addAssets

    func test_AC_509_addAssets_success() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb")]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.addAssets(ids: ["new-1", "new-2"])
        XCTAssertEqual(mock.lastAddAssetsAlbumId, "alb")
        XCTAssertEqual(mock.lastAddAssetsIds, ["new-1", "new-2"])
        XCTAssertEqual(vm.assets.count, 2) // refreshed from server
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_509b_addAssets_error() async {
        let mock = MockImmichClient()
        mock.addAssetsError = Boom()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.addAssets(ids: ["new-1"])
        XCTAssertTrue(vm.assets.isEmpty)
        XCTAssertEqual(mock.lastAddAssetsAlbumId, "alb")
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    // MARK: - AC-510 removeAssets

    func test_AC_510_removeAssets_success() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", count: 3)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2", "a3"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        XCTAssertEqual(vm.assets.count, 3)
        await vm.removeAssets(ids: ["a2"])
        XCTAssertEqual(mock.lastRemoveAssetsAlbumId, "alb")
        XCTAssertEqual(mock.lastRemoveAssetsIds, ["a2"])
        XCTAssertEqual(vm.assets.count, 2)
        XCTAssertFalse(vm.assets.contains { $0.id == "a2" })
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_510b_removeAssets_error() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb")]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2"])
        mock.removeAssetsError = Boom()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        let countBefore = vm.assets.count
        await vm.removeAssets(ids: ["a1"])
        XCTAssertEqual(vm.assets.count, countBefore) // unchanged on error
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    // MARK: - AC-511 deleteAlbum

    func test_AC_511_deleteAlbum_success() async {
        let mock = MockImmichClient()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.deleteAlbum()
        XCTAssertEqual(mock.deleteAlbumCallCount, 1)
        XCTAssertEqual(mock.lastDeletedAlbumId, "alb")
        XCTAssertTrue(vm.isDeleted)
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_511b_deleteAlbum_error() async {
        let mock = MockImmichClient()
        mock.deleteAlbumError = Boom()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.deleteAlbum()
        XCTAssertFalse(vm.isDeleted)
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    // MARK: - AC-512 createSharedLink

    func test_AC_512_createSharedLink_noPassword() async {
        let mock = MockImmichClient()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.createSharedLink(password: nil, description: nil)
        XCTAssertEqual(mock.lastCreateSharedLinkDto?.type, .album)
        XCTAssertEqual(mock.lastCreateSharedLinkDto?.albumId, "alb")
        XCTAssertNil(mock.lastCreateSharedLinkDto?.password)
        XCTAssertEqual(vm.sharedLinks.count, 1)
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_512b_createSharedLink_withPassword() async {
        let mock = MockImmichClient()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.createSharedLink(password: "secret", description: "Trip")
        XCTAssertEqual(mock.lastCreateSharedLinkDto?.password, "secret")
        XCTAssertEqual(mock.lastCreateSharedLinkDto?.description, "Trip")
        XCTAssertEqual(vm.sharedLinks.count, 1)
    }

    // MARK: - AC-513 load + revoke shared links

    func test_AC_513_loadRevokeSharedLinks() async {
        let mock = MockImmichClient()
        mock.sharedLinksResponse = [makeSharedLink(id: "link-1"), makeSharedLink(id: "link-2")]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.loadSharedLinks()
        XCTAssertEqual(vm.sharedLinks.count, 2)
        XCTAssertEqual(mock.lastSharedLinksAlbumId, "alb")

        await vm.revokeSharedLink(id: "link-1")
        XCTAssertEqual(mock.lastDeleteSharedLinkId, "link-1")
        XCTAssertEqual(vm.sharedLinks.count, 1)
        XCTAssertFalse(vm.sharedLinks.contains { $0.id == "link-1" })
    }

    // MARK: - AC-1091 update shared link

    func test_updateSharedLink_sendsDtoAndReplacesRow() async {
        let mock = MockImmichClient()
        mock.sharedLinksResponse = [makeSharedLink(id: "link-1")]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.loadSharedLinks()

        let updated = makeSharedLink(id: "link-1", password: "x")
        mock.updateSharedLinkResponse = updated
        let dto = SharedLinkEditDto(
            password: "x", expiresAt: nil, allowUpload: true,
            allowDownload: true, showMetadata: false, description: "Edited"
        )
        let ok = await vm.updateSharedLink(id: "link-1", dto: dto)

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastUpdateSharedLinkId, "link-1")
        XCTAssertEqual(mock.lastUpdateSharedLinkDto, dto)
        XCTAssertEqual(vm.sharedLinks[0].password, "x", "row replaced with server response")
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_updateSharedLink_failure_keepsRow() async {
        let mock = MockImmichClient()
        mock.sharedLinksResponse = [makeSharedLink(id: "link-1")]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.loadSharedLinks()
        mock.sharedLinksError = Boom()

        let ok = await vm.updateSharedLink(id: "link-1", dto: SharedLinkEditDto())

        XCTAssertFalse(ok)
        XCTAssertEqual(vm.sharedLinks.count, 1, "failed edit must keep the row")
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    // MARK: - AC-1100 update album details

    func test_updateAlbumDetails_sendsDtoAndUpdatesAlbum() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", name: "Old Name")]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        XCTAssertEqual(vm.album?.albumName, "Old Name")

        let ok = await vm.updateAlbumDetails(name: "New Name", description: "Trip", isActivityEnabled: true)

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastUpdateAlbumId, "alb")
        XCTAssertEqual(mock.lastUpdateAlbumDto?.albumName, "New Name")
        XCTAssertEqual(mock.lastUpdateAlbumDto?.description, "Trip")
        XCTAssertEqual(mock.lastUpdateAlbumDto?.isActivityEnabled, true)
        XCTAssertEqual(vm.album?.albumName, "New Name", "album replaced with server response")
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_updateAlbumDetails_failure_keepsAlbum() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", name: "Old Name")]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        mock.updateAlbumError = Boom()

        let ok = await vm.updateAlbumDetails(name: "New Name", description: nil, isActivityEnabled: nil)

        XCTAssertFalse(ok)
        XCTAssertEqual(vm.album?.albumName, "Old Name", "failed edit must keep the album")
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    // MARK: - AC-717 AlbumsViewModel.addAssets (V1.5 polish — no searchMetadata round-trip)

    func test_AC_717_addAssets_albumsVM_success() async {
        let mock = MockImmichClient()
        let vm = AlbumsViewModel(client: mock)
        await vm.addAssets(ids: ["a-1", "a-2"], toAlbumId: "alb-7")
        XCTAssertEqual(mock.lastAddAssetsAlbumId, "alb-7")
        XCTAssertEqual(mock.lastAddAssetsIds, ["a-1", "a-2"])
        XCTAssertNil(vm.actionErrorMessage)
        // V1.5 guarantee: picker path does NOT trigger a wasted searchMetadata call.
        XCTAssertNil(mock.lastMetadataSearchDto)
    }

    func test_AC_717b_addAssets_albumsVM_error() async {
        let mock = MockImmichClient()
        mock.addAssetsError = Boom()
        let vm = AlbumsViewModel(client: mock)
        await vm.addAssets(ids: ["a-1"], toAlbumId: "alb-7")
        XCTAssertEqual(mock.lastAddAssetsAlbumId, "alb-7")
        XCTAssertEqual(mock.lastAddAssetsIds, ["a-1"])
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    func test_AC_717c_addAssets_albumsVM_clearsStaleActionErrorMessage() async {
        // SUG-1 challenger amendment: a stale action error must not cause the picker to
        // falsely report an add failure. addAssets clears actionErrorMessage before the API call,
        // so a successful add leaves actionErrorMessage nil.
        let mock = MockImmichClient()
        let vm = AlbumsViewModel(client: mock)
        // Seed a stale action error from a prior failed add.
        mock.addAssetsError = Boom()
        await vm.addAssets(ids: ["a-1"], toAlbumId: "alb-7")
        XCTAssertNotNil(vm.actionErrorMessage, "precondition: stale action error seeded")
        // Now perform a successful add — action error must be cleared.
        mock.addAssetsError = nil
        await vm.addAssets(ids: ["a-1"], toAlbumId: "alb-7")
        XCTAssertEqual(mock.lastAddAssetsAlbumId, "alb-7")
        XCTAssertNil(vm.actionErrorMessage, "successful add must clear stale action error")
    }

    func test_AC_717d_addAssets_albumsVM_emptyIdsNoOp() async {
        let mock = MockImmichClient()
        let vm = AlbumsViewModel(client: mock)
        await vm.addAssets(ids: [], toAlbumId: "alb-7")
        XCTAssertNil(mock.lastAddAssetsAlbumId)
        XCTAssertNil(mock.lastAddAssetsIds)
    }

    // MARK: - AC-520 AlbumDetailViewModel selection mode

    func test_AC_520_selectionState() async {
        let mock = MockImmichClient()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)

        vm.enterSelectionMode()
        XCTAssertTrue(vm.selectionMode)
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")
        vm.toggleSelection(id: "a1") // toggle off
        XCTAssertEqual(vm.selectedIds, ["a2"])

        vm.exitSelectionMode()
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty, "exit clears selection")
    }

    func test_AC_520b_removeSelected_success() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", count: 3)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2", "a3"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a3")
        await vm.removeSelected()

        XCTAssertEqual(mock.lastRemoveAssetsAlbumId, "alb")
        XCTAssertEqual(Set(mock.lastRemoveAssetsIds ?? []), ["a1", "a3"])
        XCTAssertEqual(vm.assets.map(\.id), ["a2"])
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_520c_removeSelected_error() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb")]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2"])
        mock.removeAssetsError = Boom()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        await vm.removeSelected()

        // State preserved so the user can retry.
        XCTAssertEqual(vm.assets.count, 2)
        XCTAssertTrue(vm.selectionMode)
        XCTAssertEqual(vm.selectedIds, ["a1"])
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    func test_AC_520d_deleteSelected_success() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", count: 3)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2", "a3"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")
        await vm.deleteSelected()

        XCTAssertEqual(Set(mock.lastDeleteBody?.ids ?? []), ["a1", "a2"])
        XCTAssertEqual(mock.lastDeleteBody?.force, false)
        XCTAssertEqual(vm.assets.map(\.id), ["a3"])
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_520e_deleteSelected_error() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb")]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2"])
        mock.deleteError = Boom()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        await vm.deleteSelected()

        // State preserved so the user can retry.
        XCTAssertEqual(vm.assets.count, 2)
        XCTAssertTrue(vm.selectionMode)
        XCTAssertEqual(vm.selectedIds, ["a1"])
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    func test_AC_520f_batchSetFavorite() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", count: 3)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2", "a3"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")
        await vm.batchSetFavorite(vm.selectedIds, favorite: true)

        XCTAssertTrue(vm.assets.allSatisfy { $0.id == "a3" ? !$0.isFavorite : $0.isFavorite })
        // Set iteration order is nondeterministic — the mock only records the
        // last id, so just assert it was one of the selected ids.
        XCTAssertTrue(mock.lastUpdateAssetId == "a1" || mock.lastUpdateAssetId == "a2")
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_520g_load_clearsSelection() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb")]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        XCTAssertTrue(vm.selectionMode)

        await vm.load()
        XCTAssertFalse(vm.selectionMode, "reload starts selection-clean")
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    func test_AC_520h_bulkActions_emptySelectionNoOp() async {
        let mock = MockImmichClient()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.removeSelected()
        await vm.deleteSelected()
        XCTAssertNil(mock.lastRemoveAssetsAlbumId)
        XCTAssertNil(mock.lastDeleteBody)
    }

    // MARK: - AC-520i: removeAssets keeps the selection set consistent
    // (audit fix — stale "N selected" after context-menu remove)

    func test_AC_520i_removeAssets_clearsSelection() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", count: 3)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2", "a3"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")

        await vm.removeAssets(ids: ["a2"])

        XCTAssertEqual(vm.assets.map(\.id), ["a1", "a3"])
        XCTAssertEqual(vm.selectedIds, ["a1"], "removed asset leaves the selection set")
        XCTAssertTrue(vm.selectionMode, "context-menu remove does not exit selection mode")
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_520j_removeAssets_errorKeepsSelection() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", count: 3)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2", "a3"])
        mock.removeAssetsError = Boom()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        vm.enterSelectionMode()
        vm.toggleSelection(id: "a1")
        vm.toggleSelection(id: "a2")

        await vm.removeAssets(ids: ["a2"])

        XCTAssertEqual(vm.assets.count, 3, "no local mutation on throw")
        XCTAssertEqual(vm.selectedIds, ["a1", "a2"], "selection untouched on failure")
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    // MARK: - Cover change (setCover)

    func test_setCover_success_patchesThumbnail() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", count: 3)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2", "a3"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        let ok = await vm.setCover(assetId: "a2")

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastUpdateAlbumId, "alb")
        XCTAssertEqual(mock.lastUpdateAlbumDto?.albumThumbnailAssetId, "a2")
        XCTAssertEqual(vm.album?.albumThumbnailAssetId, "a2", "album must reflect the new cover on success")
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_setCover_error_keepsOldCover() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", count: 3)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1", "a2", "a3"])
        mock.updateAlbumError = Boom()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        let ok = await vm.setCover(assetId: "a2")

        XCTAssertFalse(ok)
        XCTAssertEqual(mock.lastUpdateAlbumId, "alb")
        XCTAssertNil(vm.album?.albumThumbnailAssetId, "cover must not change on error")
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    func test_setCover_nonMemberNoOp() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb")]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["a1"])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        let ok = await vm.setCover(assetId: "ghost")

        XCTAssertFalse(ok)
        XCTAssertNil(mock.lastUpdateAlbumId, "non-member asset must not dispatch a PATCH")
    }

    func test_refreshAlbum_updatesMetadataWithoutSpinner() async {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", name: "Old")]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        XCTAssertFalse(vm.isLoading, "load() must leave the spinner off")

        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", name: "Renamed")]
        await vm.refreshAlbum()

        XCTAssertEqual(vm.album?.albumName, "Renamed")
        XCTAssertFalse(vm.isLoading, "refresh must not flip the skeleton spinner")
        XCTAssertNil(vm.loadErrorMessage)
    }

    func test_makeShareViewModel_seedsCurrentMembership() async {
        let mock = MockImmichClient()
        let member = AlbumUserResponseDto(user: makeShareUser(), role: .editor)
        var shared = makeAlbum(id: "alb")
        shared.albumUsers = [member]
        mock.getAlbumResponse = ["alb": shared]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        let seeded = vm.makeShareViewModel(currentUserId: "owner", isAdmin: true)
        XCTAssertEqual(seeded.role(for: "u1"), .editor)
        XCTAssertNil(seeded.role(for: "owner"), "current user must never be listed")
        XCTAssertTrue(seeded.isAdmin, "isAdmin must propagate from the caller")
    }

    private func makeShareUser() -> UserResponseDto {
        UserResponseDto(
            id: "u1", name: "Alice", email: "alice@example.com",
            profileImagePath: "", avatarColor: "#FF0000", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    // MARK: - AC-8 / AC-1 — two error channels, cancellation is silent

    func test_AC8_userActionFailureSetsActionErrorOnly() async {
        let mock = MockImmichClient()
        mock.createAlbumError = Boom()
        let vm = AlbumsViewModel(client: mock)
        await vm.createAlbum(name: "Test")
        XCTAssertEqual(vm.actionErrorMessage, UserFacingError.genericMessage)
        XCTAssertNil(vm.loadErrorMessage)
    }

    func test_AC8_backgroundRefreshFailureSetsLoadErrorOnly() async {
        let mock = MockImmichClient()
        mock.albumsError = URLError(.notConnectedToInternet)
        let vm = AlbumsViewModel(client: mock)
        await vm.refresh()
        XCTAssertEqual(vm.loadErrorMessage, UserFacingError.offlineMessage)
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC1_cancelledAlbumsRefreshIsSilent() async {
        let mock = MockImmichClient()
        mock.albumsError = URLError(.cancelled)
        let vm = AlbumsViewModel(client: mock)
        await vm.refresh()
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertNil(vm.actionErrorMessage)
    }
}
