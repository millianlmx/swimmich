import Foundation
import XCTest
@testable import ImmichSwiftUI

/// The one-way album mirror: resolution of device albums onto server albums,
/// the batching of the album writes, and the ledger catch-up.
///
/// Everything is driven through the real `AlbumSyncService` actor against
/// `MockImmichClient` — no Photos and no network. The mapping store gets a
/// fresh UserDefaults suite per test, so no test can read another one's pairs.
final class AlbumSyncServiceTests: XCTestCase {

    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "albumSyncTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func album(
        id: String,
        name: String,
        owner: String? = nil,
        sharedWith: [String] = []
    ) -> AlbumResponseDto {
        var users: [AlbumUserResponseDto] = []
        if let owner { users.append(AlbumUserResponseDto(user: user(owner), role: .owner)) }
        users.append(contentsOf: sharedWith.map { AlbumUserResponseDto(user: user($0), role: .editor) })
        return AlbumResponseDto(
            id: id, albumName: name, description: "", createdAt: "2024-01-01T00:00:00.000Z",
            updatedAt: "2024-01-01T00:00:00.000Z", albumThumbnailAssetId: nil, shared: !sharedWith.isEmpty,
            hasSharedLink: false, assetCount: 0, isActivityEnabled: false, order: nil,
            albumUsers: users
        )
    }

    private func user(_ id: String) -> UserResponseDto {
        UserResponseDto(
            id: id, name: id, email: "\(id)@example.com", profileImagePath: "",
            avatarColor: "#FF0000", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    private func deviceAlbum(_ id: String, _ name: String, smart: Bool = false) -> BackupAlbum {
        BackupAlbum(id: id, name: name, count: 1, isSmart: smart)
    }

    private func candidate(_ id: String) -> BackupCandidate {
        BackupCandidate(
            id: id, kind: .image, fileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            duration: nil, isFavorite: false
        )
    }

    /// A service on a per-test mapping store, resolved for `dev-vac` → the given
    /// server album when `serverAlbumID` is passed (so a test can start from a
    /// persisted pair, which is the normal state after a first run).
    @MainActor
    private func makeService(
        serverAlbumID: String? = nil,
        userID: String = "me",
        batchSize: Int = 100
    ) -> (AlbumSyncService, AlbumSyncStore) {
        let store = AlbumSyncStore(suiteName: suiteName)
        if let serverAlbumID { store.record(userID: userID, deviceAlbumID: "dev-vac", serverAlbumID: serverAlbumID) }
        return (AlbumSyncService(mapping: store, batchSize: batchSize), store)
    }

    // MARK: - Resolution

    /// The whole point of persisting the mapping: a run over an already-paired
    /// album costs no `GET /albums` at all.
    @MainActor
    func test_resolve_reusesPersistedMappingWithoutListingAlbums() async throws {
        let mock = MockImmichClient()
        let (service, store) = makeService(serverAlbumID: "srv-vac")

        let map = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: [:], userID: "me", client: mock
        )

        XCTAssertEqual(map, ["dev-vac": "srv-vac"])
        XCTAssertEqual(mock.requestCount, 0, "un mapping persisté ne coûte aucun appel serveur")
        XCTAssertEqual(store.serverAlbumID(userID: "me", deviceAlbumID: "dev-vac"), "srv-vac")
    }

    /// First run: no pair exists yet, so the album the user already owns is
    /// adopted instead of duplicated.
    @MainActor
    func test_resolve_mergesByNameWithOwnedAlbum() async throws {
        let mock = MockImmichClient()
        mock.albumsResponse = [album(id: "srv-vac", name: "Vacances", owner: "me")]
        let (service, store) = makeService()

        let map = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: [:], userID: "me", client: mock
        )

        XCTAssertEqual(map, ["dev-vac": "srv-vac"])
        XCTAssertTrue(mock.createdAlbumNames.isEmpty, "un album du même nom ne doit pas être recréé")
        XCTAssertEqual(store.serverAlbumID(userID: "me", deviceAlbumID: "dev-vac"), "srv-vac")
    }

    @MainActor
    func test_resolve_createsAlbumWhenNoNameMatch() async throws {
        let mock = MockImmichClient()
        mock.albumsResponse = [album(id: "srv-work", name: "Travail", owner: "me")]
        mock.createAlbumResponse = album(id: "srv-new", name: "Vacances", owner: "me")
        let (service, store) = makeService()

        let map = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: [:], userID: "me", client: mock
        )

        XCTAssertEqual(map, ["dev-vac": "srv-new"])
        XCTAssertEqual(mock.createdAlbumNames, ["Vacances"])
        XCTAssertNil(mock.lastCreateAlbumDto?.albumUsers, "le miroir ne partage jamais l'album")
        XCTAssertEqual(store.serverAlbumID(userID: "me", deviceAlbumID: "dev-vac"), "srv-new")
    }

    /// An album of the same name owned by somebody else is not ours to fill:
    /// merging into it would write into a stranger's album. The mirror creates
    /// its own instead.
    @MainActor
    func test_resolve_ignoresAlbumOwnedByAnotherUser() async throws {
        let mock = MockImmichClient()
        mock.albumsResponse = [album(id: "srv-theirs", name: "Vacances", owner: "someone-else")]
        mock.createAlbumResponse = album(id: "srv-mine", name: "Vacances", owner: "me")
        let (service, _) = makeService()

        let map = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: [:], userID: "me", client: mock
        )

        XCTAssertEqual(map, ["dev-vac": "srv-mine"])
        XCTAssertEqual(mock.createdAlbumNames, ["Vacances"])
    }

    /// Same name, owned by somebody else, but shared with us — the upstream
    /// "album partagé" case, which is resolved rather than created.
    @MainActor
    func test_resolve_usesAlbumSharedWithTheUser() async throws {
        let mock = MockImmichClient()
        mock.albumsResponse = [
            album(id: "srv-shared", name: "Vacances", owner: "someone-else", sharedWith: ["me"])
        ]
        let (service, _) = makeService()

        let map = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: [:], userID: "me", client: mock
        )

        XCTAssertEqual(map, ["dev-vac": "srv-shared"])
        XCTAssertTrue(mock.createdAlbumNames.isEmpty)
    }

    /// A smart album's membership changes in Photos without an upload, and an
    /// album the user did not pick has no business being mirrored — neither may
    /// cost a server call.
    @MainActor
    func test_resolve_skipsSmartAndUnselectedAlbums() async throws {
        let mock = MockImmichClient()
        let (service, _) = makeService()

        let map = try await service.resolveAlbums(
            deviceAlbums: [
                deviceAlbum("smart:videos", "Videos", smart: true),
                deviceAlbum("dev-other", "Travail"),
            ],
            // Only the smart album is mirrored; the other device album exists
            // but was never picked.
            syncedDeviceAlbumIDs: ["smart:videos"],
            albumMembership: ["a1": ["smart:videos"]],
            userID: "me", client: mock
        )

        XCTAssertTrue(map.isEmpty)
        XCTAssertEqual(mock.requestCount, 0)
    }

    /// Two Immich accounts on one device must not share their albums, and a
    /// pair recorded for one must never be reused for the other.
    @MainActor
    func test_mapping_isScopedPerUser() async throws {
        let mock = MockImmichClient()
        mock.albumsResponse = []
        let (service, store) = makeService()

        mock.createAlbumResponse = album(id: "srv-a", name: "Vacances", owner: "user-a")
        let first = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: [:], userID: "user-a", client: mock
        )
        mock.createAlbumResponse = album(id: "srv-b", name: "Vacances", owner: "user-b")
        let second = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: [:], userID: "user-b", client: mock
        )

        XCTAssertEqual(first, ["dev-vac": "srv-a"])
        XCTAssertEqual(second, ["dev-vac": "srv-b"])
        XCTAssertEqual(store.serverAlbumID(userID: "user-a", deviceAlbumID: "dev-vac"), "srv-a")
        XCTAssertEqual(store.serverAlbumID(userID: "user-b", deviceAlbumID: "dev-vac"), "srv-b")
        XCTAssertEqual(mock.createdAlbumNames, ["Vacances", "Vacances"])
    }

    // MARK: - Flush

    /// The batch size is the caller's (the engine's `checkChunkSize`), and a
    /// buffer larger than it must be split, not sent in one oversized body.
    @MainActor
    func test_flush_batchesAtTheConfiguredChunkSize() async throws {
        let mock = MockImmichClient()
        let (service, _) = makeService(serverAlbumID: "srv-vac", batchSize: 2)
        let membership = ["a1": ["dev-vac"], "a2": ["dev-vac"], "a3": ["dev-vac"]]
        _ = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: membership, userID: "me", client: mock
        )
        for asset in ["a1", "a2", "a3"] {
            await service.stage(assetID: "srv-\(asset)", deviceAssetID: asset)
        }

        let outcome = await service.flush(client: mock)

        XCTAssertEqual(mock.addAssetsToAlbumCalls.map { $0.albumId }, ["srv-vac", "srv-vac"])
        XCTAssertEqual(mock.addAssetsToAlbumCalls.map { $0.ids.count }, [2, 1])
        XCTAssertEqual(mock.addAssetsToAlbumCalls.flatMap { $0.ids }.sorted(), ["srv-a1", "srv-a2", "srv-a3"])
        XCTAssertEqual(outcome.added, 3)
    }

    /// A second run over the same photos answers `DUPLICATE` per asset. That is
    /// "already there", never a failure — otherwise every run after the first
    /// reads as broken.
    @MainActor
    func test_flush_treatsDuplicateAsAlreadyInAlbum() async throws {
        let mock = MockImmichClient()
        let (service, _) = makeService(serverAlbumID: "srv-vac")
        _ = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: ["a1": ["dev-vac"]], userID: "me", client: mock
        )
        mock.addAssetsResponse = [
            BulkIdResponseDto(id: "srv-a1", success: false, error: .duplicate, errorMessage: "duplicate")
        ]
        await service.stage(assetID: "srv-a1", deviceAssetID: "a1")

        let outcome = await service.flush(client: mock)

        XCTAssertEqual(outcome.alreadyInAlbum, 1)
        XCTAssertEqual(outcome.added, 0)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertNil(outcome.lastError)
    }

    /// A read-only shared album answers `NO_PERMISSION` per asset. The other
    /// albums of the same flush must still be sent, and the message must be
    /// kept for the settings screen.
    @MainActor
    func test_flush_recordsPermissionErrorWithoutAbortingTheRun() async throws {
        let mock = MockImmichClient()
        let (service, _) = makeService(serverAlbumID: "srv-vac")
        _ = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: ["a1": ["dev-vac"], "a2": ["dev-vac"]], userID: "me", client: mock
        )
        mock.addAssetsResponse = [
            BulkIdResponseDto(id: "srv-a1", success: false, error: .noPermission, errorMessage: "No permission"),
            BulkIdResponseDto(id: "srv-a2", success: true, error: nil, errorMessage: nil),
        ]
        await service.stage(assetID: "srv-a1", deviceAssetID: "a1")
        await service.stage(assetID: "srv-a2", deviceAssetID: "a2")

        let outcome = await service.flush(client: mock)

        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.lastError, "No permission")
    }

    /// A run that mirrored nothing must not touch the network — the common case
    /// of a user who never turned the mirror on.
    @MainActor
    func test_flush_withEmptyBufferMakesNoRequest() async {
        let mock = MockImmichClient()
        let (service, _) = makeService()

        let outcome = await service.flush(client: mock)

        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(mock.requestCount, 0)
    }

    // MARK: - Catch-up through the ledger

    /// The ledger keeps no server id, so the only way back to an already
    /// uploaded asset is `bulk-upload-check` — and the ids it returns are what
    /// must land in the album.
    @MainActor
    func test_reorganize_mapsLedgerIdsThroughBulkUploadCheck() async throws {
        let mock = MockImmichClient()
        let (service, _) = makeService(serverAlbumID: "srv-vac")
        let membership = ["a1": ["dev-vac"]]
        _ = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: membership, userID: "me", client: mock
        )
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "a1", action: "reject", reason: nil, assetId: "srv-a1", isTrashed: false)
        ])

        let outcome = await service.reorganize(
            entries: [(id: "a1", checksum: "sha1-a1")],
            albumMembership: membership, userID: "me", client: mock
        )

        XCTAssertEqual(mock.bulkUploadCheckChunks.count, 1, "le rattrapage doit passer par bulk-upload-check")
        XCTAssertEqual(mock.addAssetsToAlbumCalls.map { $0.albumId }, ["srv-vac"])
        XCTAssertEqual(mock.addAssetsToAlbumCalls.flatMap { $0.ids }, ["srv-a1"])
        XCTAssertEqual(outcome.added, 1)
    }

    /// `accept` means the server does not have the asset at all (an upload is
    /// missing, not a filing job) and a trashed asset is on its way out: neither
    /// may be written into an album.
    @MainActor
    func test_reorganize_skipsEntriesWithNoRemoteAssetID() async throws {
        let mock = MockImmichClient()
        let (service, _) = makeService(serverAlbumID: "srv-vac")
        let membership = ["a1": ["dev-vac"], "a2": ["dev-vac"]]
        _ = try await service.resolveAlbums(
            deviceAlbums: [deviceAlbum("dev-vac", "Vacances")],
            syncedDeviceAlbumIDs: ["dev-vac"],
            albumMembership: membership, userID: "me", client: mock
        )
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "a1", action: "accept", reason: nil, assetId: nil, isTrashed: nil),
            .init(id: "a2", action: "reject", reason: nil, assetId: "srv-a2", isTrashed: true),
        ])

        let outcome = await service.reorganize(
            entries: [(id: "a1", checksum: "sha1-a1"), (id: "a2", checksum: "sha1-a2")],
            albumMembership: membership, userID: "me", client: mock
        )

        XCTAssertTrue(mock.addAssetsToAlbumCalls.isEmpty)
        XCTAssertTrue(outcome.isEmpty)
    }

    // MARK: - The run itself

    /// End to end through the engine: the asset id returned by the upload is
    /// the one that reaches the album, and it is filed under the server album
    /// resolved for its device album.
    @MainActor
    func test_run_stagesTheUploadedAssetUnderItsMirroredAlbum() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        source.albums = [deviceAlbum("dev-vac", "Vacances")]
        source.albumMembershipByDeviceAlbum = ["c1": ["dev-vac"]]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept")]
        )
        let store = AlbumSyncStore(suiteName: suiteName)
        let service = AlbumSyncService(mapping: store, batchSize: 100)
        let engine = BackupEngine(
            client: mock, source: source, environment: MockBackupEnvironment(),
            ledger: BackupLedger.inMemory(), albumSync: service, userID: { "me" }
        )
        var settings = BackupSettings(isEnabled: true)
        settings.syncedAlbumIDs = ["dev-vac"]

        await engine.run(settings: settings)

        XCTAssertEqual(mock.createdAlbumNames, ["Vacances"])
        XCTAssertEqual(mock.addAssetsToAlbumCalls.map { $0.albumId }, ["album-new"])
        XCTAssertEqual(mock.addAssetsToAlbumCalls.flatMap { $0.ids }, ["new-asset"])
        XCTAssertEqual(engine.albumSyncOutcome?.added, 1)
    }

    /// Default settings: no mirrored album means no album call, no resolution
    /// and no summary — an existing install sees exactly the old behavior.
    @MainActor
    func test_run_withoutMirroredAlbumsMakesNoAlbumCall() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        source.albums = [deviceAlbum("dev-vac", "Vacances")]
        source.albumMembershipByDeviceAlbum = ["c1": ["dev-vac"]]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept")]
        )
        let service = AlbumSyncService(mapping: AlbumSyncStore(suiteName: suiteName), batchSize: 100)
        let engine = BackupEngine(
            client: mock, source: source, environment: MockBackupEnvironment(),
            ledger: BackupLedger.inMemory(), albumSync: service, userID: { "me" }
        )

        await engine.run(settings: BackupSettings(isEnabled: true))

        XCTAssertTrue(mock.addAssetsToAlbumCalls.isEmpty)
        XCTAssertTrue(mock.createdAlbumNames.isEmpty)
        XCTAssertNil(engine.albumSyncOutcome)
        XCTAssertEqual(engine.uploadedCount, 1, "le backup lui-même ne change pas")
    }

    /// The mirror is a convenience, the backup is the job: a server that cannot
    /// be listed must not stop the upload.
    @MainActor
    func test_run_continuesWhenAlbumResolutionFails() async {
        let mock = MockImmichClient()
        mock.albumsError = APIError.serverError(500, "boom")
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        source.albums = [deviceAlbum("dev-vac", "Vacances")]
        source.albumMembershipByDeviceAlbum = ["c1": ["dev-vac"]]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept")]
        )
        let service = AlbumSyncService(mapping: AlbumSyncStore(suiteName: suiteName), batchSize: 100)
        let engine = BackupEngine(
            client: mock, source: source, environment: MockBackupEnvironment(),
            ledger: BackupLedger.inMemory(), albumSync: service, userID: { "me" }
        )
        var settings = BackupSettings(isEnabled: true)
        settings.syncedAlbumIDs = ["dev-vac"]

        let started = await engine.run(settings: settings)

        XCTAssertTrue(started)
        XCTAssertEqual(engine.uploadedCount, 1)
        XCTAssertTrue(mock.addAssetsToAlbumCalls.isEmpty)
    }

    // MARK: - The screen's action

    /// The whole chain the button runs: ledger → engine → `bulk-upload-check` →
    /// album, with no second upload and a summary the screen can show.
    @MainActor
    func test_viewModel_reorganizeIntoAlbumsFilesLedgerAssetsWithoutReuploading() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.albums = [deviceAlbum("dev-vac", "Vacances")]
        source.albumMembershipByDeviceAlbum = ["a1": ["dev-vac"]]
        let ledger = BackupLedger.inMemory()
        ledger.markBackedUp(id: "a1", signature: "2024-07-01T00:00:00.000Z", checksum: "sha1-a1")
        let service = AlbumSyncService(mapping: AlbumSyncStore(suiteName: suiteName), batchSize: 100)
        let engine = BackupEngine(
            client: mock, source: source, environment: MockBackupEnvironment(),
            ledger: ledger, albumSync: service, userID: { "me" }
        )
        let settings = BackupSettingsStore(suiteName: "albumSyncSettings-\(suiteName)")
        settings.syncedAlbumIDs = ["dev-vac"]
        let vm = UploadViewModel(
            client: mock, photos: MockPhotoLibraryService(), engine: engine, settings: settings,
            scheduler: MockBackupScheduler(), activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "a1", action: "reject", reason: nil, assetId: "srv-a1", isTrashed: false)
        ])

        XCTAssertTrue(vm.canReorganize)
        await vm.reorganizeIntoAlbums()

        XCTAssertEqual(mock.addAssetsToAlbumCalls.flatMap { $0.ids }, ["srv-a1"])
        XCTAssertTrue(mock.uploads.isEmpty, "le rattrapage ne ré-upload rien")
        XCTAssertEqual(engine.albumSyncOutcome?.added, 1)
        // Through the catalog, not the English source: `String(localized:)`
        // follows the process language, so a hard-coded expectation would test
        // the simulator's language instead of the code (and an exact match is
        // stronger than a `contains`).
        XCTAssertEqual(
            vm.albumSyncSummary,
            localizedString("%lld added · %lld already there · %lld failed", 1, 0, 0)
        )
        XCTAssertNil(vm.albumSyncError)
        XCTAssertFalse(vm.isReorganizing)
    }
}
