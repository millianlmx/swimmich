import XCTest
@testable import ImmichSwiftUI

@MainActor
final class AlbumDetailViewModelTests: XCTestCase {

    private struct Boom: Error {}

    // MARK: - Fixtures

    private func makeUser(id: String) -> UserResponseDto {
        UserResponseDto(
            id: id, name: "User \(id)", email: "\(id)@example.com",
            profileImagePath: "", avatarColor: "#FF0000", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    private func makeAlbum(
        ownerId: String? = nil,
        users: [(String, AlbumUserRole)] = []
    ) -> AlbumResponseDto {
        AlbumResponseDto(
            id: "alb", albumName: "Album", description: "", createdAt: "2024-01-01T00:00:00.000Z",
            updatedAt: "2024-01-01T00:00:00.000Z", albumThumbnailAssetId: nil, shared: true,
            hasSharedLink: false, assetCount: 0, isActivityEnabled: false, order: nil,
            albumUsers: users.map { AlbumUserResponseDto(user: makeUser(id: $0.0), role: $0.1) },
            ownerId: ownerId
        )
    }

    private func makeAsset(id: String, ownerId: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T00:00:00.000Z", ownerId: ownerId, originalPath: "/x.jpg",
            originalFileName: "x.jpg", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z", updatedAt: "2024-07-01T00:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    /// Loads a VM on `album` with `assets` given as (id, ownerId).
    private func makeLoadedVM(
        album: AlbumResponseDto,
        assets: [(String, String)] = [],
        mock: MockImmichClient = MockImmichClient()
    ) async -> (AlbumDetailViewModel, MockImmichClient) {
        mock.getAlbumResponse = ["alb": album]
        mock.searchMetadataResponse = SearchResponseDto(assets: SearchAssetResponseDto(
            count: assets.count,
            items: assets.map { makeAsset(id: $0.0, ownerId: $0.1) },
            nextPage: nil
        ))
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        return (vm, mock)
    }

    private func role(_ userId: String?, _ album: AlbumResponseDto) -> AlbumUserRole {
        AlbumDetailPermissions(album: album, userId: userId).role
    }

    private let ownerOnlyActions: Set<AlbumDetailAction> = [.editAlbum, .setCover, .deleteAlbum, .sharedWith]

    // MARK: - Role (AC-1..AC-9)

    func test_AC_1_role_v3_ownerFirst_meViewer() {
        XCTAssertEqual(role("me", makeAlbum(users: [("a", .owner), ("me", .viewer)])), .viewer)
    }

    func test_AC_2_role_v3_reversedOrder_meViewer() {
        XCTAssertEqual(role("me", makeAlbum(users: [("me", .viewer), ("a", .owner)])), .viewer)
    }

    func test_AC_3_role_v3_meOwnerNotFirst() {
        XCTAssertEqual(role("me", makeAlbum(users: [("a", .editor), ("me", .owner)])), .owner)
    }

    func test_AC_4_role_v2_ownerIdIsMe() {
        XCTAssertEqual(role("me", makeAlbum(ownerId: "me", users: [("c", .editor)])), .owner)
    }

    func test_AC_5_role_v2_meViewer() {
        XCTAssertEqual(role("me", makeAlbum(ownerId: "a", users: [("c", .editor), ("me", .viewer)])), .viewer)
    }

    func test_AC_6_role_v2_meEditor() {
        XCTAssertEqual(role("me", makeAlbum(ownerId: "a", users: [("c", .viewer), ("me", .editor)])), .editor)
    }

    func test_AC_7_role_notMember_viewer() {
        XCTAssertEqual(role("me", makeAlbum(ownerId: "a", users: [("c", .editor)])), .viewer)
        XCTAssertEqual(role("me", makeAlbum(users: [("a", .owner)])), .viewer)
    }

    func test_AC_8_role_noUserId_viewer() {
        let album = makeAlbum(ownerId: "", users: [("", .owner)])
        XCTAssertEqual(role(nil, album), .viewer)
        XCTAssertEqual(role("", album), .viewer)
    }

    func test_AC_9_decode_withAndWithoutOwnerId() throws {
        func json(_ extra: String) -> Data {
            Data("""
            {"id":"alb","albumName":"A","description":"","createdAt":"2024-01-01T00:00:00.000Z",
            "updatedAt":"2024-01-01T00:00:00.000Z","shared":true,"hasSharedLink":false,
            "assetCount":0,"isActivityEnabled":false,"albumUsers":[]\(extra)}
            """.utf8)
        }
        let with = try JSONDecoder().decode(AlbumResponseDto.self, from: json(#","ownerId":"u-a""#))
        let without = try JSONDecoder().decode(AlbumResponseDto.self, from: json(""))
        XCTAssertEqual(with.ownerId, "u-a")
        XCTAssertNil(without.ownerId)
    }

    func test_AC_10_permissionsFollowFallbackThenLoadThenRefresh() async {
        let mock = MockImmichClient()
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        let asOwner = makeAlbum(ownerId: "me")
        let asViewer = makeAlbum(ownerId: "a", users: [("me", .viewer)])

        XCTAssertEqual(vm.permissions(currentUserId: "me", fallback: asOwner).role, .owner)
        XCTAssertEqual(
            vm.allowedActions(on: .albumMenu, currentUserId: "me", fallback: asOwner),
            [.editAlbum, .sharedWith, .deleteAlbum]
        )

        mock.getAlbumResponse = ["alb": asViewer]
        await vm.load()
        XCTAssertEqual(vm.permissions(currentUserId: "me", fallback: asOwner).role, .viewer)
        XCTAssertTrue(vm.allowedActions(on: .albumMenu, currentUserId: "me", fallback: asOwner).isEmpty)

        mock.getAlbumResponse = ["alb": asOwner]
        await vm.refreshAlbum()
        XCTAssertEqual(vm.permissions(currentUserId: "me", fallback: asViewer).role, .owner)
        XCTAssertEqual(
            vm.allowedActions(on: .albumMenu, currentUserId: "me", fallback: asViewer),
            [.editAlbum, .sharedWith, .deleteAlbum]
        )
    }

    // MARK: - Predicate (AC-11, AC-13..AC-16)

    func test_AC_11_viewerAndEditor_noOwnerActions() {
        for role in [AlbumUserRole.viewer, .editor] {
            let p = AlbumDetailPermissions(album: makeAlbum(ownerId: "a", users: [("me", role)]), userId: "me")
            XCTAssertEqual(p.role, role)
            for surface in [AlbumDetailSurface.albumMenu, .selectionBar, .selectionMenu, .assetContextMenu] {
                let actions = p.allowedActions(on: surface, ownedSelectionCount: 3)
                XCTAssertTrue(actions.isDisjoint(with: ownerOnlyActions), "\(role) \(surface)")
            }
        }
    }

    func test_AC_13_owner_allOwnerActions() {
        let p = AlbumDetailPermissions(album: makeAlbum(ownerId: "me"), userId: "me")
        XCTAssertEqual(p.allowedActions(on: .albumMenu), [.editAlbum, .sharedWith, .deleteAlbum])
        XCTAssertTrue(p.allowedActions(on: .selectionBar).contains(.setCover))
        XCTAssertTrue(p.allowedActions(on: .assetContextMenu).contains(.setCover))
    }

    func test_AC_14_viewer_noAddNoRemove() {
        let p = AlbumDetailPermissions(album: makeAlbum(ownerId: "a", users: [("me", .viewer)]), userId: "me")
        XCTAssertFalse(p.canAddAssets)
        XCTAssertFalse(p.canRemoveAssets)
        XCTAssertFalse(p.allowedActions(on: .selectionMenu, ownedSelectionCount: 2).contains(.removeFromAlbum))
        XCTAssertFalse(p.allowedActions(on: .assetContextMenu).contains(.removeFromAlbum))
    }

    func test_AC_15_viewer_contextMenuEmpty() {
        let p = AlbumDetailPermissions(album: makeAlbum(ownerId: "a", users: [("me", .viewer)]), userId: "me")
        XCTAssertTrue(p.allowedActions(on: .assetContextMenu).isEmpty)
    }

    func test_AC_16_ownerAndEditor_canAddAndRemove() {
        let owner = AlbumDetailPermissions(album: makeAlbum(ownerId: "me"), userId: "me")
        let editor = AlbumDetailPermissions(album: makeAlbum(ownerId: "a", users: [("me", .editor)]), userId: "me")
        for p in [owner, editor] {
            XCTAssertTrue(p.canAddAssets)
            XCTAssertTrue(p.canRemoveAssets)
            XCTAssertTrue(p.allowedActions(on: .selectionMenu).contains(.removeFromAlbum))
            XCTAssertTrue(p.allowedActions(on: .assetContextMenu).contains(.removeFromAlbum))
        }
    }

    // MARK: - Owned deletion (AC-17..AC-22, AC-24..AC-26)

    private let viewerAlbum: AlbumResponseDto = {
        AlbumResponseDto(
            id: "alb", albumName: "Album", description: "", createdAt: "2024-01-01T00:00:00.000Z",
            updatedAt: "2024-01-01T00:00:00.000Z", albumThumbnailAssetId: nil, shared: true,
            hasSharedLink: false, assetCount: 0, isActivityEnabled: false, order: nil,
            albumUsers: [AlbumUserResponseDto(
                user: UserResponseDto(
                    id: "me", name: "Me", email: "me@example.com", profileImagePath: "",
                    avatarColor: "#FF0000", profileChangedAt: "2024-01-01T00:00:00.000Z"
                ),
                role: .viewer
            )],
            ownerId: "a"
        )
    }()

    private func makeMixedVM() async -> (AlbumDetailViewModel, MockImmichClient) {
        let (vm, mock) = await makeLoadedVM(
            album: makeAlbum(ownerId: "me"),
            assets: [("p1", "me"), ("p2", "other"), ("p3", "me")]
        )
        vm.enterSelectionMode()
        for id in ["p1", "p2", "p3"] { vm.toggleSelection(id: id) }
        return (vm, mock)
    }

    func test_AC_17_ownedSelectedIds_countsOnlyMine() async {
        let (vm, _) = await makeMixedVM()
        XCTAssertEqual(vm.ownedSelectedIds(currentUserId: "me"), ["p1", "p3"])
        XCTAssertEqual(vm.selectedIds.count, 3)
    }

    func test_AC_18_deleteSelected_sendsOnlyMine() async {
        let (vm, mock) = await makeMixedVM()
        let before = mock.requestCount
        await vm.deleteSelected(currentUserId: "me")
        XCTAssertEqual(mock.requestCount, before + 1)
        XCTAssertEqual(Set(mock.lastDeleteBody?.ids ?? []), ["p1", "p3"])
        XCTAssertEqual(mock.lastDeleteBody?.ids.count, 2)
        XCTAssertEqual(mock.lastDeleteBody?.force, false)
        XCTAssertEqual(vm.assets.map(\.id), ["p2"])
    }

    func test_AC_19_noOwnedPhoto_deleteNotAllowedNoRequest() async {
        let (vm, mock) = await makeLoadedVM(
            album: makeAlbum(ownerId: "me"),
            assets: [("p1", "other"), ("p2", "")]
        )
        vm.enterSelectionMode()
        vm.toggleSelection(id: "p1")
        vm.toggleSelection(id: "p2")
        XCTAssertEqual(
            vm.allowedActions(on: .selectionMenu, currentUserId: "me", fallback: makeAlbum()),
            [.removeFromAlbum]
        )
        let before = mock.requestCount
        let removed = await vm.deleteSelected(currentUserId: "me")
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(mock.requestCount, before)
        XCTAssertNil(mock.lastDeleteBody)
        XCTAssertEqual(vm.assets.count, 2)
        XCTAssertEqual(vm.selectedIds, ["p1", "p2"])
        XCTAssertTrue(vm.selectionMode)
    }

    func test_AC_20_viewerWithOwnPhoto_deleteAllowed() async {
        let (vm, _) = await makeLoadedVM(album: viewerAlbum, assets: [("p1", "me"), ("p2", "other")])
        vm.enterSelectionMode()
        vm.toggleSelection(id: "p1")
        XCTAssertEqual(vm.permissions(currentUserId: "me", fallback: viewerAlbum).role, .viewer)
        XCTAssertTrue(
            vm.allowedActions(on: .selectionMenu, currentUserId: "me", fallback: viewerAlbum).contains(.deleteAssets)
        )
    }

    func test_AC_21_deleteSelected_errorKeepsState() async {
        let (vm, mock) = await makeMixedVM()
        mock.deleteError = Boom()
        let removed = await vm.deleteSelected(currentUserId: "me")
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(vm.assets.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(vm.selectedIds, ["p1", "p2", "p3"])
        XCTAssertTrue(vm.selectionMode)
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    func test_AC_22_deleteSelected_returnsRemovedIds() async {
        let (vm, _) = await makeMixedVM()
        let removed = await vm.deleteSelected(currentUserId: "me")
        XCTAssertEqual(removed, ["p1", "p3"])
        XCTAssertFalse(vm.selectionMode)
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_AC_22_removeLocally_ignoresIdsNotInAssets() async {
        let (vm, _) = await makeLoadedVM(
            album: makeAlbum(ownerId: "me"),
            assets: [("p1", "me"), ("p2", "me")]
        )
        let removed = vm.removeLocally(["p1", "ghost"])
        XCTAssertEqual(removed, ["p1"])
        XCTAssertEqual(vm.assets.map(\.id), ["p2"])
    }

    func test_AC_24_noUserId_deleteNotAllowedNoRequest() async {
        let (vm, mock) = await makeMixedVM()
        for userId in [nil, ""] as [String?] {
            XCTAssertFalse(
                vm.allowedActions(on: .selectionMenu, currentUserId: userId, fallback: makeAlbum())
                    .contains(.deleteAssets)
            )
            let before = mock.requestCount
            let removed = await vm.deleteSelected(currentUserId: userId)
            XCTAssertTrue(removed.isEmpty)
            XCTAssertEqual(mock.requestCount, before)
        }
        XCTAssertNil(mock.lastDeleteBody)
        XCTAssertEqual(vm.assets.count, 3)
    }

    func test_AC_25_deleteSelected_skipsIdsNotInAssets() async {
        let (vm, mock) = await makeLoadedVM(
            album: makeAlbum(ownerId: "me"),
            assets: [("p1", "me"), ("p2", "other")]
        )
        vm.enterSelectionMode()
        vm.toggleSelection(id: "p1")
        vm.toggleSelection(id: "ghost")
        await vm.deleteSelected(currentUserId: "me")
        XCTAssertEqual(mock.lastDeleteBody?.ids, ["p1"])
    }

    func test_AC_26_viewer_selectionMenuEmptyThenDeleteOnly() async {
        let (vm, _) = await makeLoadedVM(album: viewerAlbum, assets: [("p1", "other"), ("p2", "me")])
        vm.enterSelectionMode()
        vm.toggleSelection(id: "p1")
        XCTAssertTrue(vm.allowedActions(on: .selectionMenu, currentUserId: "me", fallback: viewerAlbum).isEmpty)
        vm.toggleSelection(id: "p2")
        XCTAssertEqual(
            vm.allowedActions(on: .selectionMenu, currentUserId: "me", fallback: viewerAlbum),
            [.deleteAssets]
        )
    }
}
