import CryptoKit
import Foundation
import Observation
import Photos
import XCTest
@testable import ImmichSwiftUI

final class BackupEngineTests: XCTestCase {

    private func candidate(
        _ id: String,
        kind: BackupAssetKind = .image,
        favorite: Bool = false,
        livePhoto: Bool = false
    ) -> BackupCandidate {
        BackupCandidate(
            id: id, kind: kind,
            fileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            duration: kind == .video ? 12 : nil,
            isFavorite: favorite,
            isLivePhoto: livePhoto
        )
    }

    private func settings(
        enabled: Bool = true,
        wifi: Bool = false,
        charging: Bool = false,
        cellularPhotos: Bool = false,
        cellularVideos: Bool = false,
        excludedAlbums: Set<String> = [],
        albums: Set<String> = []
    ) -> BackupSettings {
        BackupSettings(
            isEnabled: enabled,
            onlyOnWiFi: wifi,
            onlyWhenCharging: charging,
            allowCellularForPhotos: cellularPhotos,
            allowCellularForVideos: cellularVideos,
            excludedAlbumIDs: excludedAlbums,
            selectedAlbumIDs: albums
        )
    }

    // MARK: - Contrat "le run a-t-il démarré ?"

    /// Automatic runs are gated on being online — not on "is there Wi-Fi":
    /// the per-asset cellular policy decides the rest inside the pipeline.
    @MainActor
    func test_run_reportsStartedOnlyWhenPipelineEntered() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        let env = MockBackupEnvironment()
        env.hasWiFiValue = false
        let engine = BackupEngine(client: mock, source: source, environment: env)

        let disabled = await engine.run(settings: settings(enabled: false))
        XCTAssertFalse(disabled, "auto-backup off → le run n'entre pas dans le pipeline")
        XCTAssertEqual(engine.phase, .idle)

        env.isOnlineValue = false
        let offline = await engine.run(settings: settings())
        XCTAssertFalse(offline, "hors ligne → pas de run")
        XCTAssertEqual(engine.phase, .idle)

        env.isOnlineValue = true
        let ran = await engine.run(settings: settings())
        XCTAssertTrue(ran)
        XCTAssertEqual(engine.phase, .done)
    }

    // MARK: - Cœur: dédup + upload + progression

    @MainActor
    func test_backup_acceptAndRejectMix() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2"), candidate("c3")]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [
                AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept"),
                AssetBulkUploadCheckResponse.Result(id: "c2", action: "reject", reason: "duplicate"),
                AssetBulkUploadCheckResponse.Result(id: "c3", action: "accept"),
            ]
        )
        let env = MockBackupEnvironment()
        let engine = BackupEngine(client: mock, source: source, environment: env)

        await engine.run(settings: settings())

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.uploadedCount, 2)
        XCTAssertEqual(engine.rejectedCount, 1)
        XCTAssertEqual(engine.failedCount, 0)
        XCTAssertEqual(engine.total, 3, "denominator = all filtered candidates")
        XCTAssertEqual(engine.processedCount, 3, "2 uploaded + 1 already-on-server")
        XCTAssertEqual(mock.lastUploadFilename, "c3.jpg", "dernier upload = dernier accepté")
        XCTAssertNil(mock.lastUploadDuration, "image → duration nil")
    }

    @MainActor
    func test_backup_checksumSentMatchesSha1Base64() async {
        let payload = Data("hello-immich".utf8)
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        source.dataProvider = { _ in payload }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept")]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        let expected = Data(Insecure.SHA1.hash(data: payload)).base64EncodedString()
        XCTAssertEqual(mock.lastUploadChecksum, expected)
        XCTAssertEqual(mock.lastUploadData, payload)
        XCTAssertEqual(mock.lastUploadFileCreatedAt, "2024-07-01T00:00:00.000Z")
        XCTAssertFalse(mock.lastUploadIsFavorite ?? true)
    }

    @MainActor
    func test_backup_videoCarriesDurationAndFavorite() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("v1", kind: .video, favorite: true)]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [AssetBulkUploadCheckResponse.Result(id: "v1", action: "accept")]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(mock.lastUploadDuration, 12)
        XCTAssertEqual(mock.lastUploadIsFavorite, true)
        XCTAssertEqual(mock.lastUploadVisibility, .timeline)
    }

    // MARK: - Gating environment

    @MainActor
    func test_backup_offlineGateBlocksRun() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        let env = MockBackupEnvironment()
        env.isOnlineValue = false
        let engine = BackupEngine(client: mock, source: source, environment: env)

        await engine.run(settings: settings(wifi: true))

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(engine.uploadedCount, 0)
        XCTAssertEqual(engine.deferredCount, 0, "hors ligne n'entre même pas dans le pipeline")
        XCTAssertEqual(mock.requestCount, 0, "aucun appel réseau")
        XCTAssertEqual(engine.lastError, localizedString("Backup needs a network connection."))
    }

    @MainActor
    func test_backup_chargingGateBlocksRun() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        let env = MockBackupEnvironment()
        env.isChargingValue = false
        let engine = BackupEngine(client: mock, source: source, environment: env)

        await engine.run(settings: settings(charging: true))

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(mock.requestCount, 0)
        XCTAssertEqual(engine.lastError, localizedString("Backup requires charging."))
    }

    @MainActor
    func test_backup_disabledIsNoOp() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings(enabled: false))

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(mock.requestCount, 0)
    }

    // MARK: - Cancellation

    private func accepting(_ ids: String...) -> AssetBulkUploadCheckResponse {
        AssetBulkUploadCheckResponse(results: ids.map { .init(id: $0, action: "accept") })
    }

    /// Lance un run bloqué sur son premier upload, l'annule, attend son retour
    /// (< 5 s : la porte n'est libérée que par l'annulation).
    @MainActor
    private func cancelRunInFlight(_ engine: BackupEngine, _ mock: MockImmichClient) async {
        mock.uploadGate = suspendUntilCancelled
        let s = settings()
        let run = Task { @MainActor in await engine.run(settings: s, manual: true) }
        await pollUntil("upload en vol") { mock.uploads.count == 1 }
        engine.cancel()
        let elapsed = await ContinuousClock().measure { _ = await run.value }
        XCTAssertLessThan(elapsed, .seconds(5), "la porte n'a été libérée que par l'annulation")
        mock.uploadGate = nil
    }

    /// AC-5 : un cancel() sans run actif (idle, done, cancelled) est ignoré.
    @MainActor
    func test_backup_cancelBeforeRun() async {
        for state in [BackupEngine.Phase.idle, .done, .cancelled] {
            let mock = MockImmichClient()
            let source = MockBackupAssetSource()
            source.candidates = [candidate("c1"), candidate("c2")]
            mock.bulkUploadCheckResponse = accepting("c1", "c2")
            let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())
            if state == .done {
                await engine.run(settings: settings())
                engine.forgetAllBackedUp()
            } else if state == .cancelled {
                await cancelRunInFlight(engine, mock)
            }
            XCTAssertEqual(engine.phase, state)
            let before = mock.requestCount

            engine.cancel()
            let entered = await engine.run(settings: settings())

            XCTAssertTrue(entered, "\(state)")
            XCTAssertEqual(engine.phase, .done, "\(state)")
            XCTAssertGreaterThan(mock.requestCount, before, "\(state)")
            XCTAssertEqual(engine.uploadedCount, 2, "\(state)")
        }
    }

    /// AC-6 : cancel() au repos n'allume pas « Cancelling… ».
    @MainActor
    func test_AC6_cancelWhileIdleKeepsIsCancellingFalse() {
        let engine = BackupEngine(client: MockImmichClient(), source: MockBackupAssetSource(), environment: MockBackupEnvironment())

        engine.cancel()

        XCTAssertFalse(engine.isCancelling)
        XCTAssertEqual(engine.phase, .idle)
    }

    /// AC-1 : un Stop n'annule que le run en cours.
    @MainActor
    func test_AC1_cancelDuringRun_nextManualRunEntersPipeline() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2"), candidate("c3")]
        mock.bulkUploadCheckResponse = accepting("c1", "c2", "c3")
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())
        await cancelRunInFlight(engine, mock)
        XCTAssertEqual(engine.phase, .cancelled)
        let checks = mock.bulkUploadCheckChunks.count

        let entered = await engine.run(settings: settings(), manual: true)

        XCTAssertTrue(entered)
        XCTAssertEqual(engine.phase, .done)
        XCTAssertGreaterThan(mock.bulkUploadCheckChunks.count, checks)
        XCTAssertEqual(engine.uploadedCount, 3)
    }

    /// AC-3 : l'auto-détection est acceptée après un run annulé.
    @MainActor
    func test_AC3_autoRunAcceptedAfterCancelledRun() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        mock.bulkUploadCheckResponse = accepting("c1")
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())
        await cancelRunInFlight(engine, mock)

        let entered = await engine.run(settings: settings(), manual: false)

        XCTAssertTrue(entered)
        XCTAssertEqual(engine.phase, .done)
    }

    /// AC-7 : l'upload en vol est interrompu, pas attendu ni rejoué.
    @MainActor
    func test_AC7_cancelInterruptsInFlightUpload() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2"), candidate("c3")]
        mock.bulkUploadCheckResponse = accepting("c1", "c2", "c3")
        let ledger = BackupLedger.inMemory()
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment(), ledger: ledger)

        await cancelRunInFlight(engine, mock)

        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertEqual(mock.uploads.count, 1)
        XCTAssertEqual(engine.failedCount, 0)
        XCTAssertEqual(ledger.trackedCount(), 0)
    }

    /// AC-10 : « Cancelling… » est éteint quand le run annulé rend la main.
    @MainActor
    func test_AC10_cancelledRunReturnsWithCancellingCleared() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2")]
        mock.bulkUploadCheckResponse = accepting("c1", "c2")
        mock.uploadGate = suspendUntilCancelled
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())
        let s = settings()
        let run = Task { @MainActor in await engine.run(settings: s, manual: true) }
        await pollUntil("upload en vol") { mock.uploads.count == 1 }

        engine.cancel()
        XCTAssertTrue(engine.isCancelling)
        _ = await run.value

        XCTAssertFalse(engine.isCancelling)
        XCTAssertEqual(engine.phase, .cancelled)
    }

    /// AC-14 : l'export suspendu (téléchargement iCloud) est interrompu.
    @MainActor
    func test_AC14_cancelInterruptsSuspendedExport() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        mock.bulkUploadCheckResponse = accepting("c1")
        source.exportGate = { _ in try await suspendUntilCancelled() }
        let ledger = BackupLedger.inMemory()
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment(), ledger: ledger)
        let s = settings()
        let run = Task { @MainActor in await engine.run(settings: s, manual: true) }
        await pollUntil("export en vol") { source.exportedIDs == ["c1"] }

        engine.cancel()
        let elapsed = await ContinuousClock().measure { _ = await run.value }

        XCTAssertLessThan(elapsed, .seconds(5))
        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertEqual(engine.failedCount, 0)
        XCTAssertEqual(engine.deferredCount, 0)
        XCTAssertTrue(mock.uploads.isEmpty)
        XCTAssertEqual(ledger.trackedCount(), 0)
    }

    /// AC-16 : un run tenté entre la fin du pipeline et le retour de `run()`
    /// est refusé ; le premier appelant lit l'état de son propre run.
    @MainActor
    func test_AC16_runAttemptedBeforePreviousRunReturnedIsRefused() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        mock.bulkUploadCheckResponse = accepting("c1")
        let latch = TestLatch()
        mock.uploadGate = { try await latch.wait() }
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())
        let s = settings()
        let first = Task { @MainActor in
            let entered = await engine.run(settings: s, manual: true)
            return (entered, engine.phase, engine.uploadedCount)
        }
        await pollUntil("upload en vol") { mock.uploads.count == 1 }
        let second = TestBox<Task<Bool, Never>?>(nil)
        withObservationTracking {
            _ = engine.phase
        } onChange: {
            second.value = Task { @MainActor in await engine.run(settings: s, manual: true) }
        }

        latch.open()
        let (entered, phase, uploaded) = await first.value
        let checks = mock.bulkUploadCheckChunks.count
        let secondEntered = await second.value?.value

        XCTAssertTrue(entered)
        XCTAssertEqual(phase, .done)
        XCTAssertEqual(uploaded, 1)
        XCTAssertEqual(secondEntered, false)
        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.uploadedCount, 1)
        XCTAssertEqual(mock.bulkUploadCheckChunks.count, checks)
        let again = await engine.run(settings: s, manual: true)
        XCTAssertTrue(again)
    }

    /// AC-17 : un run lancé juste après `stopAndWait()` reste annulable.
    @MainActor
    func test_AC17_runStartedRightAfterStopAndWaitStaysCancellable() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        mock.bulkUploadCheckResponse = accepting("c1")
        mock.uploadGate = suspendUntilCancelled
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())
        let s = settings()
        let a = Task { @MainActor in await engine.run(settings: s, manual: true) }
        await pollUntil("upload de A en vol") { mock.uploads.count == 1 }

        await engine.stopAndWait()
        let canceller = Task { @MainActor in
            await pollUntil("upload de B en vol") { mock.uploads.count == 2 }
            _ = await a.value
            engine.cancel()
        }
        var entered = false
        let elapsed = await ContinuousClock().measure {
            entered = await engine.run(settings: s, manual: true)
        }

        XCTAssertTrue(entered)
        XCTAssertLessThan(elapsed, .seconds(5), "B doit être annulable")
        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertFalse(engine.isCancelling)
        await canceller.value
    }

    @MainActor
    func test_backup_cancelMidUploadStopsAtItemBoundary() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2"), candidate("c3")]
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())
        var cancelled = false
        let cancelOnce: () -> Void = {
            guard !cancelled else { return }
            cancelled = true
            engine.cancel()
        }
        source.onFirstLoad = cancelOnce
        // Same hook on every load: the streamed pipeline loops through all
        // candidates before honoring the cancellation flag.
        source.dataProvider = { _ in
            cancelOnce()
            return Data(repeating: 0, count: 4)
        }

        await engine.run(settings: settings())

        XCTAssertEqual(engine.phase, .cancelled, "stoppé au point de contrôle suivant le flag")
        XCTAssertLessThan(engine.uploadedCount, 3, "stoppé avant la fin")
        XCTAssertEqual(mock.requestCount, 0, "check/upload appelés après le flag = aucun")
    }

    /// AC-16 : un export interrompu par l'annulation n'est ni un échec ni un report.
    @MainActor
    func test_AC16_engine_cancelledExportIsNeitherFailureNorDeferral() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2")]
        source.loadError = CancellationError()
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())
        source.onFirstLoad = { engine.cancel() }

        await engine.run(settings: settings())

        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertEqual(engine.failedCount, 0)
        XCTAssertEqual(engine.deferredCount, 0)
        XCTAssertTrue(engine.failures.isEmpty)
        XCTAssertNil(engine.lastError)
        XCTAssertTrue(engine.backedUpIDs.isEmpty)
        XCTAssertTrue(mock.uploads.isEmpty)
    }

    /// AC-17 : une erreur d'écriture est un échec générique, et le run continue.
    @MainActor
    func test_AC17_engine_writeErrorFailsWithGenericMessageAndRunContinues() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2")]
        source.loadError = CocoaError(.fileWriteUnknown)
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(source.exportedIDs, ["c1", "c2"])
        XCTAssertEqual(engine.failedCount, 2)
        XCTAssertEqual(engine.deferredCount, 0)
        XCTAssertEqual(engine.failures.map(\.reason), [UserFacingError.genericMessage, UserFacingError.genericMessage])
    }

    // MARK: - Erreurs

    @MainActor
    func test_backup_uploadFailureContinuesToNextItem() async {
        let mock = MockImmichClient()
        mock.uploadError = APIError.serverError(500, "boom")
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2")]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [
                AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept"),
                AssetBulkUploadCheckResponse.Result(id: "c2", action: "accept"),
            ]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.failedCount, 2)
        XCTAssertEqual(engine.uploadedCount, 0)
        XCTAssertEqual(engine.processedCount, 2)
        XCTAssertEqual(engine.lastError, UserFacingError.serverErrorMessage)
    }

    /// AC-2 : une annulation réseau n'est pas un échec du run.
    @MainActor
    func test_AC2_cancelledUploadIsNotCountedAsFailure() async {
        let mock = MockImmichClient()
        mock.uploadError = URLError(.cancelled)
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept")]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.failedCount, 0, "une annulation n'est pas un échec")
        XCTAssertTrue(engine.failures.isEmpty)
        XCTAssertNil(engine.lastError)
    }

    /// AC-3 : le message d'échec est la copie localisée, jamais le texte brut.
    @MainActor
    func test_AC3_backupFailureMessageIsLocalizedCopyNotRawText() async {
        let mock = MockImmichClient()
        mock.uploadErrorsByFilename = [
            "c1.jpg": APIError.decoding("Decoding failed"),
            "c2.jpg": APIError.serverError(500, "HTTP 500 Network error"),
        ]
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2")]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [
                AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept"),
                AssetBulkUploadCheckResponse.Result(id: "c2", action: "accept"),
            ]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.failedCount, 2)
        XCTAssertEqual(engine.failures.map(\.reason), [
            UserFacingError.genericMessage,
            UserFacingError.serverErrorMessage,
        ])
        XCTAssertEqual(engine.lastError, UserFacingError.serverErrorMessage)
        for raw in ["Decoding failed", "Network error", "HTTP"] {
            XCTAssertFalse(engine.lastError?.contains(raw) ?? false, "texte brut « \(raw) » interdit")
            XCTAssertFalse(engine.failures.contains { $0.reason.contains(raw) })
        }
    }

    @MainActor
    func test_backup_loadFailureCountsFailedAndContinues() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("bad"), candidate("good")]
        source.loadError = APIError.decoding("PHAsset not found")
        // loadError s'applique au premier loadData seulement? Non — tous.
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.failedCount, 2, "tous les loads échouent")
        XCTAssertEqual(engine.uploadedCount, 0)
        XCTAssertEqual(engine.phase, .done)
    }

    @MainActor
    func test_backup_iCloudNotReadyIsDeferredNotFailed() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("pending"), candidate("c3")]
        source.deferIDs = ["pending"]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [
                AssetBulkUploadCheckResponse.Result(id: "c1", action: "accept"),
                AssetBulkUploadCheckResponse.Result(id: "c3", action: "accept"),
            ]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(engine.uploadedCount, 2)
        XCTAssertEqual(engine.deferredCount, 1, "iCloud-not-ready asset is deferred")
        XCTAssertEqual(engine.failedCount, 0, "deferral is not a failure")
        XCTAssertTrue(engine.failures.isEmpty, "deferred assets never enter the failures list")
        XCTAssertNil(engine.lastError, "deferral must not surface a red error")
        XCTAssertEqual(engine.processedCount, 3, "deferred counts as handled so the bar completes")
    }

    // MARK: - Filtres + scoping albums

    @MainActor
    func test_backup_excludedAlbumIDsForwardedAndApplied() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("shot"), candidate("real")]
        source.excludedAssetIDs = ["shot"]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [AssetBulkUploadCheckResponse.Result(id: "real", action: "accept")]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings(excludedAlbums: ["album-screenshots"]))

        XCTAssertEqual(source.lastExcludedAlbumIDs, ["album-screenshots"],
                       "l'exclusion est transmise à la source, qui la résout")
        XCTAssertEqual(engine.total, 1)
        XCTAssertEqual(mock.lastUploadFilename, "real.jpg")
    }

    /// The heuristic this replaced dropped anything named `IMG_*`, i.e. almost a
    /// whole iPhone camera roll. An asset with that name must now be uploaded.
    @MainActor
    func test_backup_noFilenameHeuristicFilters() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        let imgs = [
            BackupCandidate(
                id: "img1", kind: .image, fileName: "IMG_0001.HEIC",
                fileCreatedAt: "2024-07-01T00:00:00.000Z",
                fileModifiedAt: "2024-07-01T00:00:00.000Z",
                duration: nil, isFavorite: false
            ),
            BackupCandidate(
                id: "wa1", kind: .image, fileName: "WhatsApp Image.jpg",
                fileCreatedAt: "2024-07-01T00:00:00.000Z",
                fileModifiedAt: "2024-07-01T00:00:00.000Z",
                duration: nil, isFavorite: false
            ),
        ]
        source.candidates = imgs
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: imgs.map { AssetBulkUploadCheckResponse.Result(id: $0.id, action: "accept") }
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.uploadedCount, 2, "plus aucun filtre sur le nom de fichier")
        XCTAssertEqual(engine.total, 2)
    }

    @MainActor
    func test_backup_selectedAlbumsForwardedToSource() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings(albums: ["a1", "a2"]))

        XCTAssertEqual(source.lastAlbumIDs, ["a1", "a2"])
    }

    // MARK: - Chunking

    @MainActor
    func test_backup_chunksBulkCheckByHundred() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = (0..<250).map { candidate("c\($0)") }
        mock.bulkUploadCheckChunks = []
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: (0..<250).map { AssetBulkUploadCheckResponse.Result(id: "c\($0)", action: "accept") }
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(mock.bulkUploadCheckChunks.count, 3, "100 + 100 + 50")
        XCTAssertEqual(mock.bulkUploadCheckChunks[0].count, 100)
        XCTAssertEqual(mock.bulkUploadCheckChunks[2].count, 50)
        XCTAssertEqual(engine.uploadedCount, 250)
    }

    // MARK: - Live Activity progress hook (P2 backup-live-activity)

    @MainActor
    func test_backupEngine_progressAdvancesDuringStagingThenUploads() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2"), candidate("c3")]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: (1...3).map { AssetBulkUploadCheckResponse.Result(id: "c\($0)", action: "accept") }
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())
        var fractions: [Double] = []
        var totals: [Int] = []
        engine.onProgressUpdate = { _, total in
            fractions.append(engine.progressFraction)
            totals.append(total)
        }

        await engine.run(settings: settings())

        // 3 stagings (export+hash) then 3 uploads: the bar must move on the
        // staging half too, or it sits at 0 through the slow pass and then
        // jumps a whole chunk — the "0 then 100, looks broken" report.
        XCTAssertEqual(fractions.count, 6)
        XCTAssertEqual(totals, [3, 3, 3, 3, 3, 3], "total = full candidate count, fixed for the run")
        XCTAssertEqual(fractions[0], 1.0 / 6, accuracy: 0.0001, "un asset staged = un demi-pas sur 3")
        XCTAssertEqual(fractions[2], 0.5, accuracy: 0.0001, "tout staged, rien finalisé")
        XCTAssertEqual(fractions[5], 1, accuracy: 0.0001)
        XCTAssertEqual(zip(fractions, fractions.dropFirst()).filter { $0 >= $1 }.count, 0,
                       "strictement croissant : la barre ne recule jamais")
    }

    @MainActor
    func test_backup_progressReachesFullOnMixedOutcomes() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("up1"), candidate("dup"), candidate("bad"), candidate("up2")]
        source.failIDs = ["bad"]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [
                AssetBulkUploadCheckResponse.Result(id: "up1", action: "accept"),
                AssetBulkUploadCheckResponse.Result(id: "dup", action: "reject", reason: "duplicate"),
                AssetBulkUploadCheckResponse.Result(id: "up2", action: "accept"),
            ]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.total, 4, "denominator = all filtered candidates")
        XCTAssertEqual(engine.uploadedCount, 2)
        XCTAssertEqual(engine.rejectedCount, 1)
        XCTAssertEqual(engine.failedCount, 1)
        XCTAssertEqual(engine.processedCount, 4, "every candidate reaches a final outcome")
        XCTAssertEqual(engine.progressFraction, 1, accuracy: 0.0001, "bar completes despite skips/failures")
        XCTAssertEqual(engine.progressPercent, 100)
    }

}

// MARK: - Network policy (per-asset cellular decision + offline gate)

/// The Wi-Fi gate used to be all-or-nothing and `hasWiFiConnection == false`
/// covered both "on cellular" and "airplane mode" — an offline run exported and
/// hashed the whole library and then failed every upload. These cover the
/// replacement: one offline gate, then a per-asset decision whose result is a
/// deferral, never a failure.
final class NetworkPolicyTests: XCTestCase {

    private func candidate(
        _ id: String, kind: BackupAssetKind = .image
    ) -> BackupCandidate {
        BackupCandidate(
            id: id, kind: kind, fileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            duration: kind == .video ? 30 : nil, isFavorite: false
        )
    }

    private func settings(
        wifi: Bool = false,
        cellularPhotos: Bool = false,
        cellularVideos: Bool = false
    ) -> BackupSettings {
        BackupSettings(
            isEnabled: true,
            onlyOnWiFi: wifi,
            allowCellularForPhotos: cellularPhotos,
            allowCellularForVideos: cellularVideos
        )
    }

    @MainActor
    func test_offline_runDoesNotEnterPipeline() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        let env = MockBackupEnvironment()
        env.isOnlineValue = false
        let engine = BackupEngine(client: mock, source: source, environment: env)

        let started = await engine.run(settings: settings(wifi: true))

        XCTAssertFalse(started)
        XCTAssertEqual(engine.phase, .idle, "hors ligne : le pipeline n'est pas entré")
        XCTAssertEqual(source.purgeCount, 0, "aucun octet lu, aucun temp purgé")
        XCTAssertEqual(mock.requestCount, 0)
        XCTAssertEqual(engine.lastError, localizedString("Backup needs a network connection."))
    }

    /// On cellular with "Wi-Fi only", photos may go up when allowed while videos
    /// wait — the whole point of splitting the decision per media kind.
    @MainActor
    func test_cellular_photosAllowedVideosDeferred() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("photo"), candidate("movie", kind: .video)]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "photo", action: "accept")]
        )
        let env = MockBackupEnvironment()
        env.hasWiFiValue = false
        let engine = BackupEngine(client: mock, source: source, environment: env)

        await engine.run(settings: settings(wifi: true, cellularPhotos: true, cellularVideos: false))

        XCTAssertEqual(engine.uploadedCount, 1)
        XCTAssertEqual(engine.deferredCount, 1)
        XCTAssertEqual(engine.failedCount, 0, "un report n'est pas un échec")
        XCTAssertEqual(engine.processedCount, 2, "la barre atteint 100 % malgré le report")
        XCTAssertEqual(mock.lastUploadFilename, "photo.jpg")
    }

    /// The deferred asset costs no iCloud download and no hash: the decision is
    /// made before the export.
    @MainActor
    func test_cellular_deferredAssetIsNeverExported() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("photo"), candidate("movie", kind: .video)]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "photo", action: "accept")]
        )
        let env = MockBackupEnvironment()
        env.hasWiFiValue = false
        let engine = BackupEngine(client: mock, source: source, environment: env)

        await engine.run(settings: settings(wifi: true, cellularPhotos: true, cellularVideos: false))

        XCTAssertEqual(source.exportedIDs, ["photo"], "l'asset reporté n'est jamais exporté")
    }

    @MainActor
    func test_cellular_deferralDoesNotSetLastErrorNorFailures() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("movie", kind: .video)]
        let env = MockBackupEnvironment()
        env.hasWiFiValue = false
        let engine = BackupEngine(client: mock, source: source, environment: env)

        await engine.run(settings: settings(wifi: true))

        XCTAssertEqual(engine.deferredCount, 1)
        XCTAssertNil(engine.lastError, "un report ne doit pas allumer une erreur rouge")
        XCTAssertTrue(engine.failures.isEmpty)
        XCTAssertEqual(engine.failedCount, 0)
    }

    @MainActor
    func test_wifi_uploadsAllRegardlessOfCellularToggles() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("photo"), candidate("movie", kind: .video)]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "photo", action: "accept"), .init(id: "movie", action: "accept")]
        )
        let env = MockBackupEnvironment()
        env.hasWiFiValue = true
        let engine = BackupEngine(client: mock, source: source, environment: env)

        await engine.run(settings: settings(wifi: true, cellularPhotos: false, cellularVideos: false))

        XCTAssertEqual(engine.uploadedCount, 2)
        XCTAssertEqual(engine.deferredCount, 0)
    }

    /// A manual run is an explicit user action: it overrides the network policy
    /// as it already overrides the Wi-Fi and charging gates.
    @MainActor
    func test_manualRun_ignoresCellularPolicy() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("movie", kind: .video)]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "movie", action: "accept")]
        )
        let env = MockBackupEnvironment()
        env.hasWiFiValue = false
        let engine = BackupEngine(client: mock, source: source, environment: env)

        await engine.run(settings: settings(wifi: true, cellularVideos: false), manual: true)

        XCTAssertEqual(engine.uploadedCount, 1)
        XCTAssertEqual(engine.deferredCount, 0)
    }

    /// The bucket must say *why* it's waiting: "Waiting for Wi-Fi" and "Waiting
    /// for iCloud" are different stories, and an unlabeled counter reads as a
    /// stall.
    @MainActor
    func test_deferralReason_reportsWiFiVsICloud() async {
        // Cellular, video not allowed → Wi-Fi.
        let wifiMock = MockImmichClient()
        let wifiSource = MockBackupAssetSource()
        wifiSource.candidates = [candidate("movie", kind: .video)]
        let wifiEnv = MockBackupEnvironment()
        wifiEnv.hasWiFiValue = false
        let wifiEngine = BackupEngine(client: wifiMock, source: wifiSource, environment: wifiEnv)
        await wifiEngine.run(settings: settings(wifi: true))
        XCTAssertEqual(wifiEngine.deferralReason, [.waitingForWiFi])

        // Wi-Fi, but the iCloud original isn't local → iCloud.
        let iCloudMock = MockImmichClient()
        let iCloudSource = MockBackupAssetSource()
        iCloudSource.candidates = [candidate("pending")]
        iCloudSource.deferIDs = ["pending"]
        let iCloudEngine = BackupEngine(
            client: iCloudMock, source: iCloudSource, environment: MockBackupEnvironment()
        )
        await iCloudEngine.run(settings: settings())
        XCTAssertEqual(iCloudEngine.deferralReason, [.waitingForICloud])

        // Both causes in one run: photos may go up over cellular, so the
        // iCloud-only one reaches its export and defers there; the video is
        // held back before any export.
        let mixedMock = MockImmichClient()
        let mixedSource = MockBackupAssetSource()
        mixedSource.candidates = [candidate("pending"), candidate("movie", kind: .video)]
        mixedSource.deferIDs = ["pending"]
        let mixedEnv = MockBackupEnvironment()
        mixedEnv.hasWiFiValue = false
        let mixedEngine = BackupEngine(client: mixedMock, source: mixedSource, environment: mixedEnv)
        await mixedEngine.run(settings: settings(wifi: true, cellularPhotos: true))
        XCTAssertEqual(mixedEngine.deferralReason, [.waitingForWiFi, .waitingForICloud])
    }
}

// MARK: - Live Photos (paired video upload + retroactive repair)

/// A Live Photo must reach the server as a Live Photo: the paired video goes up
/// first (hidden), then the still carrying the video's id. An earlier run may
/// already have stored the still as a dead image — the reject path repairs it
/// through the remote `assetId`, which is the only way back.
final class LivePhotoBackupTests: XCTestCase {

    private func livePhoto(_ id: String) -> BackupCandidate {
        BackupCandidate(
            id: id, kind: .image, fileName: "\(id).HEIC",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            duration: nil, isFavorite: false, isLivePhoto: true
        )
    }

    private func still(_ id: String) -> BackupCandidate {
        BackupCandidate(
            id: id, kind: .image, fileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            duration: nil, isFavorite: false
        )
    }

    private func settings() -> BackupSettings { BackupSettings(isEnabled: true) }

    @MainActor
    func test_livePhoto_uploadsVideoHiddenBeforePhotoWithPairID() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "lp1", action: "accept")]
        )
        mock.uploadResponsesByFilename = ["lp1.MOV": AssetMediaResponseDto(id: "video-9", status: "created")]
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(mock.uploads.count, 2, "vidéo puis photo")
        XCTAssertEqual(mock.uploads[0].filename, "lp1.MOV")
        XCTAssertEqual(mock.uploads[0].visibility, .hidden, "la vidéo appairée est masquée")
        XCTAssertNil(mock.uploads[0].livePhotoVideoId)
        XCTAssertEqual(mock.uploads[1].filename, "lp1.HEIC")
        XCTAssertEqual(mock.uploads[1].visibility, .timeline)
        XCTAssertEqual(mock.uploads[1].livePhotoVideoId, "video-9", "la photo porte l'id de sa vidéo")
    }

    /// One asset is one progress unit, however many files it takes to store it.
    @MainActor
    func test_livePhoto_countsAsSingleProgressUnit() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "lp1", action: "accept")]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.total, 1)
        XCTAssertEqual(engine.processedCount, 1)
        XCTAssertEqual(engine.progressPercent, 100)
    }

    /// A Live Photo already stored as a dead image comes back as a reject with
    /// the remote `assetId` — the video is uploaded and linked onto it.
    @MainActor
    func test_livePhoto_rejectedPhotoStillLinksPairedVideoViaUpdateAsset() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "lp1", action: "reject", reason: "duplicate", assetId: "remote-photo-7"),
        ])
        mock.uploadResponsesByFilename = ["lp1.MOV": AssetMediaResponseDto(id: "video-9", status: "created")]
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.rejectedCount, 1)
        XCTAssertEqual(engine.failedCount, 0, "le rattachement ne fait pas échouer l'asset")
        XCTAssertEqual(mock.updateAssetCalls.count, 1)
        XCTAssertEqual(mock.updateAssetCalls[0].id, "remote-photo-7")
        XCTAssertEqual(mock.updateAssetCalls[0].dto.livePhotoVideoId, "video-9")
    }

    /// A reject without an `assetId` (nothing to attach to) must not attempt a
    /// blind PATCH — and the asset is not recorded as backed up: it has no video
    /// on the server, so the next run must look at it again.
    @MainActor
    func test_livePhoto_rejectWithoutAssetIdSkipsRepair() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        let ledger = BackupLedger.inMemory()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "lp1", action: "reject", reason: "duplicate"),
        ])
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment(), ledger: ledger)

        await engine.run(settings: settings())

        XCTAssertTrue(mock.updateAssetCalls.isEmpty)
        XCTAssertEqual(mock.uploads.count, 0)
        XCTAssertEqual(engine.rejectedCount, 1)
        XCTAssertEqual(engine.failedCount, 0)
        XCTAssertEqual(engine.failures.map(\.assetID), ["lp1"])
        XCTAssertEqual(engine.failures.first?.reason, String(localized: "The Live Photo video could not be linked."))
        XCTAssertEqual(ledger.trackedCount(), 0)
        XCTAssertTrue(engine.backedUpIDs.isEmpty)
    }

    /// The still is on the server but its video could not be linked: no ledger
    /// entry, so the next backup re-exports it and tries the link again.
    @MainActor
    func test_AC20_livePhotoReject_repairFails_noLedgerAndRetriedNextRun() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        let ledger = BackupLedger.inMemory()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "lp1", action: "reject", reason: "duplicate", assetId: "remote-photo-7"),
        ])
        mock.uploadErrorsByFilename = ["lp1.MOV": APIError.decoding("no link today")]
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment(), ledger: ledger)
        // Keep the weekly reconciliation (which would answer for the mock) out of it.
        ledger.recordReconciliation(at: Date())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.failures.map(\.assetID), ["lp1"])
        XCTAssertEqual(engine.failedCount, 0, "a warning, not a failed asset")
        XCTAssertFalse(ledger.isBackedUp(id: "lp1", signature: livePhoto("lp1").fileModifiedAt))
        XCTAssertTrue(engine.backedUpIDs.isEmpty)

        mock.uploadErrorsByFilename = [:]
        mock.uploadResponsesByFilename = ["lp1.MOV": AssetMediaResponseDto(id: "video-9", status: "created")]

        await engine.run(settings: settings())

        XCTAssertEqual(source.exportedIDs, ["lp1", "lp1"], "the second run re-exports it")
        XCTAssertEqual(mock.updateAssetCalls.count, 1)
        XCTAssertTrue(engine.failures.isEmpty)
        XCTAssertTrue(ledger.isBackedUp(id: "lp1", signature: livePhoto("lp1").fileModifiedAt))
        XCTAssertEqual(engine.backedUpIDs, ["lp1"])
    }

    /// A trashed asset is on the server (in the trash) — linking a video onto
    /// it would be wrong.
    @MainActor
    func test_livePhoto_trashedRejectSkipsRepair() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "lp1", action: "reject", reason: "duplicate", assetId: "remote-photo-7", isTrashed: true),
        ])
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertTrue(mock.updateAssetCalls.isEmpty)
    }

    /// The still and its video share one fate: if the video can't be exported,
    /// deferring the still is the only outcome that doesn't store a dead image.
    @MainActor
    func test_livePhoto_pairedExportDeferredDefersWholeAsset() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.pairedDeferIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.deferredCount, 1)
        XCTAssertEqual(engine.failedCount, 0)
        XCTAssertEqual(engine.uploadedCount, 0, "rien n'est uploadé")
        XCTAssertEqual(mock.uploads.count, 0)
        XCTAssertEqual(engine.total, 1)
    }

    /// A hard failure on the video is a failure of the asset, and nothing of it
    /// is uploaded — the still alone would be a dead Live Photo.
    @MainActor
    func test_livePhoto_pairedHardFailureFailsAssetWithoutUpload() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.pairedFailIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.failedCount, 1)
        XCTAssertEqual(engine.uploadedCount, 0)
        XCTAssertEqual(mock.uploads.count, 0)
    }

    /// AC-8 : la vidéo appairée échoue, le still déjà exporté ne reste pas sur le disque.
    @MainActor
    func test_AC8_engine_pairedVideoExportErrorRemovesStill() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.pairedFailIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(engine.failedCount, 1)
        XCTAssertTrue(Self.tempExportFiles(matching: "lp1").isEmpty)
    }

    /// No temp file may survive the run — the pair doubles the disk footprint
    /// of a chunk, so a missed cleanup is a real leak.
    @MainActor
    func test_livePhoto_tempFilesDeletedAfterRun() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "lp1", action: "accept")]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertTrue(Self.tempExportFiles(matching: "lp1").isEmpty,
                      "les temps de la photo ET du pair sont supprimés")
    }

    /// Cancellation mid-run must clean the pairs too, not just the stills.
    @MainActor
    func test_livePhoto_tempFilesDeletedOnCancel() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1"), livePhoto("lp2")]
        source.livePhotoIDs = ["lp1", "lp2"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())
        // Cancel once the first asset (still + pair) is on disk and staged: the
        // flag is honoured at the next item boundary, and both temp files of
        // the staged chunk must go with it.
        source.onFirstLoad = { engine.cancel() }

        await engine.run(settings: settings())

        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertTrue(Self.tempExportFiles(matching: "lp").isEmpty, "l'annulation ne fuit aucun temp")
    }

    /// AC-8 : un upload interrompu ne laisse ni échec, ni ledger, ni temporaire.
    @MainActor
    func test_AC8_cancelledLivePhotoUploadLeavesNoFailureLedgerOrTempFiles() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [.init(id: "lp1", action: "accept")])
        mock.uploadGate = suspendUntilCancelled
        let ledger = BackupLedger.inMemory()
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment(), ledger: ledger)
        let s = settings()

        let run = Task { @MainActor in await engine.run(settings: s, manual: true) }
        await pollUntil("upload de la vidéo appariée en vol") { mock.uploads.count == 1 }
        engine.cancel()
        _ = await run.value

        XCTAssertEqual(engine.failedCount, 0)
        XCTAssertTrue(engine.failures.isEmpty)
        XCTAssertEqual(ledger.trackedCount(), 0)
        XCTAssertTrue(Self.tempExportFiles(matching: "lp1").isEmpty)
    }

    /// AC-15 : une réparation interrompue ne marque pas la Live Photo
    /// sauvegardée ; le run complet suivant la retente.
    @MainActor
    func test_AC15_cancelledLivePhotoRepairStaysOutOfLedger() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "lp1", action: "reject", reason: "duplicate", assetId: "remote-photo-7"),
        ])
        mock.uploadResponsesByFilename = ["lp1.MOV": AssetMediaResponseDto(id: "video-9", status: "created")]
        mock.uploadGate = suspendUntilCancelled
        let ledger = BackupLedger.inMemory()
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment(), ledger: ledger)
        let s = settings()

        let run = Task { @MainActor in await engine.run(settings: s, manual: true) }
        await pollUntil("upload de la vidéo de réparation en vol") { mock.uploads.count == 1 }
        engine.cancel()
        let elapsed = await ContinuousClock().measure { _ = await run.value }

        XCTAssertLessThan(elapsed, .seconds(5))
        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertEqual(ledger.trackedCount(), 0, "réparation interrompue ⇒ pas dans le ledger")
        XCTAssertTrue(engine.failures.isEmpty)
        XCTAssertEqual(engine.failedCount, 0)
        XCTAssertTrue(mock.updateAssetCalls.isEmpty)
        XCTAssertTrue(Self.tempExportFiles(matching: "lp1").isEmpty)

        mock.uploadGate = nil
        let entered = await engine.run(settings: s)

        XCTAssertTrue(entered)
        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(mock.updateAssetCalls.count, 1)
        XCTAssertEqual(mock.updateAssetCalls.first?.id, "remote-photo-7")
        XCTAssertEqual(mock.updateAssetCalls.first?.dto.livePhotoVideoId, "video-9")
        XCTAssertEqual(ledger.trackedCount(), 1)
    }

    /// A plain still must not grow a video upload or a PATCH.
    @MainActor
    func test_stillImage_unchangedNoPairedUploadNoUpdateAsset() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [still("c1")]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "c1", action: "accept")]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(mock.uploads.count, 1)
        XCTAssertEqual(mock.uploads[0].filename, "c1.jpg")
        XCTAssertNil(mock.uploads[0].livePhotoVideoId)
        XCTAssertTrue(mock.updateAssetCalls.isEmpty)
        XCTAssertEqual(engine.uploadedCount, 1)
    }

    /// Every upload carries the device attribution, which the server needs to
    /// list an asset under this device.
    @MainActor
    func test_uploadSendsDeviceAssetIdAndStableDeviceId() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [still("c1")]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "c1", action: "accept")]
        )
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertEqual(mock.lastUploadDeviceAssetId, "c1")
        XCTAssertEqual(mock.lastUploadDeviceId, DeviceIdentity.current)
        XCTAssertFalse(DeviceIdentity.current.isEmpty)
    }

    /// Leftover temp exports whose name contains `matching` — scoped so a
    /// sibling test's in-flight file can't make this flaky.
    private static func tempExportFiles(matching: String) -> [String] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immich-test-backup", isDirectory: true)
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return all.filter { $0.contains(matching) }
    }
}

// MARK: - Settings store (persistence)

final class BackupSettingsStoreTests: XCTestCase {

    @MainActor
    func test_settings_persistAcrossInstances() {
        let suite = "backup-settings-test-\(UUID().uuidString)"
        let first = BackupSettingsStore(suiteName: suite)
        first.isEnabled = true
        first.onlyOnWiFi = true
        first.onlyWhenCharging = true
        first.allowCellularForPhotos = true
        first.excludedAlbumIDs = [BackupAlbum.SmartID.screenshots]
        first.selectedAlbumIDs = ["a1", "a2"]
        first.albumScope = .selected

        let second = BackupSettingsStore(suiteName: suite)
        XCTAssertTrue(second.isEnabled)
        XCTAssertTrue(second.onlyOnWiFi)
        XCTAssertTrue(second.onlyWhenCharging)
        XCTAssertTrue(second.allowCellularForPhotos)
        XCTAssertEqual(second.albumScope, .selected)
        XCTAssertEqual(second.excludedAlbumIDs, [BackupAlbum.SmartID.screenshots])
        XCTAssertEqual(second.selectedAlbumIDs, ["a1", "a2"])
        // Both sets survive, but only the active scope's one reaches the engine.
        XCTAssertEqual(second.snapshot().selectedAlbumIDs, ["a1", "a2"])
        XCTAssertTrue(second.snapshot().excludedAlbumIDs.isEmpty)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    /// The old "Exclude screenshots" toggle becomes the Screenshots smart album,
    /// and the two dead heuristic keys are removed rather than left behind.
    @MainActor
    func test_settings_migratesScreenshotsToggleAndDropsLegacyKeys() {
        let suite = "backup-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: BackupSettingsStore.legacyScreenshotsKey)
        defaults.set(true, forKey: BackupSettingsStore.legacyCameraRollKey)
        defaults.set(true, forKey: BackupSettingsStore.legacyWhatsAppKey)

        let store = BackupSettingsStore(suiteName: suite)

        XCTAssertEqual(store.excludedAlbumIDs, [BackupAlbum.SmartID.screenshots])
        XCTAssertNil(defaults.object(forKey: BackupSettingsStore.legacyScreenshotsKey))
        XCTAssertNil(defaults.object(forKey: BackupSettingsStore.legacyCameraRollKey))
        XCTAssertNil(defaults.object(forKey: BackupSettingsStore.legacyWhatsAppKey))
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    /// A second launch must not re-run the migration over the user's own
    /// exclusion list.
    @MainActor
    func test_settings_migrationDoesNotOverrideStoredExclusions() {
        let suite = "backup-migration-keep-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["user-album"], forKey: BackupSettingsStore.excludedAlbumsKey)
        defaults.set(true, forKey: BackupSettingsStore.legacyScreenshotsKey)

        let store = BackupSettingsStore(suiteName: suite)

        XCTAssertEqual(store.excludedAlbumIDs, ["user-album"])
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    /// The scope picks which set reaches the engine — the two can never both
    /// apply, which is what made the old pair of links contradictory.
    @MainActor
    func test_settingsStore_scopeSelectsWhichSetReachesTheEngine() {
        let suite = "backup-scope-\(UUID().uuidString)"
        let store = BackupSettingsStore(suiteName: suite)
        store.selectedAlbumIDs = ["only-a"]
        store.excludedAlbumIDs = ["skip-b"]

        store.albumScope = .all
        XCTAssertTrue(store.snapshot().selectedAlbumIDs.isEmpty)
        XCTAssertTrue(store.snapshot().excludedAlbumIDs.isEmpty, "aucun ensemble ne s'applique")

        store.albumScope = .selected
        XCTAssertEqual(store.snapshot().selectedAlbumIDs, ["only-a"])
        XCTAssertTrue(store.snapshot().excludedAlbumIDs.isEmpty)

        store.albumScope = .excluded
        XCTAssertEqual(store.snapshot().excludedAlbumIDs, ["skip-b"])
        XCTAssertTrue(store.snapshot().selectedAlbumIDs.isEmpty)

        // Switching back and forth must not lose either set.
        store.albumScope = .selected
        XCTAssertEqual(store.snapshot().selectedAlbumIDs, ["only-a"])
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @MainActor
    func test_settingsStore_scopePersists() {
        let suite = "backup-scope-persist-\(UUID().uuidString)"
        let first = BackupSettingsStore(suiteName: suite)
        first.albumScope = .excluded
        let second = BackupSettingsStore(suiteName: suite)
        XCTAssertEqual(second.albumScope, .excluded)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    /// An install predating the scope had a set configured but no mode. The
    /// exclusion wins, because it is the one that made runs differ from "the
    /// whole library".
    @MainActor
    func test_settingsStore_infersScopeFromExistingSets() {
        let excludedSuite = "backup-scope-inf-ex-\(UUID().uuidString)"
        UserDefaults(suiteName: excludedSuite)?
            .set(["a"], forKey: BackupSettingsStore.excludedAlbumsKey)
        XCTAssertEqual(BackupSettingsStore(suiteName: excludedSuite).albumScope, .excluded)
        UserDefaults(suiteName: excludedSuite)?.removePersistentDomain(forName: excludedSuite)

        let selectedSuite = "backup-scope-inf-sel-\(UUID().uuidString)"
        UserDefaults(suiteName: selectedSuite)?
            .set(["a"], forKey: BackupSettingsStore.albumsKey)
        XCTAssertEqual(BackupSettingsStore(suiteName: selectedSuite).albumScope, .selected)
        UserDefaults(suiteName: selectedSuite)?.removePersistentDomain(forName: selectedSuite)

        let emptySuite = "backup-scope-inf-none-\(UUID().uuidString)"
        XCTAssertEqual(BackupSettingsStore(suiteName: emptySuite).albumScope, .all)
        UserDefaults(suiteName: emptySuite)?.removePersistentDomain(forName: emptySuite)
    }

    /// "Only selected" with nothing picked cannot be expressed to the engine
    /// (an empty inclusion set means "the whole library"), so it degrades to
    /// `.all` — and the UI states it rather than silently widening the run.
    @MainActor
    func test_settingsStore_emptySelectionDegradesToAll() {
        let suite = "backup-scope-empty-\(UUID().uuidString)"
        let store = BackupSettingsStore(suiteName: suite)
        store.albumScope = .selected

        XCTAssertEqual(store.effectiveAlbumScope, .all)
        let snap = store.snapshot()
        XCTAssertTrue(snap.selectedAlbumIDs.isEmpty)
        XCTAssertTrue(snap.excludedAlbumIDs.isEmpty)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @MainActor
    func test_settingsStore_defaultsAreOff() {
        let suite = "backup-settings-test-\(UUID().uuidString)"
        let store = BackupSettingsStore(suiteName: suite)
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.onlyOnWiFi)
        XCTAssertFalse(store.onlyWhenCharging)
        XCTAssertFalse(store.allowCellularForPhotos)
        XCTAssertFalse(store.allowCellularForVideos)
        XCTAssertTrue(store.excludedAlbumIDs.isEmpty)
        XCTAssertTrue(store.selectedAlbumIDs.isEmpty)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @MainActor
    func test_viewModel_runBackupSubmitsSchedulerOnDone() async {
        let mockClient = MockImmichClient()
        let photos = MockPhotoLibraryService()
        let scheduler = MockBackupScheduler()
        let engine = BackupEngine(client: mockClient, source: MockBackupAssetSource(), environment: MockBackupEnvironment())
        let settings = BackupSettingsStore(suiteName: "backup-vm-test-\(UUID().uuidString)")
        settings.isEnabled = true
        let activity = MockBackupLiveActivityService()
        let vm = UploadViewModel(client: mockClient, photos: photos, engine: engine, settings: settings, scheduler: scheduler, activityService: activity, readOnly: .ephemeral())

        await vm.runBackup()

        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(scheduler.submitCount, 1)
        UserDefaults(suiteName: "backup-vm-test-\(UUID().uuidString)")?.removePersistentDomain(forName: "backup-vm-test-\(UUID().uuidString)")
    }
}

// MARK: - ContinuationGate (completion-handler → async bridge)

final class ContinuationGateTests: XCTestCase {

    /// Regression: the PhotosKit completion can fire *before* the caller
    /// installs its continuation (fast, fully-local resources). This used to
    /// drop the resume, leaving the awaiter hung until the 90 s deadline —
    /// every local asset surfaced as a bogus "export timed out".
    func test_gate_finishBeforeAwait_deliversResult() async throws {
        let gate = ContinuationGate<Int>()
        gate.finish(with: .success(42))
        let value = try await gate.value
        XCTAssertEqual(value, 42)
    }

    /// A late timeout that lost the race must not clobber the delivered result.
    func test_gate_firstFinishWins() async throws {
        let gate = ContinuationGate<Int>()
        gate.finish(with: .success(7))
        gate.finish(with: .failure(APIError.decoding("late timeout")))
        let value = try await gate.value
        XCTAssertEqual(value, 7)
    }

    /// Normal path: finish arrives after the awaiter is parked.
    func test_gate_awaitThenFinish_delivers() async throws {
        let gate = ContinuationGate<Int>()
        let task = Task { try await gate.value }
        try await Task.sleep(nanoseconds: 5_000_000)
        gate.finish(with: .success(99))
        let value = try await task.value
        XCTAssertEqual(value, 99)
    }
}

// MARK: - Export en flux (PhotoKit)

/// L'export en flux de `PhotoLibraryServiceImpl` (`requestData` + `FileHandle`),
/// piloté par une fausse source de données : PhotoKit lui-même n'est pas testable
/// sans iCloud.
final class ResourceExportHelpersTests: XCTestCase {

    // MARK: Helpers

    private final class Log<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Element] = []
        func append(_ element: Element) { lock.lock(); items.append(element); lock.unlock() }
        var values: [Element] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private final class FakeResourceData: @unchecked Sendable {
        struct Request: @unchecked Sendable {
            let id: PHAssetResourceDataRequestID
            let progress: @Sendable (Double) -> Void
            let dataReceived: @Sendable (Data) -> Void
            let completion: @Sendable (Error?) -> Void
        }

        private let lock = NSLock()
        private var recorded: [Request] = []
        private var cancelled: [PHAssetResourceDataRequestID] = []
        /// Script of the n-th request (0-based), run on a global queue once the
        /// request is registered. A request without script stays pending.
        var script: [Int: @Sendable (Request) -> Void] = [:]
        /// Called synchronously from `cancelDataRequest`.
        var onCancel: (@Sendable (Request) -> Void)?

        var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
        var cancelledIDs: [PHAssetResourceDataRequestID] { lock.lock(); defer { lock.unlock() }; return cancelled }

        var source: ResourceDataSource {
            ResourceDataSource(
                requestData: { [self] progress, dataReceived, completion in
                    lock.lock()
                    let index = recorded.count
                    let request = Request(
                        id: PHAssetResourceDataRequestID(index + 1),
                        progress: progress, dataReceived: dataReceived, completion: completion
                    )
                    recorded.append(request)
                    let body = script[index]
                    lock.unlock()
                    if let body { DispatchQueue.global().async { body(request) } }
                    return request.id
                },
                cancelDataRequest: { [self] id in
                    lock.lock()
                    cancelled.append(id)
                    let request = recorded.first { $0.id == id }
                    lock.unlock()
                    if let request { onCancel?(request) }
                }
            )
        }

        func waitFor(_ what: String, timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline { XCTFail("timeout: \(what)"); return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    private final class FootprintSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var count = 0
        private var running = false

        var snapshot: (peak: UInt64, count: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (peak, count)
        }

        /// A thread, not a Task: the export runs on the cooperative pool, and a
        /// sampler queued behind it would never see it run.
        func start() {
            lock.lock()
            running = true
            lock.unlock()
            let thread = Thread { [self] in
                while true {
                    lock.lock()
                    let keepGoing = running
                    lock.unlock()
                    guard keepGoing else { return }
                    let value = Self.physFootprint()
                    lock.lock()
                    peak = max(peak, value)
                    count += 1
                    lock.unlock()
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() {
            lock.lock()
            running = false
            lock.unlock()
        }

        static func physFootprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
                }
            }
            return status == KERN_SUCCESS ? info.phys_footprint : 0
        }
    }

    private func makeDest() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("resource-export-\(UUID().uuidString)")
    }

    private static func describe(_ state: BackupExportState) -> String {
        switch state {
        case .downloadingFromICloud(let fraction): "downloading(\(fraction))"
        case .retryingICloud(let attempt): "retrying(\(attempt))"
        }
    }

    private func export(
        _ dest: URL,
        _ fake: FakeResourceData,
        stall: TimeInterval = 30,
        retryDelayNanos: UInt64 = 1_000_000,
        states: Log<String> = Log(),
        openFile: (URL) -> FileHandle? = PhotoLibraryServiceImpl.openEmptyFile
    ) async throws -> URL {
        try await PhotoLibraryServiceImpl.exportResource(
            to: dest, source: fake.source, stallInterval: stall, retryAttempts: 2,
            retryDelayNanos: retryDelayNanos, openFile: openFile,
            onState: { states.append(Self.describe($0)) }
        )
    }

    private func failure(of task: Task<URL, Error>) async -> Error? {
        switch await task.result {
        case .success: nil
        case .failure(let error): error
        }
    }

    private func content(of url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private static let cloud1005 = NSError(domain: "CloudPhotoLibraryErrorDomain", code: 1005)

    // MARK: ResourceFileWriter / ResourceDataRequest

    func test_AC18_resourceFileWriter_keepsChunkOrderAndClosesOnce() throws {
        let url = makeDest()
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = ResourceFileWriter(handle: try FileHandle(forWritingTo: url))

        XCTAssertNil(writer.append(Data("ab".utf8)))
        XCTAssertEqual(content(of: url), "ab", "le morceau est sur le disque avant toute fermeture")
        XCTAssertNil(writer.append(Data("cd".utf8)))
        XCTAssertNil(writer.append(Data("ef".utf8)))
        XCTAssertNil(writer.close())
        XCTAssertNil(writer.append(Data("zz".utf8)), "écriture après fermeture ignorée")
        XCTAssertNil(writer.close(), "double fermeture sans effet")

        XCTAssertEqual(content(of: url), "abcdef")
    }

    func test_AC19_resourceFileWriter_reportsFirstWriteFailure() throws {
        let url = makeDest()
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = ResourceFileWriter(handle: try FileHandle(forReadingFrom: url))

        let first = writer.append(Data("ab".utf8))
        XCTAssertNotNil(first, "un handle en lecture seule refuse l'écriture")
        XCTAssertNil(writer.append(Data("cd".utf8)), "morceau ignoré après l'échec")
        let closeError = writer.close()
        XCTAssertNotNil(closeError)
        XCTAssertEqual(closeError as NSError?, first as NSError?, "la fermeture rend l'erreur du premier ajout")
    }

    func test_AC18_resourceDataRequest_cancelsOnceWhateverTheOrder() {
        // (a) cancel() avant l'identifiant.
        let a = Log<PHAssetResourceDataRequestID>()
        let requestA = ResourceDataRequest(cancelRequest: { a.append($0) })
        requestA.cancel()
        requestA.store(7)
        XCTAssertEqual(a.values, [7])
        requestA.cancel()
        XCTAssertEqual(a.values, [7])

        // (b) identifiant avant cancel().
        let b = Log<PHAssetResourceDataRequestID>()
        let requestB = ResourceDataRequest(cancelRequest: { b.append($0) })
        requestB.store(9)
        XCTAssertEqual(b.values, [])
        requestB.cancel()
        XCTAssertEqual(b.values, [9])
        requestB.cancel()
        XCTAssertEqual(b.values, [9])

        // (c) jamais d'annulation sans cancel().
        let c = Log<PHAssetResourceDataRequestID>()
        let requestC = ResourceDataRequest(cancelRequest: { c.append($0) })
        requestC.store(11)
        XCTAssertEqual(c.values, [])
    }

    // MARK: exportResource

    func test_AC12_exportResource_writesChunksInOrderAndReturnsDest() async throws {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let fake = FakeResourceData()
        fake.script[0] = { request in
            for chunk in ["ab", "cd", "ef"] { request.dataReceived(Data(chunk.utf8)) }
            request.completion(nil)
        }

        let url = try await export(dest, fake)

        XCTAssertEqual(url, dest)
        XCTAssertEqual(content(of: dest), "abcdef")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int, 6)
        XCTAssertEqual(fake.cancelledIDs, [])
    }

    /// Contrainte « Mémoire » : 256 Mio livrés, jamais accumulés.
    func test_AC12_exportResource_largeOriginalKeepsMemoryFootprintFlat() async throws {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let chunk = Data(count: 1 << 20)
        let fake = FakeResourceData()
        fake.script[0] = { request in
            for _ in 0..<256 { request.dataReceived(chunk) }
            request.completion(nil)
        }
        let base = FootprintSampler.physFootprint()
        let sampler = FootprintSampler()
        sampler.start()

        let url = try await export(dest, fake)
        sampler.stop()

        XCTAssertEqual(url, dest)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int, 256 << 20)
        let snapshot = sampler.snapshot
        XCTAssertGreaterThanOrEqual(snapshot.count, 2, "la fenêtre de l'export a été observée")
        XCTAssertLessThan(snapshot.peak, base + (64 << 20), "l'export est en flux, pas accumulé")
    }

    func test_AC13_exportResource_forwardsDownloadProgress() async throws {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let states = Log<String>()
        let fake = FakeResourceData()
        fake.script[0] = { request in
            request.progress(0.5)
            request.completion(nil)
        }

        _ = try await export(dest, fake, states: states)

        XCTAssertEqual(states.values, ["downloading(0.5)"])
    }

    func test_AC6_exportResource_cancelDuringDownloadCancelsRequestAndThrowsCancellation() async {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let fake = FakeResourceData()
        fake.script[0] = { $0.dataReceived(Data("ab".utf8)) }
        let task = Task { try await self.export(dest, fake) }
        await fake.waitFor("morceau écrit") { self.content(of: dest) == "ab" }

        let start = Date()
        task.cancel()
        let error = await failure(of: task)

        XCTAssertTrue(error is CancellationError, "obtenu : \(String(describing: error))")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(fake.cancelledIDs, [1])
    }

    func test_AC7_exportResource_cancelDuringDownloadLeavesNoFile() async {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let fake = FakeResourceData()
        fake.script[0] = { $0.dataReceived(Data("ab".utf8)) }
        let task = Task { try await self.export(dest, fake) }
        // L'existence de `dest` ne suffit pas (créé vide) : "ab" prouve l'écriture
        // dès la réception, sans attendre la complétion.
        await fake.waitFor("morceau écrit") { self.content(of: dest) == "ab" }

        task.cancel()
        _ = await failure(of: task)

        XCTAssertFalse(exists(dest))
        let late = fake.requests[0]
        late.dataReceived(Data("zz".utf8))
        late.completion(nil)
        XCTAssertFalse(exists(dest), "les octets tardifs ne recréent rien")
    }

    func test_AC9_exportResource_stallDefersWithoutCancellingAndIgnoresLateChunks() async {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let fake = FakeResourceData()
        fake.script[0] = { $0.dataReceived(Data("ab".utf8)) }

        do {
            _ = try await export(dest, fake, stall: 0.1)
            XCTFail("doit lever cloudDownloadPending")
        } catch let error as BackupExportError {
            guard case .cloudDownloadPending = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("obtenu : \(error)")
        }

        XCTAssertEqual(fake.cancelledIDs, [])
        XCTAssertFalse(exists(dest))
        let late = fake.requests[0]
        late.dataReceived(Data("cd".utf8))
        late.completion(nil)
        XCTAssertFalse(exists(dest), "writer fermé : rien n'est recréé")
    }

    func test_AC14_exportResource_retries1005ThenDefers() async {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let states = Log<String>()
        let fake = FakeResourceData()
        for index in 0...2 { fake.script[index] = { $0.completion(Self.cloud1005) } }

        do {
            _ = try await export(dest, fake, states: states)
            XCTFail("doit lever cloudDownloadPending")
        } catch let error as BackupExportError {
            guard case .cloudDownloadPending = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("obtenu : \(error)")
        }

        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertEqual(states.values, ["retrying(1)"])
        XCTAssertFalse(exists(dest))
    }

    func test_AC14_exportResource_retryRestartsFromEmptyFile() async throws {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let fake = FakeResourceData()
        fake.script[0] = { request in
            request.dataReceived(Data("xx".utf8))
            request.completion(Self.cloud1005)
        }
        fake.script[1] = { request in
            request.dataReceived(Data("ok".utf8))
            request.completion(nil)
        }

        let url = try await export(dest, fake)

        XCTAssertEqual(url, dest)
        XCTAssertEqual(content(of: dest), "ok")
    }

    func test_AC15_exportResource_cancelDuringBackoffStartsNoNewAttempt() async {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let states = Log<String>()
        let fake = FakeResourceData()
        fake.script[0] = { $0.completion(Self.cloud1005) }
        let task = Task { try await self.export(dest, fake, retryDelayNanos: 30_000_000_000, states: states) }
        await fake.waitFor("état de relance") { states.values == ["retrying(1)"] }

        let start = Date()
        task.cancel()
        let error = await failure(of: task)

        XCTAssertTrue(error is CancellationError, "obtenu : \(String(describing: error))")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(states.values, ["retrying(1)"])
        XCTAssertFalse(exists(dest))
    }

    func test_AC15_exportResource_alreadyCancelledStartsNoRequest() async {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let fake = FakeResourceData()
        let task = Task { () -> URL in
            // Rendue immédiatement par l'annulation ; l'export démarre ensuite annulé.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return try await self.export(dest, fake)
        }
        task.cancel()

        let error = await failure(of: task)

        XCTAssertTrue(error is CancellationError, "obtenu : \(String(describing: error))")
        XCTAssertEqual(fake.requests.count, 0)
        XCTAssertFalse(exists(dest))
    }

    func test_AC16_exportResource_photoKitErrorAfterCancelIsCancellation() async {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let fake = FakeResourceData()
        fake.script[0] = { $0.dataReceived(Data("ab".utf8)) }
        fake.onCancel = { request in
            request.completion(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.userCancelled.rawValue))
        }
        let task = Task { try await self.export(dest, fake) }
        await fake.waitFor("morceau écrit") { self.content(of: dest) == "ab" }

        task.cancel()
        let error = await failure(of: task)

        XCTAssertTrue(error is CancellationError, "obtenu : \(String(describing: error))")
        XCTAssertFalse(exists(dest))
    }

    func test_AC17_exportResource_unopenableDestinationFailsWithoutRequest() async {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathComponent("file")
        let fake = FakeResourceData()

        do {
            _ = try await export(dest, fake)
            XCTFail("doit lever")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown)
            XCTAssertFalse(error is BackupExportError)
            XCTAssertFalse(UserFacingError.isCancellation(error))
            XCTAssertEqual(error.userFacingMessage, UserFacingError.genericMessage)
        }

        XCTAssertEqual(fake.requests.count, 0)
        XCTAssertFalse(exists(dest))
    }

    func test_AC18_exportResource_writeFailureCancelsRequestAndFails() async {
        let dest = makeDest()
        defer { try? FileManager.default.removeItem(at: dest) }
        let fake = FakeResourceData()
        fake.script[0] = { $0.dataReceived(Data("ab".utf8)) }

        do {
            // Fichier créé puis ouvert en lecture seule : l'écriture du morceau échoue.
            _ = try await export(dest, fake) { url in
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
                return try? FileHandle(forReadingFrom: url)
            }
            XCTFail("doit lever")
        } catch {
            XCTAssertFalse(error is BackupExportError)
            XCTAssertFalse(UserFacingError.isCancellation(error))
            XCTAssertEqual(error.userFacingMessage, UserFacingError.genericMessage)
        }

        XCTAssertEqual(fake.cancelledIDs, [1])
        XCTAssertEqual(fake.requests.count, 1, "aucune nouvelle tentative")
        XCTAssertFalse(exists(dest))
    }
}

/// Guards the iCloud-retry classifier: a CloudPhotoLibraryErrorDomain 1005
/// ("asset not local and not preparing") is transient and must be retried,
/// while any other error is surfaced immediately as a failure.
final class CloudNotReadyTests: XCTestCase {
    private func cloudError() -> NSError {
        NSError(domain: "CloudPhotoLibraryErrorDomain", code: 1005)
    }

    func test_directCloud1005_isRetryable() {
        XCTAssertTrue(PhotoLibraryServiceImpl.isCloudNotReady(cloudError()))
    }

    func test_wrappedCloud1005_isRetryable() {
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: 4864,
            userInfo: [NSUnderlyingErrorKey: cloudError()]
        )
        XCTAssertTrue(PhotoLibraryServiceImpl.isCloudNotReady(wrapped))
    }

    func test_otherCloudCode_isNotRetryable() {
        let other = NSError(domain: "CloudPhotoLibraryErrorDomain", code: 42)
        XCTAssertFalse(PhotoLibraryServiceImpl.isCloudNotReady(other))
    }

    func test_unrelatedError_isNotRetryable() {
        XCTAssertFalse(PhotoLibraryServiceImpl.isCloudNotReady(APIError.decoding("boom")))
    }
}

/// The Check of "On this device" exports into `BackupExportDirectory.localCheck`
/// while backup runs empty `BackupExportDirectory.backup` at their start.
final class ExportDirectoryTests: XCTestCase {
    func test_AC23_purgeStaleExports_leavesTheCheckDirectory() throws {
        let fm = FileManager.default
        let name = "ac23-\(UUID().uuidString)"
        let kept = BackupExportDirectory.localCheck.appendingPathComponent(name)
        let purged = BackupExportDirectory.backup.appendingPathComponent(name)
        for url in [kept, purged] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        defer { try? fm.removeItem(at: kept) }

        PhotoLibraryServiceImpl().purgeStaleExports()

        XCTAssertTrue(fm.fileExists(atPath: kept.path), "the Check's export must survive a run's purge")
        XCTAssertFalse(fm.fileExists(atPath: purged.path))
    }
}

/// Ledger: assets already backed up (uploaded or server-confirmed duplicate)
/// are skipped before export on later runs, so an iCloud library is never
/// re-downloaded run after run.
final class BackupLedgerTests: XCTestCase {

    private func candidate(_ id: String, modifiedAt: String = "2024-07-01T00:00:00.000Z") -> BackupCandidate {
        BackupCandidate(
            id: id, kind: .image, fileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: modifiedAt,
            duration: nil, isFavorite: false
        )
    }

    private func settings() -> BackupSettings { BackupSettings(isEnabled: true) }

    @MainActor
    func test_ledger_skipsUploadedAndRejectedOnSecondRun() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2")]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "c1", action: "accept"),
            .init(id: "c2", action: "reject", reason: "duplicate"),
        ])
        let engine = BackupEngine(
            client: mock, source: source,
            environment: MockBackupEnvironment(), ledger: BackupLedger.inMemory()
        )

        await engine.run(settings: settings())
        XCTAssertEqual(engine.total, 2)
        XCTAssertEqual(engine.uploadedCount, 1)
        XCTAssertEqual(engine.rejectedCount, 1)
        XCTAssertEqual(source.purgeCount, 1, "stale temp purge runs once per run")

        // Second run: c1 (uploaded) and c2 (server duplicate) are both tracked,
        // so nothing is exported/downloaded again.
        await engine.run(settings: settings())
        XCTAssertEqual(engine.total, 0, "already-backed-up assets are skipped before export")
        XCTAssertEqual(engine.uploadedCount, 0)
        XCTAssertEqual(source.purgeCount, 2)
    }

    @MainActor
    func test_ledger_reconsidersEditedAssetByModificationSignature() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1", modifiedAt: "2024-01-01T00:00:00.000Z")]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "c1", action: "accept"),
        ])
        let engine = BackupEngine(
            client: mock, source: source,
            environment: MockBackupEnvironment(), ledger: BackupLedger.inMemory()
        )

        await engine.run(settings: settings())
        XCTAssertEqual(engine.uploadedCount, 1)

        // Same id, newer modification date → the ledger no longer matches, so
        // the edited asset is backed up again.
        source.candidates = [candidate("c1", modifiedAt: "2025-06-01T00:00:00.000Z")]
        await engine.run(settings: settings())
        XCTAssertEqual(engine.total, 1, "edited asset (new signature) is reconsidered")
        XCTAssertEqual(engine.uploadedCount, 1)
    }

    @MainActor
    func test_ledger_forgetAllBackedUp_reprocessesEverything() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "c1", action: "accept"),
        ])
        let engine = BackupEngine(
            client: mock, source: source,
            environment: MockBackupEnvironment(), ledger: BackupLedger.inMemory()
        )

        await engine.run(settings: settings())
        XCTAssertEqual(engine.trackedAssetCount, 1)

        engine.forgetAllBackedUp()
        XCTAssertEqual(engine.trackedAssetCount, 0)

        await engine.run(settings: settings())
        XCTAssertEqual(engine.total, 1, "cleared ledger re-checks the whole library")
        XCTAssertEqual(engine.uploadedCount, 1)
    }
}

// MARK: - Helpers partagés (tests d'annulation)

/// Porte « suspendue jusqu'à l'annulation » : seule l'annulation la libère en
/// moins de 30 s ; les tests vérifient donc que `run` rend la main en < 5 s.
@Sendable func suspendUntilCancelled() async throws {
    try await Task.sleep(for: .seconds(30))
}

@MainActor
func pollUntil(
    _ what: String = "condition",
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting for \(what)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// Porte libérée par le test (attentes qui ne tournent pas dans la Task annulée).
final class TestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() {
        lock.lock()
        isOpen = true
        lock.unlock()
    }

    func wait() async throws {
        while true {
            lock.lock()
            let open = isOpen
            lock.unlock()
            if open { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Capture mutable pour les closures `@Sendable`.
final class TestBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Arrêt pendant l'export iCloud (suite de « export PhotoKit annulable »)

/// Un Stop, une expiration BG ou une déconnexion pendant l'export de l'original
/// d'un asset rend la main en moins d'1 s, sans échec ni report, et laisse le
/// moteur réarmé. L'export est simulé par `MockBackupAssetSource.exportGate` ;
/// le raccord PhotoKit est prouvé par `ResourceExportHelpersTests`.
final class BackupExportStopTests: XCTestCase {

    private struct Rig {
        let client: MockImmichClient
        let source: MockBackupAssetSource
        let ledger: BackupLedger
        let engine: BackupEngine
        let vm: UploadViewModel
        let detail: UploadDetailViewModel
        /// Erreur avec laquelle l'export suspendu est sorti.
        let exportError: TestBox<Error?>
    }

    private func candidate(_ id: String) -> BackupCandidate {
        BackupCandidate(
            id: id, kind: .image, fileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            duration: nil, isFavorite: false
        )
    }

    /// Un asset « c1 » dont l'export remonte 40 % de téléchargement iCloud puis
    /// reste suspendu jusqu'à l'annulation.
    @MainActor
    private func makeRig() -> Rig {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: [.init(id: "c1", action: "accept")]
        )
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        source.iCloudFractions = ["c1": 0.4]
        let exportError = TestBox<Error?>(nil)
        source.exportGate = { _ in
            do { try await suspendUntilCancelled() } catch {
                exportError.value = error
                throw error
            }
        }
        let ledger = BackupLedger.inMemory()
        let engine = BackupEngine(
            client: client, source: source, environment: MockBackupEnvironment(), ledger: ledger
        )
        let store = BackupSettingsStore(suiteName: "backup-export-stop-\(UUID().uuidString)")
        store.isEnabled = true
        let vm = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(),
            engine: engine, settings: store,
            scheduler: MockBackupScheduler(), activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )
        return Rig(
            client: client, source: source, ledger: ledger, engine: engine, vm: vm,
            detail: UploadDetailViewModel(upload: vm), exportError: exportError
        )
    }

    /// L'export de c1 est en vol et son état « Downloading from iCloud » est en place.
    @MainActor
    private func waitForSuspendedExport(_ rig: Rig) async {
        await pollUntil("export de c1 en vol") { rig.source.exportedIDs == ["c1"] }
        await pollUntil("progression iCloud de c1") { rig.engine.iCloudProgress["c1"] == 0.4 }
    }

    /// Assertions communes à AC-40 et AC-41 (le moteur est réarmé, rien n'est compté).
    @MainActor
    private func assertStoppedCleanly(_ rig: Rig, elapsed: Duration, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(elapsed, .seconds(1), "l'arrêt n'attend pas la fin du téléchargement", file: file, line: line)
        XCTAssertTrue(rig.exportError.value is CancellationError, "l'export reçoit l'annulation", file: file, line: line)
        XCTAssertEqual(rig.engine.phase, .cancelled, file: file, line: line)
        XCTAssertEqual(rig.engine.failedCount, 0, file: file, line: line)
        XCTAssertEqual(rig.engine.deferredCount, 0, file: file, line: line)
        XCTAssertTrue(rig.client.uploads.isEmpty, file: file, line: line)
        XCTAssertEqual(rig.ledger.trackedCount(), 0, file: file, line: line)
        XCTAssertFalse(rig.engine.isCancelling, file: file, line: line)
        XCTAssertNil(rig.engine.currentAssetID, file: file, line: line)
        XCTAssertNil(rig.engine.currentFileName, file: file, line: line)
        XCTAssertEqual(rig.detail.currentState, .idle, "Upload detail ne montre plus d'asset en cours", file: file, line: line)
        XCTAssertNil(rig.detail.currentICloudFraction, file: file, line: line)
    }

    /// AC-40 (B-40) : Stop pendant l'export iCloud.
    @MainActor
    func test_ExportStop_AC40_stopDuringICloudExportEndsRunUnderOneSecond() async {
        let rig = makeRig()
        let run = Task { @MainActor in await rig.vm.runBackup(manual: true) }
        await waitForSuspendedExport(rig)
        XCTAssertEqual(rig.detail.currentState, .downloading(0.4))

        let elapsed = await ContinuousClock().measure {
            rig.vm.cancelBackup()
            _ = await run.value
        }

        assertStoppedCleanly(rig, elapsed: elapsed)
    }

    /// AC-41 (B-41) : expiration de la tâche de fond pendant l'export iCloud.
    @MainActor
    func test_ExportStop_AC41_bgExpirationDuringICloudExportEndsRunUnderOneSecond() async {
        let rig = makeRig()
        let run = Task { @MainActor in await rig.vm.runBackup() }
        await waitForSuspendedExport(rig)
        XCTAssertEqual(rig.detail.currentState, .downloading(0.4))

        // Ce que fait `expirationHandler` : appel depuis une file de fond.
        let engine = rig.engine
        let elapsed = await ContinuousClock().measure {
            await Task.detached { await MainActor.run { engine.cancel() } }.value
            _ = await run.value
        }

        assertStoppedCleanly(rig, elapsed: elapsed)
    }

    /// AC-42 (B-41) : déconnexion (`stopAndWait`) pendant l'export iCloud.
    @MainActor
    func test_ExportStop_AC42_stopAndWaitDuringICloudExportReturnsUnderOneSecond() async {
        let rig = makeRig()
        let engine = rig.engine
        let run = Task { @MainActor in
            await engine.run(settings: BackupSettings(isEnabled: true), manual: true)
        }
        await waitForSuspendedExport(rig)

        let elapsed = await ContinuousClock().measure { await engine.stopAndWait() }
        let isRunActive = engine.isRunActive
        _ = await run.value

        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertTrue(rig.exportError.value is CancellationError)
        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertEqual(engine.failedCount, 0)
        XCTAssertEqual(engine.deferredCount, 0)
        XCTAssertTrue(rig.client.uploads.isEmpty)
        XCTAssertEqual(rig.ledger.trackedCount(), 0)
        XCTAssertFalse(isRunActive, "la déconnexion vide les stores après stopAndWait()")
        XCTAssertNil(engine.currentAssetID)
        XCTAssertNil(engine.currentFileName)
    }

    /// AC-43 (B-42) : après un Stop pendant l'export, le run suivant réexporte l'asset.
    @MainActor
    func test_ExportStop_AC43_runAfterExportStopReexportsAndBacksUpInterruptedAsset() async {
        let rig = makeRig()
        let first = Task { @MainActor in await rig.vm.runBackup(manual: true) }
        await waitForSuspendedExport(rig)
        rig.vm.cancelBackup()
        _ = await first.value
        XCTAssertEqual(rig.engine.phase, .cancelled)

        rig.source.exportGate = nil
        let result = await rig.vm.runBackup(manual: true)

        XCTAssertEqual(
            result,
            .completed(BackupRunOutcome(backedUpIDs: ["c1"], failures: [], deferrals: [], wasCancelled: false))
        )
        XCTAssertEqual(rig.source.exportedIDs, ["c1", "c1"], "l'asset interrompu est réexporté")
        XCTAssertEqual(rig.client.uploads.map(\.deviceAssetId), ["c1"])
        XCTAssertTrue(rig.ledger.isBackedUp(id: "c1", signature: "2024-07-01T00:00:00.000Z"))
        XCTAssertEqual(rig.engine.phase, .done)
        XCTAssertEqual(rig.engine.failedCount, 0)
        XCTAssertEqual(rig.engine.deferredCount, 0)
    }
}
