import Foundation
import Photos
import XCTest
@testable import ImmichSwiftUI

// MARK: - BackupSettingsStore scoping + auto-detect (AC-BK01, AC-BK02)

final class BackupSettingsNewFieldsTests: XCTestCase {

    @MainActor
    func test_settingsStore_exposesExcludedAlbumIDs() {
        let suite = "backup-excluded-albums-\(UUID().uuidString)"
        let store = BackupSettingsStore(suiteName: suite)
        XCTAssertTrue(store.excludedAlbumIDs.isEmpty)
        store.excludedAlbumIDs = ["album-1", BackupAlbum.SmartID.videos]
        let fresh = BackupSettingsStore(suiteName: suite)
        XCTAssertEqual(fresh.excludedAlbumIDs, ["album-1", BackupAlbum.SmartID.videos])
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @MainActor
    func test_settingsStore_exposesCellularPolicy() {
        let suite = "backup-cellular-test-\(UUID().uuidString)"
        let store = BackupSettingsStore(suiteName: suite)
        XCTAssertFalse(store.allowCellularForPhotos)
        XCTAssertFalse(store.allowCellularForVideos)
        store.allowCellularForPhotos = true
        let fresh = BackupSettingsStore(suiteName: suite)
        XCTAssertTrue(fresh.allowCellularForPhotos)
        XCTAssertFalse(fresh.allowCellularForVideos)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @MainActor
    func test_settingsStore_exposesAutoDetectNewPhotos() {
        let suite = "backup-autodetect-test-\(UUID().uuidString)"
        let store = BackupSettingsStore(suiteName: suite)
        XCTAssertFalse(store.autoDetectNewPhotos)
        store.autoDetectNewPhotos = true
        let fresh = BackupSettingsStore(suiteName: suite)
        XCTAssertTrue(fresh.autoDetectNewPhotos)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @MainActor
    func test_snapshot_includesNewFields() {
        let suite = "backup-snapshot-test-\(UUID().uuidString)"
        let store = BackupSettingsStore(suiteName: suite)
        store.excludedAlbumIDs = [BackupAlbum.SmartID.bursts]
        store.albumScope = .excluded
        store.allowCellularForVideos = true
        store.autoDetectNewPhotos = true
        let snap = store.snapshot()
        XCTAssertEqual(snap.excludedAlbumIDs, [BackupAlbum.SmartID.bursts])
        XCTAssertTrue(snap.allowCellularForVideos)
        XCTAssertTrue(snap.autoDetectNewPhotos)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

// MARK: - Helpers

private func makeCandidate(id: String, fileName: String) -> BackupCandidate {
    BackupCandidate(
        id: id, kind: .image, fileName: fileName,
        fileCreatedAt: "2024-01-01T00:00:00.000Z",
        fileModifiedAt: "2024-01-01T00:00:00.000Z",
        duration: nil, isFavorite: false
    )
}

@MainActor
private func makeVM(
    client: MockImmichClient,
    source: MockBackupAssetSource,
    settings: BackupSettingsStore,
    photos: MockPhotoLibraryService = MockPhotoLibraryService()
) -> (UploadViewModel, BackupEngine) {
    let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
    let vm = UploadViewModel(
        client: client, photos: photos, engine: engine, settings: settings,
        scheduler: MockBackupScheduler(), activityService: MockBackupLiveActivityService(),
        readOnly: .ephemeral()
    )
    return (vm, engine)
}

// MARK: - UploadViewModel new features (AC-BK03)

final class UploadViewModelNewFeaturesTests: XCTestCase {

    @MainActor
    func test_viewModel_canResumeAfterCompletedRun() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "c1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "c1", fileName: "photo.jpg")]
        source.dataProvider = { _ in Data(repeating: 0, count: 8) }
        let settings = BackupSettingsStore(suiteName: "vm-resume-\(UUID().uuidString)")
        settings.isEnabled = true
        let (vm, engine) = makeVM(client: client, source: source, settings: settings)

        XCTAssertFalse(vm.canResume)
        await vm.runBackup()
        XCTAssertEqual(engine.phase, .done)
        XCTAssertTrue(vm.canResume)
    }

    @MainActor
    func test_viewModel_sharesSettingsStore() {
        // The view binds toggles to $vm.settings.*; the VM must run the
        // engine against that same store, so a toggle flows into the snapshot.
        let settings = BackupSettingsStore(suiteName: "vm-scope-\(UUID().uuidString)")
        let (vm, _) = makeVM(client: MockImmichClient(), source: MockBackupAssetSource(), settings: settings)
        vm.settings.excludedAlbumIDs = [BackupAlbum.SmartID.screenshots]
        vm.settings.albumScope = .excluded
        vm.settings.autoDetectNewPhotos = true
        let snap = vm.settings.snapshot()
        XCTAssertEqual(snap.excludedAlbumIDs, [BackupAlbum.SmartID.screenshots])
        XCTAssertTrue(snap.selectedAlbumIDs.isEmpty, "l'autre ensemble ne part jamais au moteur")
        XCTAssertTrue(snap.autoDetectNewPhotos)
    }

    @MainActor
    func test_viewModel_uploadHistory_populatedOnDone() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "c1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "c1", fileName: "photo1.jpg")]
        source.dataProvider = { _ in Data(repeating: 0, count: 100) }
        let settings = BackupSettingsStore(suiteName: "vm-history-\(UUID().uuidString)")
        settings.isEnabled = true
        let (vm, _) = makeVM(client: client, source: source, settings: settings)

        await vm.runBackup()

        XCTAssertEqual(vm.uploadHistory.count, 1)
        let entry = vm.uploadHistory[0]
        XCTAssertTrue(entry.success)
        XCTAssertEqual(entry.uploaded, 1)
        XCTAssertEqual(entry.total, 1)
        XCTAssertEqual(entry.failed, 0)
    }

    /// "Run now" with the album scope set to a single album is what the removed
    /// Backfill sheet used to do: same manual run, same scoped fetch. Covered
    /// here so the capability it provided can't regress with it.
    @MainActor
    func test_manualRun_scopedToAlbumUploadsIt() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "a1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "a1", fileName: "album-photo.jpg")]
        source.dataProvider = { _ in Data(repeating: 1, count: 64) }
        // Auto-backup OFF: a manual run must still go (explicit user action).
        let settings = BackupSettingsStore(suiteName: "vm-scoped-run-\(UUID().uuidString)")
        settings.isEnabled = false
        settings.selectedAlbumIDs = ["album-42"]
        settings.albumScope = .selected
        let (vm, engine) = makeVM(client: client, source: source, settings: settings)

        vm.resumeUpload()
        await vm.awaitCurrentBackup()

        XCTAssertEqual(source.lastAlbumIDs, ["album-42"], "le run est scopé à l'album choisi")
        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.uploadedCount, 1)
    }
}

// MARK: - Manual vs automatic gating (core Run-now fix)

final class BackupManualRunTests: XCTestCase {

    /// Automatic path (BGTask) with auto-backup OFF must not run.
    @MainActor
    func test_automaticRun_disabled_doesNothing() async {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "x1", fileName: "photo.jpg")]
        let settings = BackupSettingsStore(suiteName: "auto-off-\(UUID().uuidString)")
        settings.isEnabled = false
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings.snapshot(), manual: false)

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertTrue(client.bulkUploadCheckChunks.isEmpty)
    }

    /// Manual "Run now" with auto-backup OFF must still run the pipeline.
    @MainActor
    func test_manualRun_disabled_stillRuns() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "x1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "x1", fileName: "photo.jpg")]
        source.dataProvider = { _ in Data(repeating: 2, count: 32) }
        let settings = BackupSettingsStore(suiteName: "manual-off-\(UUID().uuidString)")
        settings.isEnabled = false
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings.snapshot(), manual: true)

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.uploadedCount, 1)
    }

    /// Manual run ignores the Wi-Fi gate even with no Wi-Fi.
    @MainActor
    func test_manualRun_ignoresWiFiGate() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "x1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "x1", fileName: "photo.jpg")]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        let env = MockBackupEnvironment()
        env.hasWiFiValue = false
        let settings = BackupSettingsStore(suiteName: "manual-nowifi-\(UUID().uuidString)")
        settings.isEnabled = true
        settings.onlyOnWiFi = true
        let engine = BackupEngine(client: client, source: source, environment: env)

        await engine.run(settings: settings.snapshot(), manual: true)

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.uploadedCount, 1)
    }

    /// An automatic run on cellular with "Wi-Fi only" enters the pipeline and
    /// reports the asset instead of refusing the whole run: the choice is per
    /// media kind now, so a refusal at the run level would block photos the
    /// user allowed.
    @MainActor
    func test_automaticRun_cellularDefersInsteadOfBlocking() async {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "x1", fileName: "photo.jpg")]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        let env = MockBackupEnvironment()
        env.hasWiFiValue = false
        let settings = BackupSettingsStore(suiteName: "auto-nowifi-\(UUID().uuidString)")
        settings.isEnabled = true
        settings.onlyOnWiFi = true
        settings.allowCellularForPhotos = false
        let engine = BackupEngine(client: client, source: source, environment: env)

        await engine.run(settings: settings.snapshot(), manual: false)

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.deferredCount, 1)
        XCTAssertEqual(engine.failedCount, 0)
        XCTAssertNil(engine.lastError, "un report n'est pas une erreur")
        XCTAssertEqual(engine.deferralReason, [.waitingForWiFi])
    }

    /// Offline is the one automatic refusal, and it happens before any work.
    @MainActor
    func test_automaticRun_offlineBlocks() async {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "x1", fileName: "photo.jpg")]
        let env = MockBackupEnvironment()
        env.isOnlineValue = false
        let settings = BackupSettingsStore(suiteName: "auto-offline-\(UUID().uuidString)")
        settings.isEnabled = true
        let engine = BackupEngine(client: client, source: source, environment: env)

        let started = await engine.run(settings: settings.snapshot(), manual: false)

        XCTAssertFalse(started)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(source.purgeCount, 0, "aucun octet lu")
        XCTAssertEqual(engine.lastError, localizedString("Backup needs a network connection."))
    }
}

// MARK: - BackupEngine exclusion filtering (AC-BK02 runtime)

/// Album-based exclusion: the album set is resolved by the asset source, so the
/// engine's job is to pass it through and to have no filename opinions at all.
final class BackupEngineExclusionTests: XCTestCase {

    @MainActor
    func test_engine_passesExcludedAlbumIDsToSource() async {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "n1", fileName: "photo.jpg")]
        source.dataProvider = { _ in Data(repeating: 0, count: 50) }
        let settings = BackupSettingsStore(suiteName: "eng-ex-\(UUID().uuidString)")
        settings.isEnabled = true
        settings.excludedAlbumIDs = [BackupAlbum.SmartID.screenshots, "album-42"]
        settings.albumScope = .excluded
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings.snapshot())

        XCTAssertEqual(source.lastExcludedAlbumIDs, [BackupAlbum.SmartID.screenshots, "album-42"])
    }

    /// An excluded album drops its assets before dedup, wherever they'd land.
    @MainActor
    func test_engine_excludedAlbumAssetsNeverReachDedup() async {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [
            makeCandidate(id: "excluded", fileName: "screenshot.png"),
            makeCandidate(id: "kept", fileName: "photo.jpg"),
        ]
        source.excludedAssetIDs = ["excluded"]
        source.dataProvider = { _ in Data(repeating: 0, count: 50) }
        let settings = BackupSettingsStore(suiteName: "eng-ex2-\(UUID().uuidString)")
        settings.isEnabled = true
        settings.excludedAlbumIDs = [BackupAlbum.SmartID.screenshots]
        settings.albumScope = .excluded
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings.snapshot())

        let checkedIDs = client.bulkUploadCheckChunks.flatMap { $0 }.map(\.id)
        XCTAssertEqual(checkedIDs, ["kept"])
        XCTAssertEqual(engine.total, 1)
    }

    /// The filename heuristics are gone: `IMG_*` and `WhatsApp*` are ordinary
    /// assets now. They used to drop nearly a whole iPhone camera roll (IMG_)
    /// or filter nothing at all (WhatsApp).
    @MainActor
    func test_engine_hasNoFilenameHeuristics() async {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [
            makeCandidate(id: "c1", fileName: "IMG_001.jpg"),
            makeCandidate(id: "w1", fileName: "WhatsApp Image 2024.jpg"),
        ]
        source.dataProvider = { _ in Data(repeating: 0, count: 50) }
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "c1", action: "accept"),
            .init(id: "w1", action: "accept"),
        ])
        let settings = BackupSettingsStore(suiteName: "eng-heur-\(UUID().uuidString)")
        settings.isEnabled = true
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings.snapshot())

        XCTAssertEqual(engine.total, 2, "aucun filtre sur le nom de fichier")
        XCTAssertEqual(engine.uploadedCount, 2)
    }

    /// No exclusion configured must mean "everything" — the default has to
    /// widen the scope, not narrow it (the trap the old `IMG_` heuristic fell
    /// into).
    @MainActor
    func test_engine_noExclusionUploadsEverything() async {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = (0..<4).map { makeCandidate(id: "c\($0)", fileName: "photo\($0).jpg") }
        source.dataProvider = { _ in Data(repeating: 0, count: 50) }
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: (0..<4).map { .init(id: "c\($0)", action: "accept") }
        )
        let settings = BackupSettingsStore(suiteName: "eng-none-\(UUID().uuidString)")
        settings.isEnabled = true
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings.snapshot())

        XCTAssertTrue(source.lastExcludedAlbumIDs?.isEmpty ?? false)
        XCTAssertEqual(engine.total, 4)
        XCTAssertEqual(engine.uploadedCount, 4)
    }

    /// The scoping is read from the store at run time, so a change made between
    /// two runs applies to the next one. Fresh ledgers on both sides so the
    /// assertion is about the scoping, not about dedup.
    @MainActor
    func test_engine_exclusionAppliesFromTheNextRun() async {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [
            makeCandidate(id: "a", fileName: "a.jpg"),
            makeCandidate(id: "b", fileName: "b.jpg"),
        ]
        source.dataProvider = { _ in Data(repeating: 0, count: 50) }
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "a", action: "accept"),
            .init(id: "b", action: "accept"),
        ])
        let settings = BackupSettingsStore(suiteName: "eng-live-\(UUID().uuidString)")
        settings.isEnabled = true

        let first = BackupEngine(
            client: client, source: source,
            environment: MockBackupEnvironment(), ledger: BackupLedger.inMemory()
        )
        await first.run(settings: settings.snapshot())
        XCTAssertEqual(first.total, 2)
        XCTAssertEqual(source.exportedIDs, ["a", "b"])

        settings.excludedAlbumIDs = ["album-holidays"]
        settings.albumScope = .excluded
        source.excludedAssetIDs = ["b"]
        let second = BackupEngine(
            client: client, source: source,
            environment: MockBackupEnvironment(), ledger: BackupLedger.inMemory()
        )
        await second.run(settings: settings.snapshot())

        XCTAssertEqual(source.lastExcludedAlbumIDs, ["album-holidays"])
        XCTAssertEqual(second.total, 1, "l'album exclu ne fournit plus de candidat")
        XCTAssertEqual(source.exportedIDs, ["a", "b", "a"], "b n'est plus exporté au 2e run")
    }
}

// MARK: - Auto-detect foreground kick + background chain resubmit

final class BackupAutoChainTests: XCTestCase {

    @MainActor
    func test_kick_runsGatedScanWhenAutoDetectOn() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "n1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "n1", fileName: "n1.jpg")]
        source.dataProvider = { _ in Data(repeating: 7, count: 8) }
        let settings = BackupSettingsStore(suiteName: "kick-on-\(UUID().uuidString)")
        settings.isEnabled = true
        settings.autoDetectNewPhotos = true
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(), engine: engine, settings: settings,
            scheduler: MockBackupScheduler(), activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )

        await vm.kickOffAutoBackupIfConfigured()
        await vm.awaitCurrentBackup()

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.uploadedCount, 1)
    }

    @MainActor
    func test_kick_noopWhenAutoDetectOff() async {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "n1", fileName: "n1.jpg")]
        let settings = BackupSettingsStore(suiteName: "kick-off-\(UUID().uuidString)")
        settings.isEnabled = true
        settings.autoDetectNewPhotos = false
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(), engine: engine, settings: settings,
            scheduler: MockBackupScheduler(), activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )

        await vm.kickOffAutoBackupIfConfigured()
        await vm.awaitCurrentBackup()

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(client.requestCount, 0)
    }

    @MainActor
    func test_chain_notResubmittedWhenAutoBackupOff() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "n1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "n1", fileName: "n1.jpg")]
        source.dataProvider = { _ in Data(repeating: 1, count: 4) }
        let settings = BackupSettingsStore(suiteName: "chain-off-\(UUID().uuidString)")
        settings.isEnabled = false
        let scheduler = MockBackupScheduler()
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(), engine: engine, settings: settings,
            scheduler: scheduler, activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )

        await vm.runBackup(manual: true)

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(scheduler.submitCount, 0, "chaîne non ré-armée quand auto-backup est off")
    }

    @MainActor
    func test_chain_resubmittedAfterEnabledRun() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "n1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "n1", fileName: "n1.jpg")]
        source.dataProvider = { _ in Data(repeating: 1, count: 4) }
        let settings = BackupSettingsStore(suiteName: "chain-on-\(UUID().uuidString)")
        settings.isEnabled = true
        let scheduler = MockBackupScheduler()
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(), engine: engine, settings: settings,
            scheduler: scheduler, activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )

        await vm.runBackup(manual: true)

        XCTAssertEqual(scheduler.submitCount, 1, "un run terminé ré-arme la chaîne (auto-backup on)")
    }
}

// MARK: - No PhotoKit read without a gesture (AC-5, AC-6, AC-7)

@MainActor
final class BackupPhotoAccessTests: XCTestCase {

    private func makeFixture(
        status: PHAuthorizationStatus,
        afterRequest: PHAuthorizationStatus = .authorized,
        autoDetect: Bool = false
    ) -> (UploadViewModel, MockPhotoLibraryService, MockBackupAssetSource, MockImmichClient, BackupEngine) {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [.init(id: "c1", action: "accept")])
        let source = MockBackupAssetSource()
        source.candidates = [makeCandidate(id: "c1", fileName: "c1.jpg")]
        source.albums = [BackupAlbum(id: "trip", name: "Trip", count: 3)]
        source.dataProvider = { _ in Data(repeating: 1, count: 8) }
        let photos = MockPhotoLibraryService()
        photos.status = status
        photos.statusAfterRequest = afterRequest
        let settings = BackupSettingsStore(suiteName: "photo-access-\(UUID().uuidString)")
        settings.isEnabled = true
        settings.autoDetectNewPhotos = autoDetect
        let (vm, engine) = makeVM(client: client, source: source, settings: settings, photos: photos)
        return (vm, photos, source, client, engine)
    }

    func test_AC5_loadAlbums_undetermined_neitherPromptsNorReads() {
        let (vm, photos, source, _, _) = makeFixture(status: .notDetermined)

        vm.loadAlbums()

        XCTAssertEqual(photos.requestCount, 0)
        XCTAssertEqual(source.fetchAlbumsCallCount, 0)
        XCTAssertTrue(vm.albums.isEmpty)
        XCTAssertFalse(vm.canReadPhotoLibrary)
        XCTAssertFalse(vm.isPhotoAccessDenied, "undetermined n'est pas un refus")
    }

    func test_AC5_loadAlbums_deniedOrRestricted_flagsDeniedAndReadsNothing() {
        for status in [PHAuthorizationStatus.denied, .restricted] {
            let (vm, photos, source, _, _) = makeFixture(status: status)

            vm.loadAlbums()

            XCTAssertTrue(vm.isPhotoAccessDenied, "\(status.rawValue)")
            XCTAssertFalse(vm.canReadPhotoLibrary, "\(status.rawValue)")
            XCTAssertEqual(source.fetchAlbumsCallCount, 0, "\(status.rawValue)")
            XCTAssertEqual(photos.requestCount, 0, "\(status.rawValue)")
            XCTAssertTrue(vm.albums.isEmpty, "\(status.rawValue)")
        }
    }

    func test_AC5_loadAlbums_authorizedOrLimited_reads() {
        for status in [PHAuthorizationStatus.authorized, .limited] {
            let (vm, _, source, _, _) = makeFixture(status: status)

            vm.loadAlbums()

            XCTAssertEqual(vm.albums.map(\.id), ["trip"], "\(status.rawValue)")
            XCTAssertEqual(source.fetchAlbumsCallCount, 1, "\(status.rawValue)")
            XCTAssertFalse(vm.isPhotoAccessDenied, "\(status.rawValue)")
        }
    }

    func test_AC5_loadAlbums_followsAGrantMadeInSettings() {
        let (vm, photos, _, _, _) = makeFixture(status: .denied)
        vm.loadAlbums()
        XCTAssertTrue(vm.isPhotoAccessDenied)

        photos.status = .authorized
        vm.loadAlbums()

        XCTAssertFalse(vm.isPhotoAccessDenied)
        XCTAssertEqual(vm.albums.map(\.id), ["trip"])
    }

    func test_AC5_kickOff_undetermined_doesNothing() async {
        let (vm, photos, source, client, engine) = makeFixture(status: .notDetermined, autoDetect: true)

        await vm.kickOffAutoBackupIfConfigured()
        await vm.awaitCurrentBackup()

        XCTAssertEqual(photos.requestCount, 0)
        XCTAssertEqual(client.requestCount, 0, "bulkUploadCheck n'est pas appelé")
        XCTAssertTrue(source.exportedIDs.isEmpty)
        XCTAssertEqual(engine.phase, .idle)
    }

    func test_AC5_unattendedRun_withoutReadableAccess_returnsBeforeAnyReadOrError() async {
        for status in [PHAuthorizationStatus.notDetermined, .denied, .restricted] {
            let (vm, photos, _, client, engine) = makeFixture(status: status)

            await vm.runBackup(manual: false)

            XCTAssertEqual(photos.requestCount, 0, "\(status.rawValue)")
            XCTAssertEqual(client.requestCount, 0, "\(status.rawValue)")
            XCTAssertNil(engine.lastError, "\(status.rawValue) : pas de message d'erreur anglais")
            XCTAssertEqual(engine.phase, .idle, "\(status.rawValue)")
        }
    }

    func test_AC5_unattendedRun_withAccess_stillRuns() async {
        let (vm, _, _, _, engine) = makeFixture(status: .authorized)

        await vm.runBackup(manual: false)

        XCTAssertEqual(engine.phase, .done)
    }

    func test_AC6_manualRun_undeterminedThenDenied_promptsOnceAndStaysSilent() async {
        let (vm, photos, _, client, engine) = makeFixture(status: .notDetermined, afterRequest: .denied)

        await vm.runBackup(manual: true)

        XCTAssertEqual(photos.requestCount, 1)
        XCTAssertTrue(vm.isPhotoAccessDenied)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(client.requestCount, 0)
        XCTAssertEqual(engine.phase, .idle)
    }

    func test_AC6_manualRun_undeterminedThenGranted_runs() async {
        let (vm, photos, _, _, engine) = makeFixture(status: .notDetermined, afterRequest: .authorized)

        await vm.runBackup(manual: true)

        XCTAssertEqual(photos.requestCount, 1)
        XCTAssertTrue(vm.canReadPhotoLibrary)
        XCTAssertEqual(engine.phase, .done)
    }

    func test_AC6_ensurePhotoAccess_alreadyDetermined_neverPrompts() async {
        for (status, expected) in [(PHAuthorizationStatus.authorized, true), (.limited, true), (.denied, false), (.restricted, false)] {
            let (vm, photos, _, _, _) = makeFixture(status: status)

            let granted = await vm.ensurePhotoAccess()

            XCTAssertEqual(granted, expected, "\(status.rawValue)")
            XCTAssertEqual(photos.requestCount, 0, "\(status.rawValue)")
        }
    }

    func test_AC6_prepareAlbumPicker_undeterminedThenGranted_loadsAlbums() async {
        let (vm, photos, _, _, _) = makeFixture(status: .notDetermined, afterRequest: .authorized)

        await vm.prepareAlbumPicker()

        XCTAssertEqual(photos.requestCount, 1)
        XCTAssertEqual(vm.albums.map(\.id), ["trip"])
    }

    func test_AC6_prepareAlbumPicker_undeterminedThenDenied_leavesTheListEmpty() async {
        let (vm, photos, source, _, _) = makeFixture(status: .notDetermined, afterRequest: .denied)

        await vm.prepareAlbumPicker()

        XCTAssertEqual(photos.requestCount, 1)
        XCTAssertTrue(vm.albums.isEmpty)
        XCTAssertEqual(source.fetchAlbumsCallCount, 0)
        XCTAssertTrue(vm.isPhotoAccessDenied)
    }
}
