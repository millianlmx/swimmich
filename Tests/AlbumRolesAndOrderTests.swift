import Foundation
import XCTest
@testable import ImmichSwiftUI

/// Lot L-02 — albums: the real owner (v2.x and v3+), edition by editors
/// depending on the server version, and the owner's sort order. Own
/// numbering (parity feature AC-7…AC-11, AC-82…AC-85), kept apart from the
/// older `AlbumDetailViewModelTests` numbering.
@MainActor
final class AlbumRolesAndOrderTests: XCTestCase {

    private struct Boom: Error {}

    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "albumRolesTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Fixtures

    private let me = "me"

    private func user(_ id: String) -> UserResponseDto {
        UserResponseDto(
            id: id, name: "User \(id)", email: "\(id)@example.com", profileImagePath: "",
            avatarColor: "#FF0000", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    private func entry(_ id: String, _ role: AlbumUserRole) -> AlbumUserResponseDto {
        AlbumUserResponseDto(user: user(id), role: role)
    }

    /// An album in the v2.x shape (`ownerId` + `owner`, owner absent from `albumUsers`)
    /// or in the v3+ shape (owner is an `albumUsers` entry, no `ownerId`).
    private func album(
        id: String = "alb",
        name: String = "Album",
        ownerId: String? = nil,
        owner: UserResponseDto? = nil,
        users: [AlbumUserResponseDto] = [],
        order: AssetOrder? = nil
    ) -> AlbumResponseDto {
        AlbumResponseDto(
            id: id, albumName: name, description: "", createdAt: "2024-01-01T00:00:00.000Z",
            updatedAt: "2024-01-01T00:00:00.000Z", albumThumbnailAssetId: nil, shared: !users.isEmpty,
            hasSharedLink: false, assetCount: 0, isActivityEnabled: true, order: order,
            albumUsers: users, ownerId: ownerId, owner: owner
        )
    }

    private func asset(_ id: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T00:00:00.000Z", ownerId: me, originalPath: "/x.jpg",
            originalFileName: "x.jpg", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z", updatedAt: "2024-07-01T00:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    private func page(_ ids: [String]) -> SearchResponseDto {
        SearchResponseDto(assets: SearchAssetResponseDto(count: ids.count, items: ids.map(asset), nextPage: nil))
    }

    private func version(_ major: Int, _ minor: Int, _ patch: Int) -> ServerVersionResponseDto {
        ServerVersionResponseDto(major: major, minor: minor, patch: patch, prerelease: nil)
    }

    /// A loaded detail VM; the probe runs for `userId` like the screen's `.task`.
    private func loadedVM(
        _ album: AlbumResponseDto,
        userId: String,
        serverVersion: ServerVersionResponseDto? = nil,
        mock: MockImmichClient = MockImmichClient(),
        assets: [String] = []
    ) async -> (AlbumDetailViewModel, MockImmichClient) {
        mock.getAlbumResponse = [album.id: album]
        mock.serverVersionResponse = serverVersion
        mock.searchMetadataResponse = page(assets)
        let vm = AlbumDetailViewModel(client: mock, albumId: album.id)
        await vm.load()
        await vm.probeServerVersionIfEditor(currentUserId: userId)
        return (vm, mock)
    }

    private func makeSyncService(userID: String = "me") -> AlbumSyncService {
        AlbumSyncService(mapping: AlbumSyncStore(suiteName: suiteName), batchSize: 100)
    }

    private func resolve(
        _ service: AlbumSyncService, mock: MockImmichClient, name: String = "Vacances"
    ) async throws -> [String: String] {
        try await service.resolveAlbums(
            deviceAlbums: [BackupAlbum(id: "dev-vac", name: name, count: 1, isSmart: false)],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: ["a1": ["dev-vac"]], userID: me, client: mock
        )
    }

    // MARK: - AC-7 (v2 owner on the share sheet)

    func test_AC_7_v2OwnerSheetShowsOwnerIdNotFirstMember() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [user(me)]   // non-admin: the directory is just oneself
        let v2 = album(
            ownerId: me, owner: user(me),
            users: [entry("alice", .editor), entry("bob", .viewer)]
        )
        let (vm, _) = await loadedVM(v2, userId: me, mock: mock)

        let share = vm.makeShareViewModel(currentUserId: me, isAdmin: false)
        XCTAssertEqual(share.owner?.id, me, "the owner is the one `ownerId` designates, not albumUsers.first")
        XCTAssertEqual(share.role(for: "alice"), .editor)
        XCTAssertEqual(share.role(for: "bob"), .viewer)

        await share.load()
        XCTAssertEqual(Set(share.collaborators.map(\.id)), ["alice", "bob"])
        XCTAssertFalse(share.collaborators.contains { $0.id == me })

        await share.revoke(userId: "alice")
        XCTAssertEqual(mock.lastRemovedUserId, "alice", "the editor stays revocable by the owner")
        XCTAssertNil(share.role(for: "alice"))
    }

    func test_AC_7_noOwnerKnownMeansNoOwnerRow_neverFirstMember() {
        let share = AlbumShareViewModel(
            client: MockImmichClient(), albumId: "alb", currentUserId: me, isAdmin: false,
            albumUsers: [entry("alice", .editor)]
        )
        XCTAssertNil(share.owner)
    }

    func test_AC_7_ownerEntryNeverListedAsCollaborator() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [user(me), user("tom")]
        let share = AlbumShareViewModel(
            client: mock, albumId: "alb", currentUserId: me, isAdmin: true,
            albumUsers: [entry("tom", .owner), entry(me, .editor)]
        )
        await share.load()
        XCTAssertEqual(share.owner?.id, "tom")
        XCTAssertNil(share.role(for: "tom"), "the owner is never a collaborator, so never revocable")
        XCTAssertTrue(share.collaborators.isEmpty)
    }

    func test_AC_7_roleRule_sameOnBothServerShapes() {
        XCTAssertEqual(album(ownerId: me).role(of: me), .owner)
        XCTAssertEqual(album(ownerId: "carol", users: [entry("alice", .editor), entry(me, .viewer)]).role(of: me), .viewer)
        XCTAssertEqual(album(users: [entry("carol", .owner), entry(me, .editor)]).role(of: me), .editor)
        XCTAssertEqual(album(users: [entry(me, .owner)]).role(of: me), .owner)
        XCTAssertEqual(album(ownerId: me).role(of: nil), .viewer)
        XCTAssertEqual(album(ownerId: me).role(of: ""), .viewer)
    }

    func test_AC_7_decodesV2OwnerField() throws {
        let json = Data("""
        {"id":"alb","albumName":"A","description":"","createdAt":"2024-01-01T00:00:00.000Z",
        "updatedAt":"2024-01-01T00:00:00.000Z","shared":true,"hasSharedLink":false,
        "assetCount":0,"isActivityEnabled":false,"albumUsers":[],"ownerId":"me",
        "owner":{"id":"me","name":"Me","email":"me@example.com","profileImagePath":"",
        "avatarColor":"#FF0000","profileChangedAt":"2024-01-01T00:00:00.000Z"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(AlbumResponseDto.self, from: json)
        XCTAssertEqual(decoded.owner?.id, "me")
    }

    // MARK: - AC-8 (v2 sync recognises its own album)

    func test_AC_8_v2OwnedAlbumMatchedWithoutCreate() async throws {
        // (a) ownerId = me, albumUsers = [editor]
        let mock = MockImmichClient()
        mock.albumsResponse = [album(id: "srv-own", name: "Vacances", ownerId: me, owner: user(me), users: [entry("eve", .editor)])]
        let service = makeSyncService()
        let map = try await resolve(service, mock: mock)
        XCTAssertEqual(map, ["dev-vac": "srv-own"])
        XCTAssertTrue(mock.createdAlbumNames.isEmpty)

        // (b) a stranger's album listed first, where I am the first (editor) member.
        let mock2 = MockImmichClient()
        mock2.albumsResponse = [
            album(id: "srv-theirs", name: "Vacances", ownerId: "tom", owner: user("tom"), users: [entry(me, .editor)]),
            album(id: "srv-mine", name: "Vacances", ownerId: me, owner: user(me), users: [entry("eve", .editor)]),
        ]
        let map2 = try await resolve(makeSyncService(), mock: mock2)
        XCTAssertEqual(map2, ["dev-vac": "srv-mine"], "ownership wins over an editor seat listed earlier")
        XCTAssertTrue(mock2.createdAlbumNames.isEmpty)
        XCTAssertEqual(mock2.getAlbumsSharedArgs, [nil], "the mirror keeps the unfiltered list")
    }

    // MARK: - AC-82 (v3 owner sheet + sync, viewer never reused)

    func test_AC_82_v3OwnerSheetAndSyncPickOwnedAlbum() async throws {
        let theirs = album(id: "srv-theirs", name: "Vacances", users: [entry("tom", .owner), entry(me, .editor)])
        let mine = album(id: "srv-mine", name: "Vacances", users: [entry(me, .owner), entry("eve", .editor)])

        // The sheet of my own album.
        let mock = MockImmichClient()
        mock.getUsersResponse = [user(me)]
        let (vm, _) = await loadedVM(mine, userId: me, mock: mock)
        let share = vm.makeShareViewModel(currentUserId: me, isAdmin: false)
        XCTAssertEqual(share.owner?.id, me)
        XCTAssertEqual(share.role(for: "eve"), .editor)

        // The mirror files photos into the album I own.
        let syncMock = MockImmichClient()
        syncMock.albumsResponse = [theirs, mine]
        let service = makeSyncService()
        let map = try await resolve(service, mock: syncMock)
        XCTAssertEqual(map, ["dev-vac": "srv-mine"])
        XCTAssertTrue(syncMock.createdAlbumNames.isEmpty)
        await service.stage(assetID: "srv-a1", deviceAssetID: "a1")
        _ = await service.flush(client: syncMock)
        XCTAssertEqual(syncMock.addAssetsToAlbumCalls.map { $0.albumId }, ["srv-mine"])
    }

    func test_AC_82_v3ViewerSameNameAlbumNotReused() async throws {
        let mock = MockImmichClient()
        mock.albumsResponse = [album(id: "srv-theirs", name: "Vacances", users: [entry("tom", .owner), entry(me, .viewer)])]
        mock.createAlbumResponse = album(id: "srv-created", name: "Vacances", users: [entry(me, .owner)])
        let map = try await resolve(makeSyncService(), mock: mock)
        XCTAssertEqual(mock.createdAlbumNames, ["Vacances"])
        XCTAssertEqual(map, ["dev-vac": "srv-created"])
    }

    func test_AC_82_v3EditorSeatIsAFallbackWhenNothingIsOwned() async throws {
        let mock = MockImmichClient()
        mock.albumsResponse = [album(id: "srv-theirs", name: "Vacances", users: [entry("tom", .owner), entry(me, .editor)])]
        let map = try await resolve(makeSyncService(), mock: mock)
        XCTAssertEqual(map, ["dev-vac": "srv-theirs"])
        XCTAssertTrue(mock.createdAlbumNames.isEmpty)
    }

    // MARK: - AC-83 (photo share picker)

    func test_AC_83_photoSharePickerExcludesSignedInUser() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [user(me), user("partner"), user("other")]
        let item = AssetReactItem(
            id: "a1", ownerId: "partner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
        let vm = PhotoShareViewModel(
            asset: item, client: mock, baseURL: URL(string: "https://example.com")!, currentUserId: me
        )
        await vm.load()
        XCTAssertEqual(vm.users.map(\.id), ["partner", "other"])

        let unknown = PhotoShareViewModel(
            asset: item, client: mock, baseURL: URL(string: "https://example.com")!, currentUserId: nil
        )
        await unknown.load()
        XCTAssertEqual(unknown.users.count, 3, "without a current user nothing is filtered")
    }

    // MARK: - AC-9 / AC-10 / AC-84 (editing by role and server version)

    func test_AC_9_editorOnV3SavesTitleAndDescription() async {
        let a = album(users: [entry("carol", .owner), entry(me, .editor)])
        let (vm, mock) = await loadedVM(a, userId: me, serverVersion: version(3, 4, 0))

        XCTAssertTrue(vm.allowedActions(on: .albumMenu, currentUserId: me, fallback: a).contains(.editAlbum))
        let ok = await vm.updateAlbumDetails(name: "New", description: "Desc", isActivityEnabled: nil, currentUserId: me)

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastUpdateAlbumId, "alb")
        XCTAssertEqual(mock.lastUpdateAlbumDto?.albumName, "New")
        XCTAssertEqual(mock.lastUpdateAlbumDto?.description, "Desc")
        XCTAssertEqual(vm.album?.albumName, "New")
        XCTAssertEqual(vm.album?.description, "Desc")
    }

    func test_AC_10_editorOn261HasNoEditAction() async {
        let a = album(ownerId: "carol", owner: user("carol"), users: [entry(me, .editor)])
        let (vm, _) = await loadedVM(a, userId: me, serverVersion: version(2, 6, 1))
        XCTAssertFalse(vm.editorCanUpdateAlbum)
        XCTAssertTrue(vm.allowedActions(on: .albumMenu, currentUserId: me, fallback: a).isEmpty)
    }

    func test_AC_84_editMatrixByRoleAndVersion() async {
        let editorAlbum = album(ownerId: "carol", owner: user("carol"), users: [entry(me, .editor)])
        let viewerAlbum = album(users: [entry("carol", .owner), entry(me, .viewer)])
        let ownerAlbum = album(ownerId: me, owner: user(me), users: [entry("eve", .editor)])

        // Viewer on v3: no action; no version probe even though it would fail.
        let viewerMock = MockImmichClient()
        viewerMock.serverVersionError = Boom()
        let (viewerVM, _) = await loadedVM(viewerAlbum, userId: me, serverVersion: version(3, 4, 0), mock: viewerMock)
        let viewerCount = viewerMock.requestCount
        await viewerVM.probeServerVersionIfEditor(currentUserId: me)
        XCTAssertEqual(viewerMock.requestCount, viewerCount, "a viewer never triggers GET /server/version")
        XCTAssertTrue(viewerVM.allowedActions(on: .albumMenu, currentUserId: me, fallback: viewerAlbum).isEmpty)

        // Editor whose version could not be read: refused.
        let unknownMock = MockImmichClient()
        unknownMock.serverVersionError = Boom()
        let (unknownVM, _) = await loadedVM(editorAlbum, userId: me, mock: unknownMock)
        XCTAssertNil(unknownVM.serverVersion)
        XCTAssertTrue(unknownVM.allowedActions(on: .albumMenu, currentUserId: me, fallback: editorAlbum).isEmpty)

        // Editors on 2.6.2 and on 3.4.0: the action, a sheet without the activity toggle, no isActivityEnabled key.
        for v in [version(2, 6, 2), version(3, 4, 0)] {
            let (vm, mock) = await loadedVM(editorAlbum, userId: me, serverVersion: v)
            XCTAssertEqual(vm.allowedActions(on: .albumMenu, currentUserId: me, fallback: editorAlbum), [.editAlbum], "\(v)")
            XCTAssertFalse(vm.canToggleActivity(currentUserId: me))
            let ok = await vm.updateAlbumDetails(name: "N", description: "D", isActivityEnabled: true, currentUserId: me)
            XCTAssertTrue(ok)
            XCTAssertNil(mock.lastUpdateAlbumDto?.isActivityEnabled, "an editor never sends the activity key")
        }

        // Owner on 2.6.1: full menu, full sheet, save succeeds with the toggle.
        let ownerMock = MockImmichClient()
        ownerMock.serverVersionError = Boom()
        let (ownerVM, _) = await loadedVM(ownerAlbum, userId: me, serverVersion: version(2, 6, 1), mock: ownerMock)
        let ownerCount = ownerMock.requestCount
        await ownerVM.probeServerVersionIfEditor(currentUserId: me)
        XCTAssertEqual(ownerMock.requestCount, ownerCount, "the owner never triggers the probe")
        XCTAssertTrue(ownerVM.allowedActions(on: .albumMenu, currentUserId: me, fallback: ownerAlbum).contains(.editAlbum))
        XCTAssertTrue(ownerVM.canToggleActivity(currentUserId: me))
        ownerMock.updateAlbumError = nil
        ownerMock.globalError = nil
        let ok = await ownerVM.updateAlbumDetails(name: "N", description: nil, isActivityEnabled: false, currentUserId: me)
        XCTAssertTrue(ok)
        XCTAssertEqual(ownerMock.lastUpdateAlbumDto?.isActivityEnabled, false)
    }

    func test_AC_84_canToggleActivityIsFalseBeforeAlbumLoads() {
        let vm = AlbumDetailViewModel(client: MockImmichClient(), albumId: "alb")
        XCTAssertFalse(vm.canToggleActivity(currentUserId: me))
    }

    func test_AC_84_versionComparison() {
        XCTAssertTrue(version(2, 6, 2).isAtLeast(major: 2, minor: 6, patch: 2))
        XCTAssertTrue(version(2, 7, 5).isAtLeast(major: 2, minor: 6, patch: 2))
        XCTAssertTrue(version(3, 0, 0).isAtLeast(major: 2, minor: 6, patch: 2))
        XCTAssertFalse(version(2, 6, 1).isAtLeast(major: 2, minor: 6, patch: 2))
        XCTAssertFalse(version(2, 0, 0).isAtLeast(major: 2, minor: 6, patch: 2))
        XCTAssertFalse(version(1, 120, 9).isAtLeast(major: 2, minor: 6, patch: 2))
    }

    func test_AC_84_v2ListIncludesSharedWithMe() async {
        let mock = MockImmichClient()
        let owned = album(id: "A", name: "Mine", ownerId: me)
        let shared = album(id: "C", name: "Carol's", ownerId: "carol", users: [entry(me, .editor)])
        mock.albumsResponse = [owned]
        mock.sharedAlbumsResponse = [owned, shared]
        let vm = AlbumsViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.albums.map(\.id), ["A", "C"])
        XCTAssertTrue(mock.getAlbumsSharedArgs.contains(nil))
        XCTAssertTrue(mock.getAlbumsSharedArgs.contains(true))

        // A failure keeps the previous list and surfaces the error.
        mock.albumsError = Boom()
        await vm.load()
        XCTAssertEqual(vm.albums.map(\.id), ["A", "C"])
        XCTAssertNotNil(vm.loadErrorMessage)
    }

    func test_AC_84_v3IdenticalListsYieldTheFirstListUnchanged() async {
        let mock = MockImmichClient()
        let all = [album(id: "B", name: "B"), album(id: "A", name: "A")]
        mock.albumsResponse = all
        mock.sharedAlbumsResponse = all.reversed()
        let vm = AlbumsViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.albums.map(\.id), ["B", "A"])
    }

    // MARK: - AC-11 / AC-85 (sort order)

    func test_AC_11_ownerSetsOldestFirstAndGridReloads() async {
        let a = album(ownerId: me, owner: user(me))
        let (vm, mock) = await loadedVM(a, userId: me, assets: ["new", "old"])
        let callsBefore = mock.searchMetadataCalls.count

        let ok = await vm.setAlbumOrder(.asc)

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastUpdateAlbumDto, UpdateAlbumDto(
            albumName: nil, description: nil, albumThumbnailAssetId: nil, isActivityEnabled: nil, order: .asc
        ))
        XCTAssertEqual(vm.albumOrder, .asc)
        XCTAssertEqual(mock.searchMetadataCalls.count, callsBefore + 1)
        XCTAssertEqual(mock.searchMetadataCalls.last?.order, "asc")
        XCTAssertEqual(mock.searchMetadataCalls.last?.page, 1)

        // After a relaunch the album comes back with the saved order: page 1 asks for it.
        let reopened = album(ownerId: me, owner: user(me), order: .asc)
        let (vm2, mock2) = await loadedVM(reopened, userId: me, assets: ["old", "new"])
        XCTAssertEqual(vm2.albumOrder, .asc)
        XCTAssertEqual(mock2.searchMetadataCalls.last?.order, "asc")
        XCTAssertEqual(vm2.assets.map(\.id), ["old", "new"])
    }

    func test_AC_85_orderDefaultFailureAndOwnerOnly() async {
        let a = album(ownerId: me, owner: user(me))
        let (vm, mock) = await loadedVM(a, userId: me, assets: ["x", "y"])
        XCTAssertEqual(vm.albumOrder, .desc, "a server that sends no order reads as newest first")

        // Choosing the current order sends nothing.
        let same = await vm.setAlbumOrder(.desc)
        XCTAssertTrue(same)
        XCTAssertNil(mock.lastUpdateAlbumId)

        // A refused PATCH leaves order, grid and pagination alone.
        let assetsBefore = vm.assets.map(\.id)
        let searchCount = mock.searchMetadataCalls.count
        mock.updateAlbumError = Boom()
        let failed = await vm.setAlbumOrder(.asc)
        XCTAssertFalse(failed)
        XCTAssertEqual(vm.albumOrder, .desc)
        XCTAssertEqual(vm.assets.map(\.id), assetsBefore)
        XCTAssertEqual(mock.searchMetadataCalls.count, searchCount)
        XCTAssertNotNil(vm.actionErrorMessage)

        // Owner only.
        let editorAlbum = album(users: [entry("carol", .owner), entry(me, .editor)])
        let viewerAlbum = album(users: [entry("carol", .owner), entry(me, .viewer)])
        let editorPerms = AlbumDetailPermissions(album: editorAlbum, userId: me, editorCanUpdate: true)
        let viewerPerms = AlbumDetailPermissions(album: viewerAlbum, userId: me, editorCanUpdate: true)
        XCTAssertFalse(editorPerms.allowedActions(on: .albumMenu).contains(.changeOrder))
        XCTAssertFalse(viewerPerms.allowedActions(on: .albumMenu).contains(.changeOrder))
        XCTAssertTrue(AlbumDetailPermissions(album: a, userId: me).allowedActions(on: .albumMenu).contains(.changeOrder))
    }

    func test_AC_85_serverEchoWithoutOrderStillReflectsTheChoice() async {
        let a = album(ownerId: me, owner: user(me))
        let (vm, mock) = await loadedVM(a, userId: me)
        mock.updateAlbumResponse = album(ownerId: me, owner: user(me), order: nil)
        let ok = await vm.setAlbumOrder(.asc)
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.albumOrder, .asc)
    }
}
