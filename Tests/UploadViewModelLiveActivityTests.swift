import XCTest
@testable import ImmichSwiftUI

/// Live Activity lifecycle driven by `UploadViewModel.runBackup()` (P2
/// backup-live-activity). ActivityKit itself is never touched — the service
/// seam is a recorder.
final class UploadViewModelLiveActivityTests: XCTestCase {

    @MainActor
    private func makeAcceptedClient(candidates: [String]) -> MockImmichClient {
        let mock = MockImmichClient()
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: candidates.map { AssetBulkUploadCheckResponse.Result(id: $0, action: "accept") }
        )
        return mock
    }

    @MainActor
    private func makeEngine(client: MockImmichClient, candidates: [String]) -> BackupEngine {
        let source = MockBackupAssetSource()
        source.candidates = candidates.map { id in
            BackupCandidate(
                id: id, kind: .image, fileName: "\(id).jpg",
                fileCreatedAt: "2024-07-01T00:00:00.000Z",
                fileModifiedAt: "2024-07-01T00:00:00.000Z",
                duration: nil, isFavorite: false
            )
        }
        return BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
    }

    @MainActor
    private func makeEnabledStore() -> BackupSettingsStore {
        let suite = "backup-live-vm-\(UUID().uuidString)"
        let store = BackupSettingsStore(suiteName: suite)
        store.isEnabled = true
        return store
    }

    @MainActor
    func test_liveActivity_startThenUpdateThenEndOnDone() async {
        let client = makeAcceptedClient(candidates: ["c1", "c2", "c3"])
        let engine = makeEngine(client: client, candidates: ["c1", "c2", "c3"])
        let scheduler = MockBackupScheduler()
        let activity = MockBackupLiveActivityService()
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(),
            engine: engine, settings: makeEnabledStore(),
            scheduler: scheduler, activityService: activity,
            readOnly: .ephemeral()
        )

        await vm.runBackup()

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(activity.startCalls.count, 1)
        XCTAssertEqual(activity.startCalls[0].total, 0, "total unknown until filters run")
        XCTAssertEqual(activity.updateCalls.count, 6,
                       "3 stagings (export+hash) puis 3 uploads — la barre bouge sur les deux moitiés")
        XCTAssertEqual(activity.updateCalls[0].total, 3, "denominator fixed at the candidate count")
        XCTAssertEqual(activity.updateCalls[0].processed, 1, "1 asset examiné dès son hash")
        XCTAssertEqual(activity.updateCalls[5].processed, 3)
        XCTAssertEqual(activity.updateCalls[5].total, 3)
        XCTAssertEqual(activity.endCalls.count, 1)
        XCTAssertEqual(activity.endCalls[0].processed, 3)
        XCTAssertEqual(activity.endCalls[0].total, 3)
        XCTAssertEqual(activity.endCalls[0].success, true)
        XCTAssertEqual(scheduler.submitCount, 1)
    }

    @MainActor
    func test_liveActivity_cancelEndsWithFailure() async {
        let client = makeAcceptedClient(candidates: ["c1"])
        let source = MockBackupAssetSource()
        source.candidates = [BackupCandidate(
            id: "c1", kind: .image, fileName: "c1.jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            duration: nil, isFavorite: false
        )]
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
        source.onFirstLoad = { [weak engine] in
            engine?.cancel()
        }
        let scheduler = MockBackupScheduler()
        let activity = MockBackupLiveActivityService()
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(),
            engine: engine, settings: makeEnabledStore(),
            scheduler: scheduler, activityService: activity,
            readOnly: .ephemeral()
        )

        await vm.runBackup()

        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertEqual(activity.endCalls.count, 1)
        XCTAssertEqual(activity.endCalls[0].success, false)
        XCTAssertEqual(scheduler.submitCount, 0, "pas de reschedule après annulation")
    }

    /// AC-2 : après un Stop, « Retry all » puis Run now démarrent (Live Activity
    /// démarrée et terminée, historique ajouté sur `.done`).
    @MainActor
    func test_AC2_runNowAndRetryAllFailedStartAfterStop() async {
        let ids = ["c1", "c2", "c3"]
        let client = makeAcceptedClient(candidates: ids)
        let source = MockBackupAssetSource()
        source.candidates = ids.map { id in
            BackupCandidate(
                id: id, kind: .image, fileName: "\(id).jpg",
                fileCreatedAt: "2024-07-01T00:00:00.000Z",
                fileModifiedAt: "2024-07-01T00:00:00.000Z",
                duration: nil, isFavorite: false
            )
        }
        source.failIDs = ["c1"]
        source.exportGate = { id in if id == "c2" { try await suspendUntilCancelled() } }
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
        let activity = MockBackupLiveActivityService()
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(),
            engine: engine, settings: makeEnabledStore(),
            scheduler: MockBackupScheduler(), activityService: activity,
            readOnly: .ephemeral()
        )
        let first = Task { @MainActor in await vm.runBackup(manual: true) }
        await pollUntil("export de c2 en vol") { source.exportedIDs.contains("c2") }

        vm.cancelBackup()
        await first.value

        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertEqual(engine.failures.map(\.assetID), ["c1"])

        source.failIDs = []
        source.exportGate = nil
        await vm.retryAllFailed()

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(vm.uploadHistory.count, 1)

        vm.resumeUpload()
        await vm.awaitCurrentBackup()

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(vm.uploadHistory.count, 2)
        XCTAssertEqual(activity.startCalls.count, 3)
        XCTAssertEqual(activity.endCalls.count, 3)
        XCTAssertEqual(activity.endCalls[0].success, false)
        XCTAssertEqual(activity.endCalls[1].success, true)
        XCTAssertEqual(activity.endCalls[2].success, true)
    }

    /// AC-4 : une expiration BG (hop vers le main actor depuis une file de fond)
    /// n'annule que le run en vol ; une expiration tardive est sans effet.
    @MainActor
    func test_AC4_bgExpirationCancelsOnlyTheRunInFlight() async {
        let client = makeAcceptedClient(candidates: ["c1"])
        let engine = makeEngine(client: client, candidates: ["c1"])
        let scheduler = MockBackupScheduler()
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(),
            engine: engine, settings: makeEnabledStore(),
            scheduler: scheduler, activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )
        client.uploadGate = suspendUntilCancelled
        let bgRun = Task { @MainActor in await vm.runBackup() }
        await pollUntil("upload en vol") { client.uploads.count == 1 }

        // Ce que fait `expirationHandler` : appel depuis une file de fond.
        await Task.detached { await MainActor.run { engine.cancel() } }.value
        await bgRun.value

        XCTAssertEqual(engine.phase, .cancelled)
        let success = engine.phase == .done && engine.failedCount == 0
        XCTAssertFalse(success, "setTaskCompleted(success: false)")
        XCTAssertEqual(scheduler.submitCount, 0)

        await Task.detached { await MainActor.run { engine.cancel() } }.value
        XCTAssertFalse(engine.isCancelling, "expiration tardive : sans effet")

        client.uploadGate = nil
        await vm.runBackup()

        XCTAssertEqual(engine.phase, .done)
    }

    @MainActor
    func test_liveActivity_disabledSettingsEndsActivityWithoutUpdates() async {
        let client = makeAcceptedClient(candidates: ["c1"])
        let engine = makeEngine(client: client, candidates: ["c1"])
        let store = makeEnabledStore()
        store.isEnabled = false
        let activity = MockBackupLiveActivityService()
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(),
            engine: engine, settings: store,
            scheduler: MockBackupScheduler(), activityService: activity,
            readOnly: .ephemeral()
        )

        await vm.runBackup()

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(activity.startCalls.count, 1)
        XCTAssertTrue(activity.updateCalls.isEmpty)
        XCTAssertEqual(activity.endCalls.count, 1,
                       "un run bloqué par une gate ne doit pas laisser d'activité orpheline dans l'île")
        XCTAssertFalse(activity.endCalls[0].success)
    }

    /// A gate that refuses the run must still close the activity it opened —
    /// otherwise the island sits at "Scanning… 0 %" for hours and the next real
    /// run inherits a stale one. Offline is the automatic refusal that remains.
    @MainActor
    func test_liveActivity_offlineGateBlocksNoUpdates() async {
        let client = makeAcceptedClient(candidates: ["c1"])
        let store = makeEnabledStore()
        let env = MockBackupEnvironment()
        env.isOnlineValue = false
        let engineOffline = BackupEngine(client: client, source: MockBackupAssetSource(), environment: env)
        let activity = MockBackupLiveActivityService()
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(),
            engine: engineOffline, settings: store,
            scheduler: MockBackupScheduler(), activityService: activity,
            readOnly: .ephemeral()
        )

        await vm.runBackup()

        XCTAssertEqual(engineOffline.phase, .idle)
        XCTAssertEqual(engineOffline.lastError, localizedString("Backup needs a network connection."))
        XCTAssertTrue(activity.updateCalls.isEmpty)
        XCTAssertEqual(activity.endCalls.count, 1,
                       "gate hors ligne : l'activité démarrée est refermée, pas laissée en 'Scanning…'")
    }

    @MainActor
    func test_liveActivity_hookClearedAfterRun() async {
        let client = makeAcceptedClient(candidates: ["c1"])
        let engine = makeEngine(client: client, candidates: ["c1"])
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(),
            engine: engine, settings: makeEnabledStore(),
            scheduler: MockBackupScheduler(), activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )

        await vm.runBackup()

        XCTAssertNil(engine.onProgressUpdate, "le hook est retiré en fin de run")
    }

    @MainActor
    func test_liveActivity_tracksProcessedNotUploaded() async {
        // c1 uploads, c2 is already on the server (reject), c3's iCloud original
        // isn't ready (defer). The Live Activity must advance for all three —
        // matching the in-app processedCount/total bar — not just the upload.
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [
                AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept"),
                AssetBulkUploadCheckResponse.Result(id: "c2", action: "reject", reason: "duplicate"),
            ]
        )
        let source = MockBackupAssetSource()
        source.candidates = ["c1", "c2", "c3"].map { id in
            BackupCandidate(
                id: id, kind: .image, fileName: "\(id).jpg",
                fileCreatedAt: "2024-07-01T00:00:00.000Z",
                fileModifiedAt: "2024-07-01T00:00:00.000Z",
                duration: nil, isFavorite: false
            )
        }
        source.deferIDs = ["c3"]
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
        let activity = MockBackupLiveActivityService()
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(),
            engine: engine, settings: makeEnabledStore(),
            scheduler: MockBackupScheduler(), activityService: activity,
            readOnly: .ephemeral()
        )

        await vm.runBackup()

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.processedCount, 3)
        XCTAssertEqual(activity.updateCalls.map(\.total), [3, 3, 3, 3, 3], "denominator fixed at candidate count")
        XCTAssertEqual(activity.updateCalls.map(\.processed), [1, 2, 3, 3, 3],
                       "avance au hash de c1/c2, au defer de c3, puis au reject et à l'upload — jamais figée")
        XCTAssertEqual(activity.endCalls.count, 1)
        XCTAssertEqual(activity.endCalls[0].processed, 3)
        XCTAssertEqual(activity.endCalls[0].total, 3)
        XCTAssertTrue(activity.endCalls[0].success, "no failures → success")
    }

    @MainActor
    func test_liveActivity_snapshotCarriesBreakdownAndPhase() async {
        // c1 uploads, c2 is already on the server, c3's iCloud original is
        // deferred. The widget's chips/celebration depend on the full
        // breakdown + phase, so they must ride along in every snapshot.
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [
                AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept"),
                AssetBulkUploadCheckResponse.Result(id: "c2", action: "reject", reason: "duplicate"),
            ]
        )
        let source = MockBackupAssetSource()
        source.candidates = ["c1", "c2", "c3"].map { id in
            BackupCandidate(
                id: id, kind: .image, fileName: "\(id).jpg",
                fileCreatedAt: "2024-07-01T00:00:00.000Z",
                fileModifiedAt: "2024-07-01T00:00:00.000Z",
                duration: nil, isFavorite: false
            )
        }
        source.deferIDs = ["c3"]
        let engine = BackupEngine(client: client, source: source, environment: MockBackupEnvironment())
        let activity = MockBackupLiveActivityService()
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(),
            engine: engine, settings: makeEnabledStore(),
            scheduler: MockBackupScheduler(), activityService: activity,
            readOnly: .ephemeral()
        )

        await vm.runBackup()

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(activity.startSnapshots.first?.phase, .checking)
        guard let last = activity.updateSnapshots.last else {
            return XCTFail("expected at least one update snapshot")
        }
        XCTAssertEqual(last.processed, 3)
        XCTAssertEqual(last.uploaded, 1)
        XCTAssertEqual(last.onServer, 1)
        XCTAssertEqual(last.waiting, 1)
        XCTAssertEqual(last.failed, 0)
        XCTAssertEqual(last.phase, .uploading, "final tick happens during the upload phase")
        XCTAssertEqual(activity.endSnapshots.count, 1)
        XCTAssertEqual(activity.endSnapshots[0].snapshot.phase, .done)
        XCTAssertTrue(activity.endSnapshots[0].success, "no failures → success")
    }
}