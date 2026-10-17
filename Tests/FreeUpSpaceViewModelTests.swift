import Foundation
import Photos
import XCTest
@testable import ImmichSwiftUI

/// Photo-library stand-in for the cleanup scan.
///
/// It honors the one contract that keeps the feature safe — a candidate only
/// exists if the *server* confirmed it, which is why `cleanupCandidates` is
/// given `backedUpIDs` and filters on it. A mock that ignored it would let a
/// test assert a deletion the production source can never offer.
final class MockCleanupSource: LocalCleanupSource, @unchecked Sendable {
    /// What the library holds, whatever the server says.
    nonisolated(unsafe) var candidates: [CleanupCandidate] = []
    /// Assets the library holds but that live in an iCloud Shared Album —
    /// counted, never offered.
    nonisolated(unsafe) var skippedInSharedAlbum = 0
    /// Overrides the reported inspected count; defaults to what was offered.
    nonisolated(unsafe) var scannedCountOverride: Int?
    /// The destructive step's only failure mode.
    nonisolated(unsafe) var deleteError: Error?

    nonisolated(unsafe) var lastCutoff: Date?
    nonisolated(unsafe) var lastKeepFavorites: Bool?
    nonisolated(unsafe) var lastKeepMediaType: CleanupKeepMediaType?
    nonisolated(unsafe) var lastKeepAlbumIDs: Set<String>?
    nonisolated(unsafe) var lastBackedUpIDs: Set<String>?
    nonisolated(unsafe) var deletedIDs: [String] = []

    func cleanupCandidates(
        cutoff: Date,
        keepFavorites: Bool,
        keepMediaType: CleanupKeepMediaType,
        keepAlbumIDs: Set<String>,
        backedUpIDs: Set<String>
    ) -> CleanupScanResult {
        lastCutoff = cutoff
        lastKeepFavorites = keepFavorites
        lastKeepMediaType = keepMediaType
        lastKeepAlbumIDs = keepAlbumIDs
        lastBackedUpIDs = backedUpIDs
        let offered = candidates.filter { backedUpIDs.contains($0.id) }
        return CleanupScanResult(
            candidates: offered,
            skippedNotOnServer: 0,
            skippedInSharedAlbum: skippedInSharedAlbum,
            scannedCount: scannedCountOverride ?? offered.count
        )
    }

    func deleteLocalAssets(ids: [String]) async throws -> Int {
        deletedIDs = ids
        if let deleteError { throw deleteError }
        return ids.count
    }
}

@MainActor
final class FreeUpSpaceViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func candidate(_ id: String, bytes: Int64 = 1_000, favorite: Bool = false) -> CleanupCandidate {
        CleanupCandidate(
            id: id,
            kind: .image,
            fileName: "\(id).jpg",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            byteSize: bytes,
            isFavorite: favorite
        )
    }

    /// A store on its own throwaway suite, removed when the test ends — the
    /// filters are persisted, so a shared suite would leak state between tests.
    private func makeSettings() -> CleanupSettingsStore {
        let suite = "cleanup-tests-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return CleanupSettingsStore(suiteName: suite)
    }

    private func makeViewModel(
        client: MockImmichClient,
        ledger: BackupLedger,
        source: MockCleanupSource = MockCleanupSource(),
        albums: [BackupAlbum] = [],
        photos: MockPhotoLibraryService = MockPhotoLibraryService(),
        albumSource: MockBackupAssetSource = MockBackupAssetSource()
    ) -> FreeUpSpaceViewModel {
        if !albums.isEmpty { albumSource.albums = albums }
        return FreeUpSpaceViewModel(
            client: client,
            source: source,
            albumSource: albumSource,
            photoLibrary: photos,
            ledger: ledger,
            settings: makeSettings()
        )
    }

    private func ledger(_ ids: [String]) -> BackupLedger {
        let ledger = BackupLedger.inMemory()
        for id in ids {
            ledger.markBackedUp(id: id, signature: "sig-\(id)", checksum: "sum-\(id)")
        }
        return ledger
    }

    private func serverHolds(_ ids: [String]) -> AssetBulkUploadCheckResponse {
        AssetBulkUploadCheckResponse(results: ids.map { .init(id: $0, action: "reject") })
    }

    // MARK: - Scan

    @MainActor
    func test_scan_keepsOnlyAssetsTheServerStillHas() async {
        let client = MockImmichClient()
        let ledger = ledger(["a", "b"])
        // The server confirms `a` only. `b` is still tracked locally but no
        // longer on the server (deleted, purged, another account): its local
        // original is the LAST copy there is.
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "a", action: "reject"),
            .init(id: "b", action: "accept"),
        ])
        let source = MockCleanupSource()
        source.candidates = [candidate("a"), candidate("b")]
        let vm = makeViewModel(client: client, ledger: ledger, source: source)
        vm.setCutoff(Date())

        await vm.scan()

        XCTAssertEqual(vm.candidates.map(\.id), ["a"])
        XCTAssertEqual(source.lastBackedUpIDs, ["a"], "seules les preuves serveur atteignent la source")
        XCTAssertEqual(vm.skippedNotOnServer, 1)

        await vm.deleteConfirmed()

        XCTAssertEqual(source.deletedIDs, ["a"], "un asset non prouvé sauvegardé ne quitte jamais l'appareil")
    }

    @MainActor
    func test_scan_chunksTheServerCheckAtOneHundred() async {
        let client = MockImmichClient()
        let ledger = ledger((0..<250).map { "a\($0)" })
        client.bulkUploadCheckResponse = serverHolds([])
        let vm = makeViewModel(client: client, ledger: ledger)
        vm.setCutoff(Date())

        await vm.scan()

        XCTAssertEqual(client.bulkUploadCheckChunks.count, 3, "100 + 100 + 50")
        XCTAssertEqual(client.bulkUploadCheckChunks[0].count, 100)
        XCTAssertEqual(client.bulkUploadCheckChunks[2].count, 50)
    }

    @MainActor
    func test_scan_requiresACutoffDate() async {
        let client = MockImmichClient()
        let source = MockCleanupSource()
        source.candidates = [candidate("a")]
        let vm = makeViewModel(client: client, ledger: ledger(["a"]), source: source)

        await vm.scan()

        XCTAssertEqual(client.requestCount, 0, "sans date de coupure il n'y a rien à comparer")
        XCTAssertTrue(vm.candidates.isEmpty)
        XCTAssertEqual(vm.scannedCount, 0)
        XCTAssertNil(source.lastCutoff)
    }

    @MainActor
    func test_scan_passesTheFiltersAndTheCutoffToTheSource() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = serverHolds(["a"])
        let source = MockCleanupSource()
        source.candidates = [candidate("a")]
        source.skippedInSharedAlbum = 4
        // `scan()` now reads the albums first and prunes the kept ones absent
        // from them: the album the test keeps has to exist in the library.
        let vm = makeViewModel(
            client: client, ledger: ledger(["a"]), source: source,
            albums: [BackupAlbum(id: "album-1", name: "Trip", count: 1)]
        )
        let cutoff = Date(timeIntervalSince1970: 1_600_000_000)
        vm.setKeepFavorites(false)
        vm.setKeepMediaType(.videos)
        vm.toggleKeepAlbum("album-1")
        vm.setCutoff(cutoff)

        await vm.scan()

        XCTAssertEqual(source.lastCutoff, cutoff)
        XCTAssertEqual(source.lastKeepFavorites, false)
        XCTAssertEqual(source.lastKeepMediaType, .videos)
        XCTAssertEqual(source.lastKeepAlbumIDs, ["album-1"])
        XCTAssertEqual(vm.skippedInSharedAlbum, 4)
        XCTAssertFalse(vm.hasNothingToFreeUp, "un candidat trouvé n'est pas « rien à libérer »")
    }

    @MainActor
    func test_changingAFilter_discardsTheScan() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = serverHolds(["a"])
        let source = MockCleanupSource()
        source.candidates = [candidate("a")]
        let vm = makeViewModel(client: client, ledger: ledger(["a"]), source: source)

        let mutations: [(String, (FreeUpSpaceViewModel) -> Void)] = [
            ("la date de coupure", { $0.setCutoff(nil) }),
            ("les favoris", { $0.setKeepFavorites(false) }),
            ("la catégorie", { $0.setKeepMediaType(.photos) }),
            ("un album conservé", { $0.toggleKeepAlbum("album-1") }),
        ]
        for (label, mutate) in mutations {
            vm.setCutoff(Date())
            await vm.scan()
            XCTAssertEqual(vm.candidates.count, 1, "précondition : \(label)")

            mutate(vm)

            XCTAssertTrue(vm.candidates.isEmpty, "changer \(label) doit invalider le scan")
            XCTAssertEqual(vm.scannedCount, 0, "changer \(label) doit invalider le scan")
        }
    }

    // MARK: - Settings

    @MainActor
    func test_applyDefaultKeepAlbums_runsOnceAndMatchesMessagingNames() {
        let store = makeSettings()
        let albums = [
            BackupAlbum(id: "whatsapp-id", name: "WhatsApp", count: 12),
            BackupAlbum(id: "camera-id", name: "Camera", count: 900),
            BackupAlbum(id: "viber-id", name: "Viber Images", count: 3),
        ]

        store.applyDefaultKeepAlbums(albums)

        XCTAssertEqual(store.keepAlbumIDs, ["whatsapp-id", "viber-id"])
        XCTAssertTrue(store.defaultsInitialized)

        // The user unchecks everything; the defaults must not come back on the
        // next appearance, or the toggle becomes unusable.
        store.keepAlbumIDs = []
        store.applyDefaultKeepAlbums(albums)

        XCTAssertTrue(store.keepAlbumIDs.isEmpty)
    }

    @MainActor
    func test_pruneStaleAlbums_dropsVanishedAlbums() {
        let store = makeSettings()
        store.keepAlbumIDs = ["kept", "deleted-in-photos"]

        store.pruneStaleAlbums(existing: ["kept", "other"])

        XCTAssertEqual(store.keepAlbumIDs, ["kept"])
    }

    // MARK: - Deletion

    @MainActor
    func test_deleteConfirmed_reportsCountAndClearsCandidates() async {
        let client = MockImmichClient()
        let ledger = ledger(["a", "b"])
        client.bulkUploadCheckResponse = serverHolds(["a", "b"])
        let source = MockCleanupSource()
        source.candidates = [candidate("a"), candidate("b")]
        let vm = makeViewModel(client: client, ledger: ledger, source: source)
        vm.setCutoff(Date())
        await vm.scan()

        let deleted = await vm.deleteConfirmed()

        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(source.deletedIDs, ["a", "b"])
        XCTAssertTrue(vm.candidates.isEmpty)
        XCTAssertEqual(vm.scannedCount, 0)
        XCTAssertEqual(vm.lastDeletedCount, 2)
        XCTAssertEqual(ledger.trackedCount(), 2,
                       "le ledger n'est pas purgé : les originaux sont toujours sur le serveur")
    }

    @MainActor
    func test_deleteFailure_keepsCandidatesAndSurfacesTheError() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = serverHolds(["a"])
        let source = MockCleanupSource()
        source.candidates = [candidate("a")]
        source.deleteError = APIError.decoding("Photos refused the change")
        let vm = makeViewModel(client: client, ledger: ledger(["a"]), source: source)
        vm.setCutoff(Date())
        await vm.scan()

        let deleted = await vm.deleteConfirmed()

        XCTAssertNil(deleted)
        XCTAssertEqual(vm.candidates.map(\.id), ["a"], "un échec laisse la liste supprimable telle quelle")
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.lastDeletedCount)
    }

    @MainActor
    func test_deleteConfirmed_withNothingToDelete_doesNotTouchTheLibrary() async {
        let source = MockCleanupSource()
        let vm = makeViewModel(client: MockImmichClient(), ledger: BackupLedger.inMemory(), source: source)

        let deleted = await vm.deleteConfirmed()

        XCTAssertNil(deleted)
        XCTAssertTrue(source.deletedIDs.isEmpty)
    }

    // MARK: - Photos access (AC-5, AC-6, AC-7)

    @MainActor
    func test_AC5_loadAlbums_withoutReadableAccess_readsNothingAndKeepsTheKeptAlbums() {
        for status in [PHAuthorizationStatus.notDetermined, .denied, .restricted] {
            let photos = MockPhotoLibraryService()
            photos.status = status
            let albumSource = MockBackupAssetSource()
            albumSource.albums = [BackupAlbum(id: "other", name: "Other", count: 1)]
            let vm = makeViewModel(
                client: MockImmichClient(), ledger: BackupLedger.inMemory(),
                photos: photos, albumSource: albumSource
            )
            vm.settings.keepAlbumIDs = ["kept"]

            vm.loadAlbums()

            XCTAssertEqual(albumSource.fetchAlbumsCallCount, 0, "\(status.rawValue) : aucune lecture PhotoKit")
            XCTAssertEqual(photos.requestCount, 0, "\(status.rawValue) : aucun prompt sans geste")
            XCTAssertEqual(vm.settings.keepAlbumIDs, ["kept"], "\(status.rawValue) : pas de prune sur une liste illisible")
            XCTAssertFalse(vm.settings.defaultsInitialized, "\(status.rawValue) : les défauts ne sont pas consommés")
            XCTAssertFalse(vm.hasLoadedAlbums)
        }
    }

    @MainActor
    func test_AC5_loadAlbums_withLimitedAccess_reads() {
        let photos = MockPhotoLibraryService()
        photos.status = .limited
        let albumSource = MockBackupAssetSource()
        let vm = makeViewModel(
            client: MockImmichClient(), ledger: BackupLedger.inMemory(),
            photos: photos, albumSource: albumSource
        )

        vm.loadAlbums()

        XCTAssertEqual(albumSource.fetchAlbumsCallCount, 1)
        XCTAssertTrue(vm.hasLoadedAlbums)
    }

    @MainActor
    func test_AC6_scan_undeterminedThenGranted_loadsAlbumsBeforeTheFirstSearch() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = serverHolds(["a"])
        let source = MockCleanupSource()
        source.candidates = [candidate("a")]
        let photos = MockPhotoLibraryService()
        photos.status = .notDetermined
        photos.statusAfterRequest = .authorized
        let albumSource = MockBackupAssetSource()
        albumSource.albums = [
            BackupAlbum(id: "whatsapp-id", name: "WhatsApp", count: 12),
            BackupAlbum(id: "camera-id", name: "Camera", count: 900),
        ]
        let vm = makeViewModel(
            client: client, ledger: ledger(["a"]), source: source,
            photos: photos, albumSource: albumSource
        )
        vm.setCutoff(Date())

        await vm.scan()

        XCTAssertEqual(photos.requestCount, 1)
        XCTAssertEqual(albumSource.fetchAlbumsCallCount, 1)
        XCTAssertEqual(source.lastKeepAlbumIDs, ["whatsapp-id"],
                       "les albums de messagerie sont gardés dès le premier scan")
        XCTAssertEqual(vm.candidates.map(\.id), ["a"])

        await vm.scan()

        XCTAssertEqual(albumSource.fetchAlbumsCallCount, 1, "les albums ne sont relus qu'une fois par VM")
        XCTAssertEqual(photos.requestCount, 1)
    }

    @MainActor
    func test_AC6_scan_undeterminedThenDenied_searchesNothing() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = serverHolds(["a"])
        let source = MockCleanupSource()
        source.candidates = [candidate("a")]
        let photos = MockPhotoLibraryService()
        photos.status = .notDetermined
        photos.statusAfterRequest = .denied
        let albumSource = MockBackupAssetSource()
        let vm = makeViewModel(
            client: client, ledger: ledger(["a"]), source: source,
            photos: photos, albumSource: albumSource
        )
        vm.setCutoff(Date())

        await vm.scan()

        XCTAssertEqual(photos.requestCount, 1)
        XCTAssertNil(source.lastCutoff, "cleanupCandidates n'est jamais appelé")
        XCTAssertEqual(client.requestCount, 0, "aucune requête réseau")
        XCTAssertFalse(vm.isScanning)
        XCTAssertEqual(albumSource.fetchAlbumsCallCount, 0)
        XCTAssertTrue(vm.isPhotoAccessDenied)
        XCTAssertFalse(vm.canScan, "le bouton Scan est désactivé tant que l'accès est refusé")
    }

    @MainActor
    func test_AC6_prepareAlbumPicker_undeterminedThenGranted_loadsAlbums() async {
        let photos = MockPhotoLibraryService()
        photos.status = .notDetermined
        photos.statusAfterRequest = .authorized
        let albumSource = MockBackupAssetSource()
        albumSource.albums = [BackupAlbum(id: "trip", name: "Trip", count: 3)]
        let vm = makeViewModel(
            client: MockImmichClient(), ledger: BackupLedger.inMemory(),
            photos: photos, albumSource: albumSource
        )

        await vm.prepareAlbumPicker()

        XCTAssertEqual(photos.requestCount, 1)
        XCTAssertEqual(vm.albums.map(\.id), ["trip"])
    }
}
