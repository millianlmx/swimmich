import CryptoKit
import Foundation
import XCTest
@testable import ImmichSwiftUI

/// A server that remembers the checksums it was sent: `bulk-upload-check`
/// answers `reject` (with the asset id) for a known checksum, `accept` else.
final class FakeEditServer: @unchecked Sendable {
    var assetsByChecksum: [String: String] = [:]
    var trashedChecksums: Set<String> = []

    func respond(_ items: [AssetBulkUploadCheckRequest.Item]) -> AssetBulkUploadCheckResponse {
        AssetBulkUploadCheckResponse(results: items.map { item in
            guard let assetId = assetsByChecksum[item.checksum] else {
                return AssetBulkUploadCheckResponse.Result(id: item.id, action: "accept")
            }
            return AssetBulkUploadCheckResponse.Result(
                id: item.id, action: "reject", assetId: assetId,
                isTrashed: trashedChecksums.contains(item.checksum) ? true : nil
            )
        })
    }
}

/// "Also back up edits": the engine over a mock library and a fake server.
@MainActor
final class EditRig {
    static let t0 = "2024-07-01T00:00:00.000Z"
    static let t1 = "2024-07-02T00:00:00.000Z"
    static let t2 = "2024-07-03T00:00:00.000Z"
    static let t3 = "2024-07-04T00:00:00.000Z"

    let mock = MockImmichClient()
    let source = MockBackupAssetSource()
    let ledger: BackupLedger
    let editLedger = BackupEditLedger.inMemory()
    let server = FakeEditServer()
    let engine: BackupEngine

    init(ledger: BackupLedger = BackupLedger.inMemory(), albumSync: (any AlbumSyncServicing)? = nil) {
        self.ledger = ledger
        var userID: (@MainActor () -> String?)?
        if albumSync != nil { userID = { "me" } }
        engine = BackupEngine(
            client: mock, source: source, environment: MockBackupEnvironment(),
            ledger: ledger, editLedger: editLedger, albumSync: albumSync, userID: userID
        )
        source.dataProvider = { Data("orig-\($0)".utf8) }
        let server = self.server
        mock.bulkUploadCheckResponder = { server.respond($0) }
    }

    var settingsOn: BackupSettings {
        var settings = BackupSettings()
        settings.backUpEdits = true
        return settings
    }

    var settingsOff: BackupSettings { BackupSettings() }

    func photo(
        _ id: String, modified: String = EditRig.t0, adjusted: Bool = false,
        live: Bool = false, video: Bool = false
    ) -> BackupCandidate {
        BackupCandidate(
            id: id, kind: video ? .video : .image,
            fileName: video ? "\(id).mov" : "\(id).jpg",
            fileCreatedAt: Self.t0, fileModifiedAt: modified,
            duration: video ? 12 : nil, isFavorite: false,
            isLivePhoto: live, hasAdjustments: adjusted
        )
    }

    /// The ids the server hands back for the uploads of `id`.
    func answer(_ id: String, original: String? = nil, edit: String? = nil) {
        mock.uploadResponsesByFilename["\(id).jpg"] = AssetMediaResponseDto(id: original ?? "orig-\(id)", status: "created")
        mock.uploadResponsesByFilename["\(id).edited.jpg"] = AssetMediaResponseDto(id: edit ?? "edit-\(id)", status: "created")
    }

    func run(_ settings: BackupSettings, only: [String] = []) async {
        await engine.run(settings: settings, manual: true, only: only)
        learnUploads()
    }

    /// The server now holds every checksum uploaded so far.
    func learnUploads() {
        for (index, checksum) in mock.uploadChecksums.enumerated() {
            let name = mock.uploads[index].filename
            server.assetsByChecksum[checksum] = mock.uploadResponsesByFilename[name]?.id ?? "new-asset"
        }
    }

    func sha1(_ text: String) -> String {
        Data(Insecure.SHA1.hash(data: Data(text.utf8))).base64EncodedString()
    }

    /// An original already on the server (backed up at `t0`), then retouched in
    /// Photos: `c1` now carries adjustments at `modified`.
    func backedUpThenEdited(_ id: String = "c1", modified: String = EditRig.t1) async {
        answer(id)
        source.candidates = [photo(id)]
        await run(settingsOn)
        source.candidates = [photo(id, modified: modified, adjusted: true)]
        source.editedIDs = [id]
    }

    func uploadNames() -> [String] { mock.uploads.map(\.filename) }
}

final class BackupEditStackTests: XCTestCase {

    // MARK: - AC-41: the edit goes up and sits on top of its original

    @MainActor
    func test_AC_41_editIsSentAndStackedOnOriginal() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg"])
        XCTAssertNotEqual(rig.mock.uploadChecksums[0], rig.mock.uploadChecksums[1], "the edit is another file")
        XCTAssertEqual(rig.mock.createStackCalls, [["edit-c1", "orig-c1"]], "edit first, original below")
        XCTAssertEqual(rig.editLedger.record(id: "c1")?.isStacked, true)
        XCTAssertEqual(rig.engine.uploadedCount, 1)
        XCTAssertEqual(rig.engine.failedCount, 0)
        XCTAssertTrue(rig.engine.failures.isEmpty)
        XCTAssertTrue(rig.engine.backedUpIDs.contains("c1"))
    }

    @MainActor
    func test_AC_41_settingOffSendsNothingForAnEditedPhoto() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        let uploadsBefore = rig.mock.uploads.count

        await rig.run(rig.settingsOff)

        XCTAssertEqual(rig.mock.uploads.count, uploadsBefore, "no POST /api/assets")
        XCTAssertTrue(rig.mock.createStackCalls.isEmpty, "no POST /api/stacks")
        XCTAssertTrue(rig.source.exportedEditIDs.isEmpty)
        XCTAssertTrue(rig.editLedger.allRecords().isEmpty)
        XCTAssertEqual(
            rig.mock.bulkUploadCheckChunks.last?.map(\.id), ["c1"],
            "the check is the original's alone, as before the setting existed"
        )
        XCTAssertEqual(rig.engine.rejectedCount, 1)
    }

    // MARK: - AC-201: one pass per edit, nothing without a new edit

    @MainActor
    func test_AC_201_unchangedPassExportsHashesAndSendsNothing() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        await rig.run(rig.settingsOn)
        let exported = rig.source.exportedIDs.count
        let exportedEdits = rig.source.exportedEditIDs.count
        let checks = rig.mock.bulkUploadCheckChunks.count
        let uploads = rig.mock.uploads.count
        let stacks = rig.mock.createStackCalls.count

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.engine.total, 0)
        XCTAssertEqual(rig.source.exportedIDs.count, exported)
        XCTAssertEqual(rig.source.exportedEditIDs.count, exportedEdits)
        XCTAssertEqual(rig.mock.bulkUploadCheckChunks.count, checks)
        XCTAssertEqual(rig.mock.uploads.count, uploads)
        XCTAssertEqual(rig.mock.createStackCalls.count, stacks)
    }

    @MainActor
    func test_AC_201_editedAgainStacksOnThePreviousHead() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        await rig.run(rig.settingsOn)
        // Retouched again in Photos: another date, another rendering.
        rig.source.candidates = [rig.photo("c1", modified: EditRig.t2, adjusted: true)]
        rig.source.editDataProvider = { Data("edit2-\($0)".utf8) }
        rig.answer("c1", edit: "edit2-c1")

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg", "c1.edited.jpg"], "the new version once, the original never again")
        XCTAssertEqual(rig.mock.createStackCalls.last, ["edit2-c1", "edit-c1", "orig-c1"])
        XCTAssertEqual(rig.editLedger.record(id: "c1")?.serverAssetId, "edit2-c1")
        XCTAssertEqual(rig.editLedger.record(id: "c1")?.previousServerAssetId, "edit-c1")
        XCTAssertEqual(rig.engine.uploadedCount, 1)
    }

    @MainActor
    func test_AC_201_revertToOriginalSendsAndDeletesNothing() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        await rig.run(rig.settingsOn)
        let uploads = rig.mock.uploads.count
        let stacks = rig.mock.createStackCalls.count
        // "Revert to original" in Photos: the date moves, the adjustments go.
        rig.source.candidates = [rig.photo("c1", modified: EditRig.t3, adjusted: false)]

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.mock.uploads.count, uploads)
        XCTAssertEqual(rig.mock.createStackCalls.count, stacks)
        XCTAssertEqual(rig.engine.rejectedCount, 1, "the original is just seen again as a duplicate")
        XCTAssertNotNil(rig.editLedger.record(id: "c1"), "nothing is forgotten, nothing is removed from the server")
    }

    @MainActor
    func test_AC_201_adjustedWithoutRenderingIsClosedOnce() async {
        let rig = EditRig()
        rig.ledger.markBackedUp(id: "c1", signature: EditRig.t1, checksum: "sum-c1", serverAssetId: "orig-c1")
        rig.ledger.recordReconciliation(at: Date()) // keep the weekly check out of this scenario
        // Adjustments but no edited resource: `editedIDs` does not list it.
        rig.source.candidates = [rig.photo("c1", modified: EditRig.t1, adjusted: true)]

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.engine.total, 1)
        XCTAssertEqual(rig.engine.processedCount, rig.engine.total)
        XCTAssertEqual(rig.engine.rejectedCount, 1)
        XCTAssertTrue(rig.mock.uploads.isEmpty)
        XCTAssertTrue(rig.mock.createStackCalls.isEmpty)
        XCTAssertTrue(rig.mock.bulkUploadCheckChunks.isEmpty, "closed without any request")
        let record = rig.editLedger.record(id: "c1")
        XCTAssertEqual(record?.isStacked, true)
        XCTAssertEqual(record?.checksum, "sum-c1")
        XCTAssertEqual(record?.serverAssetId, "orig-c1")
        XCTAssertTrue(rig.engine.backedUpIDs.contains("c1"))
        let exportedEdits = rig.source.exportedEditIDs.count

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.source.exportedEditIDs.count, exportedEdits, "a second pass does not look again")
        XCTAssertEqual(rig.engine.total, 0)
    }

    // MARK: - AC-202: never backed up, or edited while the setting was off

    @MainActor
    func test_AC_202_neverBackedUpSendsBothAndStacks() async {
        let rig = EditRig()
        rig.answer("c1")
        rig.source.candidates = [rig.photo("c1", modified: EditRig.t1, adjusted: true)]
        rig.source.editedIDs = ["c1"]

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg"], "the original first")
        XCTAssertEqual(rig.mock.createStackCalls, [["edit-c1", "orig-c1"]])
        XCTAssertEqual(rig.engine.uploadedCount, 1, "one element, one outcome")
        XCTAssertEqual(rig.engine.processedCount, rig.engine.total)
        XCTAssertEqual(
            rig.engine.uploadedBytes,
            Int64(Data("orig-c1".utf8).count + Data("edit-c1".utf8).count),
            "both files count"
        )
        XCTAssertEqual(rig.ledger.trackedEntry(id: "c1")?.serverAssetId, "orig-c1")
    }

    @MainActor
    func test_AC_202_catchUpSendsOnlyTheEdit() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        // The edit happened while the setting was off: the original is
        // re-registered at the new date, the edit stays unsent.
        await rig.run(rig.settingsOff)
        let exported = rig.source.exportedIDs.count
        rig.mock.bulkUploadCheckChunks.removeAll()

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.source.exportedIDs.count, exported, "the original is not exported again")
        XCTAssertEqual(rig.source.exportedEditIDs, ["c1"])
        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg"])
        XCTAssertEqual(rig.mock.bulkUploadCheckChunks.flatMap { $0.map(\.id) }, ["c1#edit"])
        XCTAssertEqual(rig.mock.createStackCalls, [["edit-c1", "orig-c1"]])
        XCTAssertEqual(rig.engine.uploadedCount, 1)
    }

    @MainActor
    func test_AC_202_editFailureIsAWarningAndTheOriginalGoesOn() async {
        let rig = EditRig()
        rig.answer("c1")
        rig.source.candidates = [rig.photo("c1", modified: EditRig.t1, adjusted: true)]
        rig.source.editedIDs = ["c1"]
        rig.source.editFailIDs = ["c1"]

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.uploadNames(), ["c1.jpg"], "the original is sent alone")
        XCTAssertEqual(rig.engine.uploadedCount, 1)
        XCTAssertEqual(rig.engine.failedCount, 0, "a warning, not a failed element")
        XCTAssertEqual(rig.engine.failures.map(\.reason), [BackupEngine.editFailedReason])
        XCTAssertNil(rig.editLedger.record(id: "c1"))

        // Next pass: the original is done, only the edit remains.
        rig.source.editFailIDs = []
        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg"])
        XCTAssertEqual(rig.mock.createStackCalls, [["edit-c1", "orig-c1"]])
        XCTAssertTrue(rig.engine.failures.isEmpty)
    }

    // MARK: - AC-203: videos and Live Photos

    @MainActor
    func test_AC_203_videoAndLivePhotoEditsAreStacked() async {
        let rig = EditRig()
        rig.mock.uploadResponsesByFilename = [
            "v1.mov": AssetMediaResponseDto(id: "orig-v1", status: "created"),
            "v1.edited.jpg": AssetMediaResponseDto(id: "edit-v1", status: "created"),
            "l1.jpg": AssetMediaResponseDto(id: "orig-l1", status: "created"),
            "l1.MOV": AssetMediaResponseDto(id: "vid-l1", status: "created"),
            "l1.edited.jpg": AssetMediaResponseDto(id: "edit-l1", status: "created"),
            "l1.edited.MOV": AssetMediaResponseDto(id: "evid-l1", status: "created"),
        ]
        rig.source.candidates = [
            rig.photo("v1", modified: EditRig.t1, adjusted: true, video: true),
            rig.photo("l1", modified: EditRig.t1, adjusted: true, live: true),
        ]
        rig.source.editedIDs = ["v1", "l1"]
        rig.source.livePhotoIDs = ["l1"]
        rig.source.editPairedIDs = ["l1"]

        await rig.run(rig.settingsOn)

        let live = rig.mock.uploads.filter { $0.deviceAssetId == "l1" }
        XCTAssertEqual(live.map(\.filename), ["l1.MOV", "l1.jpg", "l1.edited.MOV", "l1.edited.jpg"])
        XCTAssertEqual(live.map(\.visibility), [.hidden, .timeline, .hidden, .timeline])
        XCTAssertEqual(live[1].livePhotoVideoId, "vid-l1")
        XCTAssertEqual(live[3].livePhotoVideoId, "evid-l1", "the edited still carries the edited video")
        XCTAssertEqual(rig.mock.createStackCalls, [["edit-v1", "orig-v1"], ["edit-l1", "orig-l1"]])
        XCTAssertEqual(rig.engine.uploadedCount, 2)
    }

    // MARK: - AC-204: a stack that fails is reported, then redone without resending

    @MainActor
    func test_AC_204_stackFailureWarnsThenRetriesWithoutResend() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        rig.mock.createStackError = APIError.serverError(500, "boom")

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.engine.failures.map(\.reason), [BackupEngine.editStackFailedReason])
        XCTAssertEqual(rig.engine.failures.first?.assetID, "c1")
        XCTAssertEqual(rig.engine.failedCount, 0)
        XCTAssertEqual(rig.editLedger.record(id: "c1")?.isStacked, false)
        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg"])

        rig.mock.createStackError = nil
        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg"], "the edit is not sent a second time")
        XCTAssertEqual(rig.mock.createStackCalls, [["edit-c1", "orig-c1"], ["edit-c1", "orig-c1"]])
        XCTAssertEqual(rig.editLedger.record(id: "c1")?.isStacked, true)
        XCTAssertTrue(rig.engine.failures.isEmpty)
    }

    @MainActor
    func test_AC_204_legacyLedgerEntryReexportsTheOriginalOnce() async throws {
        // A v1 ledger file: the signature only, no checksum, no server id.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data("{\"c1\":\"\(EditRig.t1)\"}".utf8).write(to: url)
        let rig = EditRig(ledger: BackupLedger(fileURL: url))
        rig.answer("c1")
        rig.source.candidates = [rig.photo("c1", modified: EditRig.t1, adjusted: true)]
        rig.source.editedIDs = ["c1"]
        // The server already holds the original under this id.
        rig.server.assetsByChecksum[rig.sha1("orig-c1")] = "orig-c1"

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.source.exportedIDs, ["c1"], "the original is exported once, to learn its id")
        XCTAssertEqual(rig.uploadNames(), ["c1.edited.jpg"])
        XCTAssertEqual(rig.mock.createStackCalls, [["edit-c1", "orig-c1"]])
        XCTAssertEqual(rig.ledger.trackedEntry(id: "c1")?.serverAssetId, "orig-c1")

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.source.exportedIDs, ["c1"], "and never again")
        XCTAssertEqual(rig.source.exportedEditIDs, ["c1"])
    }

    @MainActor
    func test_AC_204_stalePreviousHeadIsDroppedOnA400() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        await rig.run(rig.settingsOn)
        // Edited again, while the server no longer knows the first edit.
        rig.source.candidates = [rig.photo("c1", modified: EditRig.t2, adjusted: true)]
        rig.source.editDataProvider = { Data("edit2-\($0)".utf8) }
        rig.answer("c1", edit: "edit2-c1")
        rig.mock.createStackRejectedIDs = ["edit-c1"]

        await rig.run(rig.settingsOn)

        XCTAssertEqual(
            Array(rig.mock.createStackCalls.suffix(2)),
            [["edit2-c1", "edit-c1", "orig-c1"], ["edit2-c1", "orig-c1"]]
        )
        let record = rig.editLedger.record(id: "c1")
        XCTAssertEqual(record?.isStacked, true)
        XCTAssertNil(record?.previousServerAssetId)
        XCTAssertTrue(rig.engine.failures.isEmpty)
    }

    // MARK: - AC-205: the retry paths of the detail screen

    @MainActor
    func test_AC_205_retryOfAStackWarningRestacksWithoutResend() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        rig.mock.createStackError = APIError.serverError(500, "boom")
        await rig.run(rig.settingsOn)
        rig.mock.createStackError = nil

        await rig.run(rig.settingsOn, only: ["c1"])

        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg"])
        XCTAssertEqual(rig.mock.createStackCalls.count, 2)
        XCTAssertEqual(rig.editLedger.record(id: "c1")?.isStacked, true)
    }

    @MainActor
    func test_AC_205_retryOfAnEditFailureSendsAndStacks() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        rig.source.editFailIDs = ["c1"]
        await rig.run(rig.settingsOn)
        XCTAssertEqual(rig.engine.failures.map(\.reason), [BackupEngine.editFailedReason])
        rig.source.editFailIDs = []

        await rig.run(rig.settingsOn, only: ["c1"])

        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg"])
        XCTAssertEqual(rig.mock.createStackCalls, [["edit-c1", "orig-c1"]])
    }

    // MARK: - AC-206: the rules an original follows

    @MainActor
    func test_AC_206_editJoinsMirroredAlbum() async {
        let suite = "edit-stack-albums-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let service = AlbumSyncService(mapping: AlbumSyncStore(suiteName: suite), batchSize: 100)
        let rig = EditRig(albumSync: service)
        rig.answer("c1")
        rig.source.candidates = [rig.photo("c1", modified: EditRig.t1, adjusted: true)]
        rig.source.editedIDs = ["c1"]
        rig.source.albums = [BackupAlbum(id: "dev-vac", name: "Vacances", count: 1)]
        rig.source.albumMembershipByDeviceAlbum = ["c1": ["dev-vac"]]
        var settings = rig.settingsOn
        settings.syncedAlbumIDs = ["dev-vac"]

        await rig.run(settings)

        XCTAssertEqual(Set(rig.mock.addAssetsToAlbumCalls.flatMap { $0.ids }), ["orig-c1", "edit-c1"])
    }

    @MainActor
    func test_AC_206_readOnlySendsNoEdit() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        let suite = "edit-stack-readonly-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = ReadOnlyModeStore(defaults: UserDefaults(suiteName: suite)!)
        store.setEnabled(true)
        let settings = BackupSettingsStore(suiteName: suite)
        settings.backUpEdits = true
        let vm = UploadViewModel(
            client: rig.mock, photos: MockPhotoLibraryService(), engine: rig.engine,
            settings: settings, scheduler: MockBackupScheduler(),
            activityService: MockBackupLiveActivityService(), readOnly: store
        )
        let uploads = rig.mock.uploads.count
        let requests = rig.mock.requestCount

        await vm.runBackup(manual: true)

        XCTAssertEqual(rig.mock.uploads.count, uploads)
        XCTAssertEqual(rig.mock.requestCount, requests, "the whole run is refused")
        XCTAssertTrue(rig.mock.createStackCalls.isEmpty)
    }

    @MainActor
    func test_AC_206_iCloudPendingEditIsDeferred() async {
        let rig = EditRig()
        rig.answer("c1")
        rig.source.candidates = [rig.photo("c1", modified: EditRig.t1, adjusted: true)]
        rig.source.editedIDs = ["c1"]
        rig.source.editDeferIDs = ["c1"]

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.engine.deferredCount, 1)
        XCTAssertEqual(rig.engine.deferrals.first?.reason, .waitingForICloud)
        XCTAssertEqual(rig.engine.failedCount, 0)
        XCTAssertTrue(rig.engine.failures.isEmpty)
        XCTAssertTrue(rig.mock.uploads.isEmpty)
        XCTAssertTrue(rig.mock.createStackCalls.isEmpty)
        XCTAssertTrue(rig.source.exportedIDs.isEmpty, "the original is not downloaded for nothing")

        rig.source.editDeferIDs = []
        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg"])
        XCTAssertEqual(rig.mock.createStackCalls, [["edit-c1", "orig-c1"]])
    }

    @MainActor
    func test_AC_206_aFailedCheckLeavesNoEditFile() async {
        let rig = EditRig()
        let id = "leak-\(UUID().uuidString)"
        rig.source.candidates = [rig.photo(id, modified: EditRig.t1, adjusted: true)]
        rig.source.editedIDs = [id]
        rig.mock.bulkUploadCheckResponder = nil
        rig.mock.globalError = APIError.serverError(500, "down")

        await rig.run(rig.settingsOn)

        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: MockBackupAssetSource.testBackupDirectory.path
        )) ?? []
        XCTAssertEqual(rig.engine.failedCount, 1)
        XCTAssertTrue(names.filter { $0.contains(id) }.isEmpty, "originals and edited renderings are both removed")
    }

    // MARK: - AC-208: reconciliation and reset

    @MainActor
    func test_AC_208_purgedEditIsResentAndRestacked() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        await rig.run(rig.settingsOn)
        // The server loses the edit (purged) but keeps the original.
        let editChecksum = rig.editLedger.record(id: "c1")?.checksum ?? ""
        rig.server.assetsByChecksum[editChecksum] = nil
        rig.answer("c1", edit: "edit-c1-again")

        await rig.engine.reconcileNow(includeEdits: true)

        XCTAssertNil(rig.editLedger.record(id: "c1"), "only the edit is forgotten")
        XCTAssertEqual(rig.ledger.trackedCount(), 1, "the original stays")
        let exported = rig.source.exportedIDs.count

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.source.exportedIDs.count, exported, "the original is not exported again")
        XCTAssertEqual(rig.uploadNames(), ["c1.jpg", "c1.edited.jpg", "c1.edited.jpg"])
        XCTAssertEqual(rig.mock.createStackCalls.last, ["edit-c1-again", "orig-c1"])
        let uploads = rig.mock.uploads.count

        await rig.run(rig.settingsOn)

        XCTAssertEqual(rig.mock.uploads.count, uploads, "and nothing more afterwards")
    }

    @MainActor
    func test_AC_208_trashedEditIsKept() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        await rig.run(rig.settingsOn)
        let editChecksum = rig.editLedger.record(id: "c1")?.checksum ?? ""
        rig.server.trashedChecksums = [editChecksum]
        let uploads = rig.mock.uploads.count

        await rig.engine.reconcileNow(includeEdits: true)
        await rig.run(rig.settingsOn)

        XCTAssertNotNil(rig.editLedger.record(id: "c1"))
        XCTAssertEqual(rig.mock.uploads.count, uploads)
    }

    @MainActor
    func test_AC_208_resetTrackingForgetsTheEditsToo() async {
        let rig = EditRig()
        await rig.backedUpThenEdited()
        await rig.run(rig.settingsOn)

        rig.engine.forgetAllBackedUp()

        XCTAssertTrue(rig.editLedger.allRecords().isEmpty)
        XCTAssertEqual(rig.ledger.trackedCount(), 0)
    }
}
