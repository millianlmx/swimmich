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

    // AC-64 / AC-806: the album's link sheet bumps its own tick, on success only.
    func test_AC_64_albumRevokeSuccessBumpsFeedback() async {
        let mock = MockImmichClient()
        mock.sharedLinksResponse = [makeSharedLink(id: "link-1"), makeSharedLink(id: "link-2")]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.loadSharedLinks()
        XCTAssertEqual(vm.sharedLinkRevokeFeedbackTick, 0)

        let ok = await vm.revokeSharedLink(id: "link-1")
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.sharedLinkRevokeFeedbackTick, 1)

        mock.deleteSharedLinkError = NSError(domain: "test", code: 500)
        let refused = await vm.revokeSharedLink(id: "link-2")
        XCTAssertFalse(refused)
        XCTAssertEqual(vm.sharedLinkRevokeFeedbackTick, 1, "a refused revocation plays nothing (AC-806)")
        XCTAssertEqual(vm.sharedLinks.map(\.id), ["link-2"])
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
        var album = makeAlbum(id: "alb", name: "Old Name")
        album.ownerId = "me"
        mock.getAlbumResponse = ["alb": album]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        XCTAssertEqual(vm.album?.albumName, "Old Name")

        let ok = await vm.updateAlbumDetails(name: "New Name", description: "Trip", isActivityEnabled: true, currentUserId: "me")

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
        var album = makeAlbum(id: "alb", name: "Old Name")
        album.ownerId = "me"
        mock.getAlbumResponse = ["alb": album]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        mock.updateAlbumError = Boom()

        let ok = await vm.updateAlbumDetails(name: "New Name", description: nil, isActivityEnabled: nil, currentUserId: "me")

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
        await vm.deleteSelected(currentUserId: "owner")

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
        await vm.deleteSelected(currentUserId: "owner")

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
        await vm.deleteSelected(currentUserId: "owner")
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

    // MARK: - Real client: duplicate add and partial removal (BulkIdResponseDto)

    override func tearDown() {
        CapturingURLProtocol.reset()
    }

    private func makeRealClient() -> ImmichAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let client = ImmichAPIClient(session: URLSession(configuration: config))
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        return client
    }

    private static let duplicateJSON = #"[{"id":"p1","success":false,"error":"duplicate"}]"#

    func test_AC_6_albumsVM_addDuplicate_realClient_noError() async {
        let vm = AlbumsViewModel(client: makeRealClient())
        CapturingURLProtocol.nextData = Data(Self.duplicateJSON.utf8)

        await vm.addAssets(ids: ["p1"], toAlbumId: "alb-1")

        XCTAssertNil(vm.actionErrorMessage)
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.url?.path, "/api/albums/alb-1/assets")
    }

    func test_AC_6_albumDetailVM_addDuplicate_realClient_refreshes() async {
        let vm = AlbumDetailViewModel(client: makeRealClient(), albumId: "alb-1")
        CapturingURLProtocol.nextData = Data(Self.duplicateJSON.utf8)
        CapturingURLProtocol.dataByPath["/api/search/metadata"] = Data(
            #"{"assets":{"count":0,"items":[],"nextPage":null}}"#.utf8
        )

        await vm.addAssets(ids: ["p1"])

        XCTAssertNil(vm.actionErrorMessage)
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.url?.path, "/api/search/metadata")
    }

    private static let partialRemovalJSON = """
    [{"id":"p1","success":true},
     {"id":"p2","success":false,"error":"no_permission"},
     {"id":"p3","success":false,"error":"not_found"}]
    """

    private func loadedDetailVM(removeResponse: [BulkIdResponseDto]) async -> (AlbumDetailViewModel, MockImmichClient) {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", count: 3)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["p1", "p2", "p3"])
        mock.removeAssetsResponse = removeResponse
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        return (vm, mock)
    }

    func test_AC_19_removeAssets_keepsRefusedIds() async throws {
        let results = try JSONDecoder.immich.decode([BulkIdResponseDto].self, from: Data(Self.partialRemovalJSON.utf8))
        let (vm, _) = await loadedDetailVM(removeResponse: results)

        await vm.removeAssets(ids: ["p1", "p2", "p3"])

        XCTAssertEqual(vm.assets.map(\.id), ["p2"])
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_19_removeSelected_keepsRefusedIds() async throws {
        let results = try JSONDecoder.immich.decode([BulkIdResponseDto].self, from: Data(Self.partialRemovalJSON.utf8))
        let (vm, _) = await loadedDetailVM(removeResponse: results)

        vm.enterSelectionMode()
        for id in ["p1", "p2", "p3"] { vm.toggleSelection(id: id) }
        await vm.removeSelected()

        XCTAssertEqual(vm.assets.map(\.id), ["p2"])
        XCTAssertFalse(vm.selectionMode)
        XCTAssertNil(vm.actionErrorMessage)
    }

    // MARK: - List states (L-16)

    private let serverError = APIError.serverError(500, "x")

    private func detailMock(ids: [String] = ["p1", "p2"], name: String = "Holiday") -> MockImmichClient {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", name: name, count: ids.count)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ids)
        return mock
    }

    func test_AC_142_albumDetail_loadingUntilFirstAnswer() async {
        let mock = detailMock()
        let latch = TestLatch()
        mock.getAlbumGate = { try await latch.wait() }
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        XCTAssertEqual(vm.albumState, .loading)

        let read = Task { @MainActor in await vm.load() }
        await pollUntil("album read in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.albumState, .loading)
        XCTAssertEqual(vm.assetsState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.albumState, .data(.idle))
        XCTAssertEqual(vm.assetsState, .data(.idle))
        XCTAssertTrue(vm.hasLoadedAssets)
    }

    func test_AC_142_albumDetail_photosLoadingWhileFirstPageIsInFlight() async {
        let mock = detailMock()
        let latch = TestLatch()
        mock.searchMetadataGate = { _ in try await latch.wait() }
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")

        let read = Task { @MainActor in await vm.load() }
        await pollUntil("page 1 in flight") { mock.requestCount == 2 }

        XCTAssertNotNil(vm.album)
        XCTAssertEqual(vm.assetsState, .loading, "never No Photos before the page arrived")
        latch.open()
        await read.value
        XCTAssertEqual(vm.assetsState, .data(.idle))
    }

    func test_AC_147_albumDetail_emptyAlbumIsNoPhotosState() async {
        let mock = detailMock(ids: [])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")

        await vm.load()

        XCTAssertEqual(vm.albumState, .data(.idle))
        XCTAssertEqual(vm.assetsState, .empty)
    }

    /// With no album and an error, the screen used to land on "Album
    /// Unavailable" once loading ended; it is now an error with a retry that
    /// reads again.
    func test_AC_151_albumDetail_unknownAlbumFailureIsRetryableError() async {
        let mock = detailMock()
        mock.getAlbumError = serverError
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")

        await vm.load()

        XCTAssertNil(vm.album)
        XCTAssertEqual(vm.albumState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.actionErrorMessage, "the read never writes the action error")

        // "Try Again": the read without a pull, held by a gate.
        mock.getAlbumError = nil
        let latch = TestLatch()
        mock.getAlbumGate = { try await latch.wait() }
        let before = mock.requestCount
        let retry = Task { @MainActor in await vm.reload() }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }
        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.albumState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.albumState, .data(.idle))
        XCTAssertEqual(vm.assets.map(\.id), ["p1", "p2"])
    }

    func test_AC_149_albumDetail_firstPageFailureIsPhotosErrorWithAlbumKept() async {
        let mock = detailMock()
        mock.searchMetadataError = serverError
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")

        await vm.load()

        XCTAssertEqual(vm.album?.albumName, "Holiday")
        XCTAssertEqual(vm.albumState, .data(.idle))
        XCTAssertEqual(vm.assetsState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoadedAssets)

        mock.searchMetadataError = nil
        await vm.reload()
        XCTAssertEqual(vm.assetsState, .data(.idle))
        XCTAssertTrue(vm.hasLoadedAssets)
    }

    func test_AC_152_albumDetail_refreshFailureKeepsPhotosThenRetryClears() async {
        let mock = detailMock()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        mock.searchMetadataError = serverError
        await vm.refresh()

        XCTAssertEqual(vm.assetsState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.assets.map(\.id), ["p1", "p2"])

        mock.searchMetadataError = nil
        await vm.reload()
        XCTAssertEqual(vm.assetsState, .data(.idle))

        // An album that fails to refresh keeps the album and the photos too.
        mock.getAlbumError = serverError
        await vm.refresh()
        XCTAssertEqual(vm.albumState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.album?.albumName, "Holiday")
        XCTAssertEqual(vm.assets.map(\.id), ["p1", "p2"])
    }

    func test_AC_154_albumDetail_refreshFromAlbumErrorKeepsErrorWhileReading() async {
        let mock = detailMock()
        mock.getAlbumError = serverError
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        XCTAssertEqual(vm.albumState, .error(UserFacingError.serverErrorMessage))

        let latch = TestLatch()
        mock.getAlbumGate = { try await latch.wait() }
        mock.getAlbumError = nil
        let before = mock.requestCount
        let pull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.albumState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        latch.open()
        await pull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.albumState, .data(.idle))
        XCTAssertEqual(vm.assetsState, .data(.idle))
    }

    func test_AC_154_albumDetail_refreshFromEmptyAndPhotosErrorReads() async {
        // From the empty state.
        let mock = detailMock(ids: [])
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        XCTAssertEqual(vm.assetsState, .empty)
        let emptyLatch = TestLatch()
        mock.searchMetadataGate = { _ in try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 2 }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.assetsState, .empty)
        mock.searchMetadataResponse = makeSearchResponse(ids: ["p1"])
        emptyLatch.open()
        await emptyPull.value
        XCTAssertEqual(vm.assetsState, .data(.idle))

        // From the photos error state.
        let failing = AlbumDetailViewModel(client: mock, albumId: "alb")
        mock.searchMetadataGate = nil
        mock.searchMetadataError = serverError
        await failing.load()
        XCTAssertEqual(failing.assetsState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        mock.searchMetadataGate = { _ in try await errorLatch.wait() }
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refresh() }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 2 }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.assetsState, .error(UserFacingError.serverErrorMessage))
        mock.searchMetadataError = nil
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.assetsState, .data(.idle))
    }

    func test_AC_154_albumDetail_refreshDuringReadIsNotIgnored() async {
        let mock = detailMock()
        let latch = TestLatch()
        let calls = TestBox(0)
        mock.getAlbumGate = {
            calls.value += 1
            if calls.value == 1 { try await latch.wait() }
        }
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")

        let first = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }
        await vm.refresh()
        XCTAssertEqual(mock.requestCount, 3, "a pull during a read is a read of its own (album + page 1)")
        XCTAssertEqual(vm.albumState, .data(.idle))
        XCTAssertEqual(vm.assetsState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.getAlbumError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.albumState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }

    /// A pull from the unknown-album error must not publish the album before
    /// page 1 has answered: the view would swap its scroll container (the one
    /// carrying `.refreshable`) and SwiftUI would cancel the pull's task.
    func test_AC_154_albumDetail_pullFromAlbumErrorPublishesAlbumOnlyAfterPageOne() async {
        let mock = detailMock()
        mock.getAlbumError = serverError
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        XCTAssertEqual(vm.albumState, .error(UserFacingError.serverErrorMessage))

        mock.getAlbumError = nil
        let latch = TestLatch()
        mock.searchMetadataGate = { _ in try await latch.wait() }
        let before = mock.requestCount
        let pull = Task { @MainActor in await vm.refresh() }
        await pollUntil("page 1 of the pull in flight") { mock.requestCount == before + 2 }

        XCTAssertNil(vm.album, "the error container stays until page 1 answered")
        XCTAssertEqual(vm.albumState, .error(UserFacingError.serverErrorMessage))
        latch.open()
        await pull.value

        XCTAssertEqual(vm.album?.albumName, "Holiday")
        XCTAssertEqual(vm.assets.map(\.id), ["p1", "p2"], "page 1 was not dropped")
        XCTAssertEqual(vm.albumState, .data(.idle))
        XCTAssertEqual(vm.assetsState, .data(.idle))
    }

    /// Same pull, page 1 failing: the album is published and the photos carry the error.
    func test_AC_154_albumDetail_pullFromAlbumErrorWithPageOneFailureKeepsAlbumAndPhotosError() async {
        let mock = detailMock()
        mock.getAlbumError = serverError
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        mock.getAlbumError = nil
        mock.searchMetadataError = serverError
        await vm.refresh()

        XCTAssertEqual(vm.album?.albumName, "Holiday")
        XCTAssertEqual(vm.albumState, .data(.idle))
        XCTAssertEqual(vm.assetsState, .error(UserFacingError.serverErrorMessage))
    }

    func test_AC_143_albumDetail_dataKeptDuringRefresh() async {
        let mock = detailMock()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        // Pull: photos stay, the system control is the indicator.
        let pullLatch = TestLatch()
        mock.searchMetadataGate = { _ in try await pullLatch.wait() }
        var before = mock.requestCount
        let pull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull page 1 in flight") { mock.requestCount == before + 2 }
        XCTAssertEqual(vm.assets.map(\.id), ["p1", "p2"])
        XCTAssertEqual(vm.assetsState, .data(.idle))
        pullLatch.open()
        await pull.value

        // "Try Again" with photos: they stay, an indicator stands in for the banner.
        let retryLatch = TestLatch()
        mock.searchMetadataGate = { _ in try await retryLatch.wait() }
        before = mock.requestCount
        let retry = Task { @MainActor in await vm.reload() }
        await pollUntil("retry page 1 in flight") { mock.requestCount == before + 2 }
        XCTAssertEqual(vm.assets.map(\.id), ["p1", "p2"])
        XCTAssertEqual(vm.assetsState, .data(.reloading))
        retryLatch.open()
        await retry.value
        XCTAssertEqual(vm.assetsState, .data(.idle))
    }

    func test_AC_156_albumDetail_refreshReadsAlbumAndFirstPage() async {
        let mock = detailMock(ids: ["p1"], name: "Old")
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        let before = mock.requestCount

        mock.getAlbumResponse = ["alb": makeAlbum(id: "alb", name: "Renamed", count: 2)]
        mock.searchMetadataResponse = makeSearchResponse(ids: ["p1", "p2"])
        await vm.refresh()

        XCTAssertEqual(mock.requestCount, before + 2, "album, then page 1")
        XCTAssertEqual(vm.album?.albumName, "Renamed")
        XCTAssertEqual(vm.assets.map(\.id), ["p1", "p2"])
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.assetsState, .data(.idle))
    }

    func test_AC_156_albumDetail_reloadKeepsSelectionModeWhileLoadLeavesIt() async {
        let mock = detailMock()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        vm.enterSelectionMode()
        vm.toggleSelection(id: "p1")

        await vm.reload()
        XCTAssertTrue(vm.selectionMode, "a Try Again does not drop the user's selection mode")

        await vm.load()
        XCTAssertFalse(vm.selectionMode, "the .task read starts clean")
    }

    func test_AC_149_albumDetail_cancelledReadChangesNothing() async {
        let mock = detailMock()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()

        mock.getAlbumError = URLError(.cancelled)
        await vm.refresh()

        XCTAssertEqual(vm.albumState, .data(.idle))
        XCTAssertEqual(vm.assetsState, .data(.idle))
        XCTAssertNil(vm.loadErrorMessage)
    }
}
