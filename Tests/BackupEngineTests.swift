import CryptoKit
import Foundation
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

    @MainActor
    func test_backup_cancelBeforeRun() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2")]
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        engine.cancel()
        await engine.run(settings: settings())

        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertEqual(mock.requestCount, 0)
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
    /// blind PATCH.
    @MainActor
    func test_livePhoto_rejectWithoutAssetIdSkipsRepair() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [livePhoto("lp1")]
        source.livePhotoIDs = ["lp1"]
        source.dataProvider = { _ in Data(repeating: 3, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "lp1", action: "reject", reason: "duplicate"),
        ])
        let engine = BackupEngine(client: mock, source: source, environment: MockBackupEnvironment())

        await engine.run(settings: settings())

        XCTAssertTrue(mock.updateAssetCalls.isEmpty)
        XCTAssertEqual(mock.uploads.count, 0)
        XCTAssertEqual(engine.rejectedCount, 1)
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
        let vm = UploadViewModel(client: mockClient, photos: photos, engine: engine, settings: settings, scheduler: scheduler, activityService: activity)

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