import Foundation
import XCTest
@testable import ImmichSwiftUI

/// "Back up new photos automatically" promised real-time detection but only
/// ran a scan at scene activation — no `PHPhotoLibraryChangeObserver` existed.
/// The production observer watches the real Photos library and cannot be
/// exercised in a unit test, so these cover what the wiring relies on: when the
/// observer is allowed to run, and that each insertion reaches the gated run
/// through the engine's own guard. End-to-end behavior is the manual AC-LO08
/// check (a photo taken with the app open starts a run in seconds).
final class PhotoLibraryChangeMonitorTests: XCTestCase {

    @MainActor
    private func store(_ suite: String) -> BackupSettingsStore {
        BackupSettingsStore(suiteName: suite)
    }

    /// Detection without auto-backup is dead weight: every run it starts is
    /// refused by the `isEnabled` gate, so the observer must not run.
    func test_observation_requiresBothToggles() {
        var settings = BackupSettings()
        XCTAssertFalse(settings.shouldObserveLibraryChanges)

        settings.autoDetectNewPhotos = true
        XCTAssertFalse(settings.shouldObserveLibraryChanges, "auto-backup off → rien à déclencher")

        settings.isEnabled = true
        XCTAssertTrue(settings.shouldObserveLibraryChanges)

        settings.autoDetectNewPhotos = false
        XCTAssertFalse(settings.shouldObserveLibraryChanges)
    }

    @MainActor
    func test_settingsStore_snapshotDrivesObservation() {
        let suite = "monitor-\(UUID().uuidString)"
        let settings = store(suite)
        XCTAssertFalse(settings.snapshot().shouldObserveLibraryChanges)

        settings.isEnabled = true
        settings.autoDetectNewPhotos = true
        XCTAssertTrue(settings.snapshot().shouldObserveLibraryChanges)

        settings.isEnabled = false
        XCTAssertFalse(settings.snapshot().shouldObserveLibraryChanges)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    /// Insertion → one run, one upload. A second insertion must not double up:
    /// the ledger already knows the asset.
    @MainActor
    func test_insertedCallback_kicksBackupOnce() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "n1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [makeInsertedCandidate(id: "n1")]
        source.dataProvider = { _ in Data(repeating: 7, count: 8) }
        let settings = store("monitor-kick-\(UUID().uuidString)")
        settings.isEnabled = true
        settings.autoDetectNewPhotos = true
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(), engine: engine, settings: settings,
            scheduler: MockBackupScheduler(), activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )
        let monitor = MockLibraryMonitor()
        let firstWake = expectation(description: "premier réveil terminé")
        let secondWake = expectation(description: "second réveil terminé")
        monitor.onAssetsInserted = { [weak vm] in
            Task { @MainActor in
                await vm?.kickOffAutoBackupIfConfigured()
                await vm?.awaitCurrentBackup()
                firstWake.fulfill()
            }
        }

        monitor.simulateInsertion()
        await fulfillment(of: [firstWake], timeout: 5)
        monitor.onAssetsInserted = { [weak vm] in
            Task { @MainActor in
                await vm?.kickOffAutoBackupIfConfigured()
                await vm?.awaitCurrentBackup()
                secondWake.fulfill()
            }
        }
        monitor.simulateInsertion()
        await fulfillment(of: [secondWake], timeout: 5)

        XCTAssertEqual(client.uploads.count, 1, "un asset inséré = un seul upload, malgré deux réveils")
        XCTAssertEqual(source.exportedIDs, ["n1"], "le second réveil n'exporte pas l'asset déjà sauvegardé")
    }

    /// An insertion arriving while a run owns the engine is dropped, not queued:
    /// `kickOffAutoBackupIfConfigured`'s `!running` guard is the only protection.
    @MainActor
    func test_insertedCallback_ignoredWhileRunInFlight() async {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "n1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [makeInsertedCandidate(id: "n1")]
        source.dataProvider = { _ in Data(repeating: 7, count: 8) }
        let settings = store("monitor-inflight-\(UUID().uuidString)")
        settings.isEnabled = true
        settings.autoDetectNewPhotos = true
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(), engine: engine, settings: settings,
            scheduler: MockBackupScheduler(), activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )
        // Fire the insertion wake-up from inside the running run: the engine is
        // already in `.checking`, so the kick must be a no-op.
        source.onFirstLoad = {
            Task { await vm.kickOffAutoBackupIfConfigured() }
        }

        await vm.runBackup(manual: true)
        await vm.awaitCurrentBackup()

        XCTAssertEqual(client.uploads.count, 1, "le réveil pendant un run n'en démarre pas un second")
        XCTAssertEqual(engine.phase, .done)
    }

    @MainActor
    func test_autoDetectOff_neverKicks() async {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [makeInsertedCandidate(id: "n1")]
        let settings = store("monitor-noautodetect-\(UUID().uuidString)")
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
    func test_monitor_stopIsIdempotent() {
        let monitor = MockLibraryMonitor()
        monitor.stop()
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }
}

private func makeInsertedCandidate(id: String) -> BackupCandidate {
    BackupCandidate(
        id: id, kind: .image, fileName: "\(id).jpg",
        fileCreatedAt: "2024-07-01T00:00:00.000Z",
        fileModifiedAt: "2024-07-01T00:00:00.000Z",
        duration: nil, isFavorite: false
    )
}
