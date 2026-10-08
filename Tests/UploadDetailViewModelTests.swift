import Foundation
import XCTest
@testable import ImmichSwiftUI

/// The per-asset report of a backup run: the engine seams it reads (Photos
/// identifier, size, held-back list, per-asset iCloud progress) and the two
/// retries that name their assets instead of rescanning the library.
final class UploadDetailViewModelTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let client: MockImmichClient
        let source: MockBackupAssetSource
        let environment: MockBackupEnvironment
        let engine: BackupEngine
        let settings: BackupSettingsStore
        let upload: UploadViewModel
        let vm: UploadDetailViewModel
    }

    private func candidate(
        id: String,
        name: String? = nil,
        size: Int64? = nil,
        kind: BackupAssetKind = .image,
        isLivePhoto: Bool = false
    ) -> BackupCandidate {
        BackupCandidate(
            id: id,
            kind: kind,
            fileName: name ?? "\(id).jpg",
            fileCreatedAt: "2024-01-01T00:00:00.000Z",
            fileModifiedAt: "2024-01-01T00:00:00.000Z",
            duration: nil,
            isFavorite: false,
            isLivePhoto: isLivePhoto,
            fileSize: size
        )
    }

    @MainActor
    private func makeHarness(
        candidates: [BackupCandidate],
        ledger: any BackupLedgerStoring = BackupLedger.inMemory()
    ) -> Harness {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = candidates
        source.dataProvider = { _ in Data(repeating: 0, count: 8) }
        let environment = MockBackupEnvironment()
        let engine = BackupEngine(
            client: client, source: source,
            environment: environment, ledger: ledger
        )
        let settings = BackupSettingsStore(suiteName: "upload-detail-\(UUID().uuidString)")
        let upload = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(), engine: engine,
            settings: settings, scheduler: MockBackupScheduler(),
            activityService: MockBackupLiveActivityService()
        )
        return Harness(
            client: client, source: source, environment: environment,
            engine: engine, settings: settings, upload: upload,
            vm: UploadDetailViewModel(upload: upload)
        )
    }

    /// The engine posts export progress through `Task { @MainActor in … }`, so
    /// the per-asset maps land on the main actor just after the export returns.
    /// The test drains that queue instead of asserting on a race.
    @MainActor
    private func drainMainActor() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func accepts(_ ids: String...) -> AssetBulkUploadCheckResponse {
        AssetBulkUploadCheckResponse(
            results: ids.map { AssetBulkUploadCheckResponse.Result(id: $0, action: "accept") }
        )
    }

    // MARK: - The restricted run

    /// A retry names its assets: the run reads exactly those identifiers, so a
    /// single failed photo doesn't cost a whole-library scan.
    @MainActor
    func test_restrictedRun_onlyTouchesTheGivenIDs() async {
        let h = makeHarness(candidates: [candidate(id: "c1"), candidate(id: "c2"), candidate(id: "c3")])
        h.client.bulkUploadCheckResponse = accepts("c2")

        await h.engine.run(settings: h.settings.snapshot(), manual: true, only: ["c2"])

        XCTAssertEqual(h.engine.total, 1)
        XCTAssertEqual(h.source.requestedIDs, ["c2"])
        XCTAssertEqual(h.source.exportedIDs, ["c2"])
        XCTAssertEqual(h.engine.uploadedCount, 1)
    }

    /// The ledger is what a *scan* uses to skip known assets. A retry must not
    /// consult it: the asset the user asked for is precisely the one the ledger
    /// can be wrong about (its still is on the server, its Live Photo link
    /// isn't), so honouring the filter would make every retry a no-op.
    @MainActor
    func test_restrictedRun_ignoresTheLedgerFilter() async {
        let ledger = BackupLedger.inMemory()
        let h = makeHarness(candidates: [candidate(id: "c1")], ledger: ledger)
        ledger.markBackedUp(id: "c1", signature: "2024-01-01T00:00:00.000Z", checksum: "abc")
        // Keep the weekly reconciliation pass out of the way: it would forget
        // the entry (the server answers "accept" to everything below).
        ledger.recordReconciliation(at: Date())
        h.client.bulkUploadCheckResponse = accepts("c1")

        await h.engine.run(settings: h.settings.snapshot(), manual: true)
        XCTAssertEqual(h.engine.total, 0, "a full run skips what the ledger tracks")

        await h.engine.run(settings: h.settings.snapshot(), manual: true, only: ["c1"])
        XCTAssertEqual(h.engine.total, 1)
        XCTAssertEqual(h.engine.uploadedCount, 1)
    }

    /// A Live Photo whose still is already on the server comes back as a
    /// `reject`: the run links the missing video onto it. When that link fails,
    /// the entry is an *advisory*, and retrying must be able to clear it —
    /// which requires re-deciding an asset the ledger now counts as done.
    @MainActor
    func test_retryOfALivePhotoLinkWarning_clearsTheStaleFailure() async {
        let h = makeHarness(candidates: [
            candidate(id: "lp1", name: "lp1.HEIC", isLivePhoto: true),
        ])
        h.source.livePhotoIDs = ["lp1"]
        h.client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "lp1", action: "reject", reason: "duplicate", assetId: "remote-photo-7"),
        ])
        // The link can't be made this run: the video upload inside the repair
        // fails, so the still stays on the server without its video.
        h.client.uploadErrorsByFilename = ["lp1.MOV": APIError.decoding("no link today")]

        await h.upload.retryAsset(id: "lp1")

        XCTAssertEqual(h.engine.rejectedCount, 1)
        XCTAssertEqual(h.engine.failures.count, 1)
        XCTAssertEqual(h.engine.failures.first?.assetID, "lp1")

        h.client.uploadErrorsByFilename = [:]
        h.client.uploadResponsesByFilename = ["lp1.MOV": AssetMediaResponseDto(id: "video-9", status: "created")]

        await h.upload.retryAsset(id: "lp1")

        XCTAssertTrue(h.engine.failures.isEmpty, "the warning is gone, not accumulated")
        XCTAssertEqual(h.engine.rejectedCount, 1)
        XCTAssertEqual(h.client.updateAssetCalls.count, 1, "the second run really re-did the link")
        XCTAssertEqual(h.client.updateAssetCalls.first?.id, "remote-photo-7")
    }

    // MARK: - Rows the report is built from

    /// Every failure row carries a key the library answers to (the Photos
    /// identifier) and the size the run knew: the scan's size when the asset
    /// never made it to disk, the measured size of the export when it did.
    @MainActor
    func test_failures_carryThePhotosIdentifierAndSize() async throws {
        let h = makeHarness(candidates: [
            candidate(id: "c1", name: "c1.jpg", size: 4096),
            candidate(id: "c2", name: "c2.jpg", size: 8192),
        ])
        h.client.bulkUploadCheckResponse = accepts("c2")
        h.source.failIDs = ["c1"]
        h.client.uploadErrorsByFilename = ["c2.jpg": APIError.decoding("server said no")]

        await h.engine.run(settings: h.settings.snapshot(), manual: true)

        XCTAssertEqual(h.engine.failures.count, 2)
        let exportFailure = try XCTUnwrap(h.engine.failures.first { $0.assetID == "c1" })
        XCTAssertEqual(exportFailure.name, "c1.jpg")
        XCTAssertEqual(exportFailure.fileSize, 4096, "the size the scan reported")

        let uploadFailure = try XCTUnwrap(h.engine.failures.first { $0.assetID == "c2" })
        XCTAssertEqual(uploadFailure.name, "c2.jpg")
        XCTAssertEqual(uploadFailure.fileSize, 8, "the size measured on the exported original")
    }

    /// Held back is a state, not an event: the same asset listed twice in one
    /// run (a source is free to hand it back twice) is one row — otherwise a
    /// retry loop would grow the list it is retrying from.
    @MainActor
    func test_deferrals_listTheHeldBackAssetsOnceEach() async throws {
        let h = makeHarness(candidates: [candidate(id: "d1", size: 4096)])
        h.source.deferIDs = ["d1"]

        await h.engine.run(settings: h.settings.snapshot(), manual: true, only: ["d1", "d1"])

        XCTAssertEqual(h.engine.deferredCount, 2, "the asset really was held back twice")
        XCTAssertEqual(h.engine.deferrals.count, 1, "…and is listed once")
        let entry = try XCTUnwrap(h.engine.deferrals.first)
        XCTAssertEqual(entry.id, "d1")
        XCTAssertEqual(entry.name, "d1.jpg")
        XCTAssertEqual(entry.reason, .waitingForICloud)
        XCTAssertEqual(entry.fileSize, 4096)
        XCTAssertEqual(entry.kind, .image)

        // A later run that holds the same asset back for the other reason
        // replaces the entry rather than adding a second one.
        h.source.deferIDs = []
        h.settings.isEnabled = true
        h.settings.onlyOnWiFi = true
        h.environment.hasWiFiValue = false

        await h.engine.run(settings: h.settings.snapshot(), manual: false, only: ["d1"])

        XCTAssertEqual(h.engine.deferrals.count, 1)
        XCTAssertEqual(h.engine.deferrals.first?.reason, .waitingForWiFi)
        XCTAssertEqual(h.source.exportedIDs, ["d1", "d1"], "a deferred asset is never downloaded")
    }

    /// The iCloud fraction is keyed by the asset it belongs to — one asset's
    /// download is never reported against another's, and each run starts clean.
    @MainActor
    func test_iCloudProgress_isTrackedPerAssetID() async {
        let h = makeHarness(candidates: [candidate(id: "a1"), candidate(id: "a2")])
        h.source.iCloudFractions = ["a1": 0.25, "a2": 0.75]
        h.source.iCloudRetries = ["a2": 2]
        h.client.bulkUploadCheckResponse = accepts("a1", "a2")

        await h.engine.run(settings: h.settings.snapshot(), manual: true, only: ["a1"])
        await drainMainActor()
        XCTAssertEqual(h.engine.iCloudProgress["a1"], 0.25)
        XCTAssertNil(h.engine.iCloudProgress["a2"], "an asset outside the run has no fraction")

        await h.engine.run(settings: h.settings.snapshot(), manual: true, only: ["a2"])
        await drainMainActor()
        XCTAssertEqual(h.engine.iCloudProgress["a2"], 0.75)
        XCTAssertEqual(h.engine.iCloudRetryAttempts["a2"], 2)
    }

    // MARK: - The retry actions

    /// "Retry all" is ONE run over exactly the failed ids — not one run per
    /// asset, and not a rescan that would export the healthy ones again.
    @MainActor
    func test_retryAllFailed_sendsOneRestrictedRunWithEveryFailedID() async {
        let h = makeHarness(candidates: [
            candidate(id: "c1"), candidate(id: "c2"), candidate(id: "c3"),
        ])
        h.source.failIDs = ["c1", "c2"]

        await h.upload.runBackup(manual: true)

        XCTAssertEqual(h.vm.failedCount, 2)
        XCTAssertEqual(h.engine.failures.map(\.assetID).sorted(), ["c1", "c2"])
        XCTAssertEqual(h.source.purgeCount, 1)
        XCTAssertEqual(h.source.exportedIDs, ["c1", "c2", "c3"])

        h.source.failIDs = []
        h.client.bulkUploadCheckResponse = accepts("c1", "c2")

        await h.vm.retryAllFailed()

        XCTAssertEqual(h.source.purgeCount, 2, "one more run, not one per asset")
        XCTAssertEqual(Array(h.source.exportedIDs.suffix(2)).sorted(), ["c1", "c2"])
        XCTAssertEqual(h.source.requestedIDs, ["c1", "c2"])
        XCTAssertEqual(h.engine.total, 2)
        XCTAssertEqual(h.engine.uploadedCount, 2)
        XCTAssertTrue(h.engine.failures.isEmpty)
        XCTAssertEqual(h.vm.failedCount, 0)
    }

    /// Nothing failed ⇒ no run at all: an empty asset list means "the whole
    /// library" to the engine, which is the opposite of a retry.
    @MainActor
    func test_retryAllFailed_withNothingFailed_startsNoRun() async {
        let h = makeHarness(candidates: [])

        await h.upload.runBackup(manual: true)
        XCTAssertEqual(h.source.purgeCount, 1)

        await h.vm.retryAllFailed()

        XCTAssertEqual(h.source.purgeCount, 1, "no second run")
        XCTAssertEqual(h.engine.phase, .done)
    }

    /// The default path is untouched: no ids means the full scan, and the
    /// per-id lookup is never used.
    @MainActor
    func test_restrictedRun_withNoIDs_scansTheWholeLibrary() async {
        let h = makeHarness(candidates: [candidate(id: "c1"), candidate(id: "c2")])
        h.client.bulkUploadCheckResponse = accepts("c1", "c2")

        await h.engine.run(settings: h.settings.snapshot(), manual: true)

        XCTAssertEqual(h.engine.total, 2)
        XCTAssertEqual(h.source.exportedIDs, ["c1", "c2"])
        XCTAssertTrue(h.source.requestedIDs.isEmpty)
    }

    // MARK: - Projection

    /// The screen view model owns no state: it reads the run that is already
    /// happening, before and after the run changes it.
    @MainActor
    func test_uploadDetailViewModel_projectsWithoutOwningState() async {
        let h = makeHarness(candidates: [candidate(id: "c1", size: 1024)])
        h.client.bulkUploadCheckResponse = accepts("c1")

        XCTAssertEqual(h.vm.total, 0)
        XCTAssertTrue(h.vm.isEmpty)
        XCTAssertEqual(h.vm.currentState, .idle)

        await h.upload.runBackup(manual: true)

        XCTAssertEqual(h.vm.total, 1)
        XCTAssertEqual(h.vm.uploadedCount, 1)
        XCTAssertEqual(h.vm.uploadedBytes, 8, "the bytes the run really sent")
        XCTAssertEqual(h.vm.failures.count, h.engine.failures.count)
        XCTAssertEqual(h.vm.deferrals.count, h.engine.deferrals.count)
        XCTAssertEqual(h.vm.progressFraction, h.engine.progressFraction)
        XCTAssertFalse(h.vm.isEmpty)
        XCTAssertEqual(h.vm.currentState, .idle)
        XCTAssertEqual(h.vm.currentStateLabel, "", "nothing in flight, nothing claimed")

        // A size the run doesn't know is never dressed up as a number.
        XCTAssertNotEqual(
            UploadDetailViewModel.formattedBytes(nil),
            UploadDetailViewModel.formattedBytes(0)
        )
    }
}
