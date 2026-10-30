import Foundation
import XCTest
@testable import ImmichSwiftUI

/// Sync status (AC-5030–5039): the screen's view model reads the ledger, the
/// run and the offline index from the two view models that own them, and
/// delegates every action back to the owner of the state.
///
/// Everything asserted below is what the user reads on screen, computed by
/// driving real runs and real downloads through the mocks — never a stored copy
/// the view model kept for itself.
@MainActor
final class SyncStatusViewModelTests: XCTestCase {

    private var folder: URL!
    private var defaults: UserDefaults!
    private var transport: MockFileDownloadTransport!

    private let baseURL = URL(string: "https://example.com")!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-status-tests-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "sync-status-tests-\(UUID().uuidString)")!
        transport = MockFileDownloadTransport()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - Harness

    private struct Harness {
        let sut: SyncStatusViewModel
        let upload: UploadViewModel
        let offline: OfflineDownloadViewModel
        let engine: BackupEngine
        let ledger: BackupLedger
        let index: OfflineAssetIndex
        let store: OfflineAssetStore
        let settings: BackupSettingsStore
    }

    private func makeHarness(
        client: MockImmichClient,
        source: MockBackupAssetSource,
        environment: MockBackupEnvironment = MockBackupEnvironment()
    ) -> Harness {
        let ledger = BackupLedger.inMemory()
        let engine = BackupEngine(
            client: client, source: source, environment: environment, ledger: ledger
        )
        let settings = BackupSettingsStore(suiteName: "sync-status-\(UUID().uuidString)")
        let upload = UploadViewModel(
            client: client,
            photos: MockPhotoLibraryService(),
            engine: engine,
            settings: settings,
            scheduler: MockBackupScheduler(),
            activityService: MockBackupLiveActivityService(),
            readOnly: .ephemeral()
        )
        let store = OfflineAssetStore(rootURL: folder, transport: transport, defaults: defaults)
        store.setActiveAccount(OfflineAssetStoreTests.accountA, otherAccountsRegistered: false)
        let index = OfflineAssetIndex()
        let offline = OfflineDownloadViewModel(
            store: store, client: client, index: index, accountID: OfflineAssetStoreTests.accountA
        )
        return Harness(
            sut: SyncStatusViewModel(upload: upload, offline: offline),
            upload: upload,
            offline: offline,
            engine: engine,
            ledger: ledger,
            index: index,
            store: store,
            settings: settings
        )
    }

    private func candidate(_ id: String) -> BackupCandidate {
        BackupCandidate(
            id: id, kind: .image, fileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            duration: nil, isFavorite: false
        )
    }

    private func reactItem(_ id: String) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 0.75, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: "thumb",
            createdAt: "2024-07-01T10:00:00.000Z", fileCreatedAt: "2024-07-01T10:00:00.000Z",
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    /// A library of `ids` the server accepts, with `rejected` of them already
    /// on the server (the dedup path, not a failure).
    private func library(_ ids: [String], rejected: [String] = []) -> (MockImmichClient, MockBackupAssetSource) {
        let client = MockImmichClient()
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: ids.map {
                AssetBulkUploadCheckResponse.Result(
                    id: $0, action: rejected.contains($0) ? "reject" : "accept"
                )
            }
        )
        let source = MockBackupAssetSource()
        source.candidates = ids.map { candidate($0) }
        source.dataProvider = { _ in Data(repeating: 5, count: 32) }
        return (client, source)
    }

    // MARK: - Counters

    func test_counters_mirrorEngineAndLedger() async {
        let (client, source) = library(["c1", "c2", "c3"], rejected: ["c3"])
        let harness = makeHarness(client: client, source: source)

        await harness.sut.runNow()

        XCTAssertEqual(harness.sut.uploadedCount, 2, "two assets went up")
        XCTAssertEqual(harness.sut.alreadyOnServerCount, 1, "one was already there — skipped, not failed")
        XCTAssertEqual(harness.sut.trackedCount, 3, "the ledger records every settled asset")
        XCTAssertEqual(harness.sut.failedCount, 0)
        XCTAssertEqual(harness.sut.deferredCount, 0)
        XCTAssertEqual(harness.sut.offlineCount, 0, "no download happened: the offline index is untouched")
    }

    /// `total` keeps the finished run's denominator, so the "Waiting" tile must
    /// subtract what is already settled instead of showing the run's size.
    func test_pendingCount_excludesSettledAssets() async {
        let (client, source) = library(["c1", "c2", "c3"])
        source.deferIDs = ["c3"]
        let harness = makeHarness(client: client, source: source)

        await harness.sut.runNow()

        XCTAssertEqual(harness.engine.total, 3, "the run's denominator survives the run")
        XCTAssertEqual(harness.sut.pendingCount, 0, "nothing waits once every asset has an outcome")
        XCTAssertEqual(harness.sut.deferredCount, 1, "the iCloud asset is held back, not pending")
    }

    /// The "Ready to upload" tile is the queue's backlog: it grows while
    /// originals are exported + hashed and falls back to zero once the chunk
    /// has been deduped and uploaded.
    func test_stagedCount_isTheUploadQueueBacklog() async {
        let (client, source) = library(["c1", "c2", "c3"])
        let harness = makeHarness(client: client, source: source)
        var samples: [Int] = []
        source.dataProvider = { _ in
            samples.append(harness.sut.stagedCount)
            return Data(repeating: 5, count: 32)
        }

        await harness.sut.runNow()

        XCTAssertEqual(samples, [0, 1, 2], "each export adds one to the backlog, in order")
        XCTAssertEqual(harness.sut.stagedCount, 0, "an uploaded asset leaves the queue")
        XCTAssertEqual(harness.sut.uploadedCount, 3)
    }

    func test_lastRun_isTheMostRecentHistoryEntry() async {
        let (client, source) = library(["a1"])
        let harness = makeHarness(client: client, source: source)

        await harness.sut.runNow()
        XCTAssertEqual(harness.sut.lastRun?.uploaded, 1)

        source.candidates = ["a1", "a2", "a3"].map { candidate($0) }
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(
            results: ["a2", "a3"].map { AssetBulkUploadCheckResponse.Result(id: $0, action: "accept") }
        )

        await harness.sut.runNow()

        XCTAssertEqual(harness.upload.uploadHistory.count, 2, "two runs on record")
        XCTAssertEqual(harness.sut.lastRun?.uploaded, 2, "the newest run, not the first one")
        XCTAssertEqual(harness.sut.lastRun?.total, 2, "a1 was already tracked, so it is not in this run")
    }

    // MARK: - Offline index

    func test_offlineCount_andBytes_comeFromTheDownloadViewModel() async {
        let (client, source) = library(["c1"])
        let harness = makeHarness(client: client, source: source)
        transport.payload = Data(repeating: 0x01, count: 300)

        await harness.offline.downloadAsset(reactItem("pinned-1"), baseURL: baseURL, token: "tok")
        await harness.offline.downloadAsset(reactItem("pinned-2"), baseURL: baseURL, token: "tok")
        await harness.sut.refresh()

        XCTAssertEqual(harness.sut.offlineCount, 2)
        XCTAssertEqual(harness.sut.offlineBytes, 600, "the bytes are the ones on disk")
        XCTAssertEqual(harness.sut.formattedOfflineBytes(), harness.offline.formattedUsage(600))
        XCTAssertFalse(harness.sut.formattedOfflineBytes().isEmpty, "the tile reads a size, never a blank")
        XCTAssertTrue(harness.index.isCached("pinned-1"))
    }

    // MARK: - Actions

    /// Reset is only useful if it actually clears the ledger: the next run must
    /// re-check and re-upload what it had been skipping.
    func test_resetLedger_delegates_andEmptiesTrackedCount() async {
        let (client, source) = library(["c1", "c2"])
        let harness = makeHarness(client: client, source: source)
        await harness.sut.runNow()
        XCTAssertEqual(harness.sut.trackedCount, 2)

        harness.sut.resetLedger()

        XCTAssertEqual(harness.sut.trackedCount, 0, "the ledger is empty after a reset")
        XCTAssertEqual(harness.ledger.trackedCount(), 0)

        await harness.sut.runNow()

        XCTAssertEqual(harness.sut.uploadedCount, 2, "everything is re-uploaded: the skip is gone")
        XCTAssertEqual(harness.sut.trackedCount, 2)
    }

    func test_clearOfflineCache_emptiesTheIndex() async {
        let (client, source) = library(["c1"])
        let harness = makeHarness(client: client, source: source)
        transport.payload = Data(repeating: 0x02, count: 128)
        await harness.offline.downloadAsset(reactItem("pinned-1"), baseURL: baseURL, token: "tok")
        await harness.sut.refresh()
        XCTAssertEqual(harness.sut.offlineCount, 1)

        await harness.sut.clearOfflineCache()

        XCTAssertEqual(harness.sut.offlineCount, 0)
        XCTAssertEqual(harness.sut.offlineBytes, 0)
        let bytesLeftOnDisk = await harness.store.totalBytes()
        XCTAssertEqual(bytesLeftOnDisk, 0, "the files are gone from disk")
        XCTAssertFalse(harness.index.isCached("pinned-1"), "the timeline badge forgets it too")
    }

    /// "Run now" is the manual path: it goes even with auto-backup off and no
    /// Wi-Fi, waits for the run to settle, and lands in the history — the three
    /// things the button promises.
    func test_runNow_settlesTheEngineAndRecordsAHistoryEntry() async {
        let (client, source) = library(["c1", "c2"])
        let environment = MockBackupEnvironment()
        environment.hasWiFiValue = false
        let harness = makeHarness(client: client, source: source, environment: environment)
        harness.settings.isEnabled = false
        harness.settings.onlyOnWiFi = true

        await harness.sut.runNow()

        XCTAssertEqual(harness.sut.phase, .done, "the caller resumes once the run has settled")
        XCTAssertFalse(harness.sut.isRunning)
        XCTAssertEqual(harness.sut.uploadedCount, 2, "a manual run ignores the Wi-Fi gate")
        XCTAssertEqual(harness.sut.deferredCount, 0)
        XCTAssertEqual(harness.upload.uploadHistory.count, 1)
        XCTAssertEqual(harness.sut.lastRun?.uploaded, 2)
        XCTAssertEqual(harness.sut.lastRun?.success, true)
    }

    // MARK: - Empty state

    func test_emptyState_reportsNothingToSync() async {
        let (client, source) = library(["c1"])
        let harness = makeHarness(client: client, source: source)

        XCTAssertTrue(harness.sut.isEmpty, "no run, no queue, no cache: the screen shows its empty state")
        XCTAssertFalse(harness.sut.hasPendingWork)
        XCTAssertNil(harness.sut.lastRun)
        XCTAssertNil(harness.sut.lastServerCheck)
        XCTAssertEqual(harness.sut.formattedLastRun(), localizedString("Never"))
        XCTAssertEqual(harness.sut.formattedLastServerCheck(), localizedString("Never"))

        await harness.sut.reconcileNow()
        await harness.sut.runNow()

        XCTAssertFalse(harness.sut.isEmpty)
        XCTAssertNotNil(harness.sut.lastServerCheck, "the check is dated once it has run")
        XCTAssertNotEqual(harness.sut.formattedLastServerCheck(), localizedString("Never"))
    }
}
