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

    // MARK: - Pagination (AC-1..AC-10, AC-23, AC-24)

    private func pgVM(
        album: AlbumResponseDto,
        pages: [Int: SearchResponseDto]
    ) async -> (AlbumDetailViewModel, MockImmichClient) {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": album]
        mock.searchMetadataResponsesByPage = pages
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        return (vm, mock)
    }

    /// VM backed by an offset server. `before` holds a request before the
    /// server reads its page, `after` holds it after (the page is already read).
    private func pgServerVM(
        _ server: PgOffsetServer,
        before: TestBox<TestLatch?> = TestBox(nil),
        after: TestBox<TestLatch?> = TestBox(nil)
    ) async -> (AlbumDetailViewModel, MockImmichClient) {
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": pgAlbum(order: nil, assetCount: server.ids.count)]
        mock.searchMetadataHandler = { dto in
            if let l = before.value { try await l.wait() }
            let response = server.page(dto.page ?? 1)
            if let l = after.value { try await l.wait() }
            return response
        }
        mock.removeAssetsFromAlbumGate = { dto in server.ids.removeAll { dto.ids.contains($0) } }
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        return (vm, mock)
    }

    func test_Pagination_AC_1_load_requestsOnlyFirstPage() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 3),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["c"], next: nil)]
        )
        XCTAssertEqual(mock.searchMetadataCalls.count, 1)
        let dto = mock.searchMetadataCalls[0]
        XCTAssertEqual(dto.page, 1)
        XCTAssertEqual(dto.size, 1000)
        XCTAssertEqual(dto.albumIds, ["alb"])
        XCTAssertNil(dto.filter)
        XCTAssertNil(dto.orderBy)
        XCTAssertNil(dto.cursor)
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b"])
        XCTAssertTrue(vm.hasMorePages)
        XCTAssertEqual(vm.gridFooter, .loadingMore)
    }

    func test_Pagination_AC_2_lastCellLoadsSecondPageThenStops() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 3),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["c"], next: nil)]
        )
        await vm.loadMoreIfNeeded(currentItemId: "a")
        XCTAssertEqual(mock.searchMetadataCalls.count, 1)
        await vm.loadMoreIfNeeded(currentItemId: "b")
        XCTAssertEqual(mock.searchMetadataCalls.count, 2)
        XCTAssertEqual(mock.searchMetadataCalls[1].page, 2)
        XCTAssertEqual(mock.searchMetadataCalls[1].albumIds, ["alb"])
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(vm.hasMorePages)
        XCTAssertEqual(vm.gridFooter, .none)
        await vm.loadMoreIfNeeded(currentItemId: "c")
        XCTAssertEqual(mock.searchMetadataCalls.count, 2)
    }

    func test_Pagination_AC_2b_gridEnd_movesAfterLastPhotosRemoved() async {
        let ids = pgIds("p1", 0..<1000)
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 2000),
            pages: [1: pgPage(ids, next: "2")]
        )
        let before = vm.gridEndRevision
        await vm.removeAssets(ids: Array(ids.suffix(3)))
        XCTAssertNotEqual(vm.gridEndRevision, before)
        XCTAssertEqual(vm.gridFooter, .loadingMore)
        XCTAssertEqual(mock.searchMetadataCalls.count, 1)

        await vm.loadMore()  // what the footer spinner triggers, without any cell callback
        XCTAssertEqual(mock.searchMetadataCalls.count, 2)
        XCTAssertEqual(mock.searchMetadataCalls[1].page, 1)

        mock.searchMetadataError = Boom()
        let revision = vm.gridEndRevision
        await vm.loadMore()
        XCTAssertNotNil(vm.loadMoreErrorMessage)
        XCTAssertEqual(vm.gridEndRevision, revision)
    }

    func test_Pagination_AC_3_threePages_loadsAll_countNeverClaimsComplete() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 2500),
            pages: [
                1: pgPage(pgIds("a", 0..<1000), next: "2"),
                2: pgPage(pgIds("b", 0..<1000), next: "3"),
                3: pgPage(pgIds("c", 0..<500), next: nil)
            ]
        )
        XCTAssertEqual(vm.displayedPhotoCount(fallback: 0), 2500)
        await vm.loadMore()
        XCTAssertTrue(vm.hasMorePages)
        XCTAssertEqual(vm.displayedPhotoCount(fallback: 0), 2500)
        await vm.loadMore()
        XCTAssertFalse(vm.hasMorePages)
        XCTAssertEqual(vm.assets.count, 2500)
        XCTAssertEqual(vm.displayedPhotoCount(fallback: 0), 2500)
        XCTAssertEqual(mock.searchMetadataCalls.map(\.page), [1, 2, 3])
    }

    func test_Pagination_AC_4_loadMoreInFlight_sendsNoDuplicate() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 3),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["c"], next: nil)]
        )
        let latch = TestLatch()
        mock.searchMetadataGate = { dto in if dto.page == 2 { try await latch.wait() } }
        let task = Task { await vm.loadMore() }
        await pollUntil("page 2 requested") { mock.searchMetadataCalls.count == 2 }
        XCTAssertTrue(vm.isLoadingMore)
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.count, 2)
        latch.open()
        await task.value
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b", "c"])
    }

    func test_Pagination_AC_5_ascOrder_sentOnEveryPage() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: .asc, assetCount: 3),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["c"], next: nil)]
        )
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.map(\.order), ["asc", "asc"])
    }

    func test_Pagination_AC_5b_albumOrderChangeWithoutFirstPage_keepsGridOrder() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: .desc, assetCount: 3),
            pages: [
                1: pgPage(["a", "b"], next: "2"),
                2: pgPage(["c", "d"], next: "3"),
                3: pgPage(["e"], next: nil)
            ]
        )
        await vm.loadMore()
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b", "c", "d"])

        mock.getAlbumResponse = ["alb": pgAlbum(order: .asc, assetCount: 5)]
        await vm.refreshAlbum()
        mock.searchMetadataError = Boom()
        await vm.load()  // album refreshed, page 1 fails
        XCTAssertNotNil(vm.loadErrorMessage)
        mock.searchMetadataError = nil

        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 3)
        XCTAssertEqual(mock.searchMetadataCalls.last?.order, "desc")
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b", "c", "d", "e"])

        await vm.load()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)
        XCTAssertEqual(mock.searchMetadataCalls.last?.order, "asc")
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.last?.order, "asc")
    }

    func test_Pagination_AC_6_descOrder_sent() async {
        let (_, mock) = await pgVM(
            album: pgAlbum(order: .desc, assetCount: 1),
            pages: [1: pgPage(["a"], next: nil)]
        )
        XCTAssertEqual(mock.searchMetadataCalls.map(\.order), ["desc"])
    }

    func test_Pagination_AC_7_noOrder_loadsAndOmitsOrderKey() async throws {
        let json = """
        {"id":"alb","albumName":"A","description":"","createdAt":"2024-01-01T00:00:00.000Z",
         "updatedAt":"2024-01-01T00:00:00.000Z","shared":false,"hasSharedLink":false,
         "assetCount":1,"isActivityEnabled":false,"albumUsers":[]}
        """
        let album = try JSONDecoder().decode(AlbumResponseDto.self, from: Data(json.utf8))
        XCTAssertNil(album.order)
        let (vm, mock) = await pgVM(album: album, pages: [1: pgPage(["a"], next: nil)])
        XCTAssertEqual(vm.assets.map(\.id), ["a"])
        XCTAssertNil(vm.loadErrorMessage)
        let dto = try XCTUnwrap(mock.searchMetadataCalls.first)
        XCTAssertNil(dto.order)
        let body = String(decoding: try JSONEncoder().encode(dto), as: UTF8.self)
        XCTAssertFalse(body.contains("\"order\""))
    }

    func test_Pagination_AC_8_secondPageDuplicate_appearsOnce() async {
        let (vm, _) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 3),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["b", "c"], next: nil)]
        )
        await vm.loadMore()
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b", "c"])
    }

    func test_Pagination_AC_9_secondPageFailure_keepsFirstPage_andRetries() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 3),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["c"], next: nil)]
        )
        mock.searchMetadataError = Boom()
        await vm.loadMoreIfNeeded(currentItemId: "b")
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b"])
        XCTAssertNotNil(vm.loadMoreErrorMessage)
        if case .error = vm.gridFooter {} else { XCTFail("footer should show the error") }
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertTrue(vm.hasMorePages)

        mock.searchMetadataError = nil
        await vm.loadMoreIfNeeded(currentItemId: "b")
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 2)
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b", "c"])
        XCTAssertNil(vm.loadMoreErrorMessage)
    }

    func test_Pagination_AC_10_reload_restartsFromFirstPage_withCurrentOrder() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: .desc, assetCount: 3),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["c"], next: nil)]
        )
        await vm.loadMore()
        XCTAssertEqual(vm.assets.count, 3)

        mock.getAlbumResponse = ["alb": pgAlbum(order: .asc, assetCount: 2)]
        mock.searchMetadataResponsesByPage = [1: pgPage(["x", "y"], next: nil)]
        await vm.load()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)
        XCTAssertEqual(mock.searchMetadataCalls.last?.order, "asc")
        XCTAssertEqual(vm.assets.map(\.id), ["x", "y"])
        XCTAssertFalse(vm.hasMorePages)
    }

    func test_Pagination_AC_10b_staleNextPage_isDropped() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 3),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["c"], next: nil)]
        )
        let latch = TestLatch()
        mock.searchMetadataGate = { dto in if dto.page == 2 { try await latch.wait() } }
        let task = Task { await vm.loadMore() }
        await pollUntil("page 2 requested") { mock.searchMetadataCalls.count == 2 }

        mock.searchMetadataResponsesByPage = [1: pgPage(["x"], next: nil)]
        await vm.load()
        latch.open()
        await task.value
        XCTAssertEqual(vm.assets.map(\.id), ["x"])
        XCTAssertFalse(vm.isLoadingMore)
    }

    func test_Pagination_AC_10c_addAssets_restartsFromFirstPage() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 3),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["c"], next: nil)]
        )
        await vm.loadMore()
        mock.searchMetadataResponsesByPage = [1: pgPage(["x", "y"], next: nil)]
        await vm.addAssets(ids: ["x"])
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)
        XCTAssertEqual(vm.assets.map(\.id), ["x", "y"])
        XCTAssertFalse(vm.hasMorePages)
    }

    func test_Pagination_AC_10d_loadMoreDuringFirstPageReload_isNoop() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 3),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["c"], next: nil)]
        )
        let latch = TestLatch()
        mock.searchMetadataGate = { _ in try await latch.wait() }
        let task = Task { await vm.addAssets(ids: ["z"]) }
        await pollUntil("page 1 re-requested") { mock.searchMetadataCalls.count == 2 }
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.count, 2)
        latch.open()
        await task.value
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b"])
    }

    func test_Pagination_AC_23_removals_requestPageHoldingBoundary() async {
        let ids = pgIds("p1", 0..<1000)
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 2000),
            pages: [1: pgPage(ids, next: "2")]
        )
        await vm.removeAssets(ids: Array(ids.prefix(5)))
        // The server, once the 5 are gone, shifts: page 1 = old 5...999 + 5 new.
        mock.searchMetadataResponsesByPage = [
            1: pgPage(Array(ids.dropFirst(5)) + pgIds("n", 0..<5), next: "2"),
            2: pgPage(["z"], next: nil)
        ]
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)
        XCTAssertEqual(vm.assets.count, 1000)
        XCTAssertEqual(Set(vm.assets.map(\.id)).count, 1000)
        XCTAssertEqual(vm.assets.suffix(5).map(\.id), pgIds("n", 0..<5))
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 2)
    }

    func test_Pagination_AC_23b_ownedOnlyDeleteAndViewerDelete_count() async {
        let ids = ["a", "b", "c"] + pgIds("x", 0..<997)
        let mock = MockImmichClient()
        mock.getAlbumResponse = ["alb": pgAlbum(order: nil, assetCount: 2500)]
        mock.searchMetadataResponsesByPage = [
            1: SearchResponseDto(assets: SearchAssetResponseDto(
                count: 1000,
                items: ids.map { pgAsset($0, owner: $0 == "c" ? "other" : "me") },
                nextPage: "2"
            ))
        ]
        let vm = AlbumDetailViewModel(client: mock, albumId: "alb")
        await vm.load()
        vm.enterSelectionMode()
        for id in ["a", "b", "c"] { vm.toggleSelection(id: id) }
        await vm.deleteSelected(currentUserId: "me")
        XCTAssertEqual(Set(mock.lastDeleteBody?.ids ?? []), ["a", "b"])
        XCTAssertTrue(vm.assets.contains { $0.id == "c" })
        XCTAssertEqual(vm.displayedPhotoCount(fallback: 0), 2498)

        mock.searchMetadataResponsesByPage = [1: pgPage(["x-1"], next: "2")]
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)

        await vm.delete(id: "x-0")
        XCTAssertEqual(vm.displayedPhotoCount(fallback: 0), 2497)
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)
    }

    func test_Pagination_AC_23c_refusedRemoval_notCounted() async {
        let ids = pgIds("p1", 0..<1000)
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 2000),
            pages: [1: pgPage(ids, next: "2"), 2: pgPage(["z"], next: nil)]
        )
        mock.removeAssetsResponse = [
            BulkIdResponseDto(id: "p1-0", success: false, error: .noPermission, errorMessage: nil)
        ]
        await vm.removeAssets(ids: ["p1-0"])
        XCTAssertEqual(vm.assets.count, 1000)
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 2)
    }

    func test_Pagination_AC_23d_removalDuringFlight_doesNotAdvance() async {
        let ids = pgIds("p1", 0..<1000)
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 3000),
            pages: [
                1: pgPage(ids, next: "2"),
                2: pgPage(pgIds("p2", 0..<1000), next: "3")
            ]
        )
        let latch = TestLatch()
        mock.searchMetadataGate = { dto in if dto.page == 2 { try await latch.wait() } }
        let task = Task { await vm.loadMore() }
        await pollUntil("page 2 requested") { mock.searchMetadataCalls.count == 2 }

        await vm.removeAssets(ids: ["p1-0"])
        let revision = vm.gridEndRevision
        latch.open()
        await task.value
        XCTAssertEqual(vm.assets.count, 999)
        XCTAssertFalse(vm.assets.contains { $0.id.hasPrefix("p2-") })
        XCTAssertTrue(vm.hasMorePages)
        XCTAssertNotEqual(vm.gridEndRevision, revision)

        mock.searchMetadataResponsesByPage = [
            1: pgPage(Array(ids.dropFirst()) + ["p2-0"], next: "2"),
            2: pgPage(pgIds("p2", 1..<1000), next: "3"),
            3: pgPage(["p3-0"], next: nil)
        ]
        await pgDrain(vm)
        XCTAssertEqual(mock.searchMetadataCalls.suffix(3).map(\.page), [1, 2, 3])
        XCTAssertEqual(vm.assets.count, 2000)
    }

    func test_Pagination_AC_23e_largeK_goesBackSeveralPages() async {
        let page1 = pgIds("p1", 0..<1000)
        let page2 = pgIds("p2", 0..<1000)
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 4000),
            pages: [1: pgPage(page1, next: "2"), 2: pgPage(page2, next: "3")]
        )
        await vm.loadMore()
        XCTAssertEqual(vm.assets.count, 2000)
        await vm.removeAssets(ids: Array((page1 + page2).prefix(1500)))
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)
    }

    func test_Pagination_AC_23f_offsetServer_removalProcessedBeforeHeldPage() async {
        let server = PgOffsetServer(ids: pgIds("id", 0..<2500))
        let hold = TestBox<TestLatch?>(nil)
        let (vm, mock) = await pgServerVM(server, before: hold)
        let latch = TestLatch()
        hold.value = latch
        let task = Task { await vm.loadMore() }
        await pollUntil("page 2 requested") { mock.searchMetadataCalls.count == 2 }

        await vm.removeAssets(ids: ["id-10"])  // applied to the server by the removal gate
        latch.open()
        await task.value
        await pgDrain(vm)
        XCTAssertEqual(vm.assets.map(\.id), server.ids)
    }

    func test_Pagination_AC_23g_offsetServer_removalAnsweredAfterPage() async {
        let server = PgOffsetServer(ids: pgIds("id", 0..<2500))
        let hold = TestBox<TestLatch?>(nil)
        let (vm, mock) = await pgServerVM(server, before: hold)
        let searchLatch = TestLatch()
        let removalLatch = TestLatch()
        hold.value = searchLatch
        mock.removeAssetsFromAlbumGate = { dto in
            server.ids.removeAll { dto.ids.contains($0) }
            try await removalLatch.wait()
        }
        let search = Task { await vm.loadMore() }
        await pollUntil("page 2 requested") { mock.searchMetadataCalls.count == 2 }
        let removal = Task { await vm.removeAssets(ids: ["id-10"]) }
        await pollUntil("removal at the server") { mock.lastRemoveAssetsIds != nil }

        searchLatch.open()
        await search.value  // read after the removal, answered while it is still in flight
        XCTAssertTrue(vm.hasMorePages)
        XCTAssertEqual(vm.assets.count, 1000)
        let calls = mock.searchMetadataCalls.count
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.count, calls)

        let revision = vm.gridEndRevision
        removalLatch.open()
        await removal.value
        XCTAssertNotEqual(vm.gridEndRevision, revision)
        await pgDrain(vm)
        XCTAssertEqual(vm.assets.map(\.id), server.ids)
    }

    func test_Pagination_AC_23h_offsetServer_compensatedPage_doesNotResurrectRemoved() async {
        let server = PgOffsetServer(ids: pgIds("id", 0..<2500))
        let after = TestBox<TestLatch?>(nil)
        let (vm, mock) = await pgServerVM(server, after: after)
        await vm.removeAssets(ids: pgIds("id", 0..<5))
        let latch = TestLatch()
        after.value = latch
        let task = Task { await vm.loadMore() }  // page 1, read before the next removal
        await pollUntil("compensated page requested") { mock.searchMetadataCalls.count == 2 }
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)

        await vm.removeAssets(ids: ["id-20"])
        latch.open()
        await task.value
        XCTAssertFalse(vm.assets.contains { $0.id == "id-20" })
        await pgDrain(vm)
        XCTAssertEqual(vm.assets.map(\.id), server.ids)
        XCTAssertEqual(Set(vm.assets.map(\.id)).count, vm.assets.count)
    }

    func test_Pagination_AC_24_viewerFavorite_patchesInPlace_noReload() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 3000),
            pages: [1: pgPage(["a", "b"], next: "2"), 2: pgPage(["c", "d"], next: "3")]
        )
        await vm.loadMore()
        mock.updateAssetResponse = pgAsset("c")
        let calls = mock.searchMetadataCalls.count
        let ok = await vm.setFavorite(id: "c", isFavorite: true)
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(vm.assets[2].isFavorite, true)
        XCTAssertEqual(mock.searchMetadataCalls.count, calls)
        XCTAssertTrue(vm.hasMorePages)
    }

    func test_Pagination_AC_24b_viewerArchive_keepsPhoto_updatesVisibility() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 2),
            pages: [1: pgPage(["a", "b"], next: nil)]
        )
        let error = await vm.setArchived(id: "b", archived: true, handOffError: true)
        XCTAssertNil(error)
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b"])
        XCTAssertEqual(vm.assets[1].visibility, "archive")
        XCTAssertEqual(mock.lastBulkUpdateDto, AssetBulkUpdateDto(ids: ["b"], visibility: .archive))
    }

    func test_Pagination_AC_24c_viewerDelete_removes_andCounts() async {
        let ids = pgIds("p1", 0..<1000)
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 2000),
            pages: [1: pgPage(ids, next: "2")]
        )
        let ok = await vm.delete(id: "p1-3")
        XCTAssertTrue(ok)
        XCTAssertFalse(vm.assets.contains { $0.id == "p1-3" })
        XCTAssertEqual(mock.lastDeleteBody?.ids, ["p1-3"])
        await vm.loadMore()
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)
    }

    func test_Pagination_AC_24d_viewerRefusals_keepPhoto_andReportError() async {
        let (vm, mock) = await pgVM(
            album: pgAlbum(order: nil, assetCount: 2),
            pages: [1: pgPage(["a", "b"], next: nil)]
        )
        mock.updateAssetErrorsById["a"] = Boom()
        let favorited = await vm.setFavorite(id: "a", isFavorite: true)
        XCTAssertFalse(favorited)
        XCTAssertFalse(vm.assets[0].isFavorite)
        XCTAssertNotNil(vm.actionErrorMessage)

        vm.actionErrorMessage = nil
        mock.deleteError = Boom()
        let deleted = await vm.delete(id: "a")
        XCTAssertFalse(deleted)
        XCTAssertEqual(vm.assets.map(\.id), ["a", "b"])
        XCTAssertNotNil(vm.actionErrorMessage)

        vm.actionErrorMessage = nil
        mock.globalError = Boom()
        let message = await vm.setArchived(id: "a", archived: true, handOffError: true)
        XCTAssertNotNil(message)
        XCTAssertNil(vm.actionErrorMessage)
        XCTAssertEqual(vm.assets[0].visibility, "timeline")
    }
}

// MARK: - Pagination builders (prefix `pg`)

private func pgAlbum(order: AssetOrder?, assetCount: Int) -> AlbumResponseDto {
    AlbumResponseDto(
        id: "alb", albumName: "Album", description: "", createdAt: "2024-01-01T00:00:00.000Z",
        updatedAt: "2024-01-01T00:00:00.000Z", albumThumbnailAssetId: nil, shared: false,
        hasSharedLink: false, assetCount: assetCount, isActivityEnabled: false, order: order
    )
}

private func pgAsset(_ id: String, owner: String = "me") -> AssetResponseDto {
    AssetResponseDto(
        id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
        duration: nil, hasMetadata: true, width: 100, height: 100,
        createdAt: "2024-07-01T00:00:00.000Z", ownerId: owner, originalPath: "/x.jpg",
        originalFileName: "x.jpg", fileCreatedAt: "2024-07-01T00:00:00.000Z",
        fileModifiedAt: "2024-07-01T00:00:00.000Z", updatedAt: "2024-07-01T00:00:00.000Z",
        isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
        visibility: "timeline", checksum: "abc", isEdited: false
    )
}

private func pgPage(_ ids: [String], next: String?) -> SearchResponseDto {
    SearchResponseDto(assets: SearchAssetResponseDto(count: ids.count, items: ids.map { pgAsset($0) }, nextPage: next))
}

private func pgIds(_ prefix: String, _ range: Range<Int>) -> [String] {
    range.map { "\(prefix)-\($0)" }
}

/// Fake server paginating by offset like `POST /api/search/metadata` (flat shape).
private final class PgOffsetServer {
    var ids: [String]
    init(ids: [String]) { self.ids = ids }

    func page(_ p: Int) -> SearchResponseDto {
        let lo = min((p - 1) * 1000, ids.count)
        let hi = min(p * 1000, ids.count)
        return pgPage(Array(ids[lo..<hi]), next: hi < ids.count ? "\(p + 1)" : nil)
    }
}

@MainActor
private func pgDrain(_ vm: AlbumDetailViewModel, max: Int = 10) async {
    var n = 0
    while vm.hasMorePages && n < max {
        await vm.loadMore()
        n += 1
    }
}
