import Foundation
import XCTest
@testable import ImmichSwiftUI

/// The thumbnail badge (G6) answers one question per tile — "is this on the
/// server?" — from the backup ledger, through two namespaces: the ledger is
/// keyed by Photos `localIdentifier`, the timeline by server UUID. These cover
/// the bridge (`serverAssetId`, ledger v3) and the index that reads it,
/// including the answer the feature must never give: a badge on an asset the
/// ledger knows nothing about.
final class CloudBackupStatusIndexTests: XCTestCase {

    /// One uploaded asset, with the server UUID both halves of the bridge need.
    private func ledgerWithOneUploadedAsset() -> BackupLedger {
        let ledger = BackupLedger.inMemory()
        ledger.markBackedUp(id: "lib-1", signature: "sig-1", checksum: "sum-1", serverAssetId: "srv-1")
        return ledger
    }

    @MainActor
    private func enabledIndex(ledger: BackupLedger) -> CloudBackupStatusIndex {
        let index = CloudBackupStatusIndex()
        index.setEnabled(true)
        index.refresh(ledger: ledger, editLedger: BackupEditLedger.inMemory())
        return index
    }

    private func writeLedgerFile(_ json: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    // MARK: - The five answers

    @MainActor
    func test_statusForServerAssetID_isUploadedAfterRefresh() {
        let index = enabledIndex(ledger: ledgerWithOneUploadedAsset())

        XCTAssertEqual(index.status(forServerAssetID: "srv-1"), .uploaded)
    }

    @MainActor
    func test_statusForLocalAssetID_isUploadedAfterRefresh() {
        let index = enabledIndex(ledger: ledgerWithOneUploadedAsset())

        XCTAssertEqual(index.status(forLocalAssetID: "lib-1"), .uploaded)
    }

    /// A library id the ledger never saw: this device holds the only copy, and
    /// the badge says so.
    @MainActor
    func test_statusForLocalAssetID_unknownIsLocalOnly() {
        let index = enabledIndex(ledger: ledgerWithOneUploadedAsset())

        XCTAssertEqual(index.status(forLocalAssetID: "jamais-vu"), .localOnly)
    }

    /// The timeline renders server UUIDs, and the ledger only knows the assets
    /// this device handled — the ones another device uploaded, or that were
    /// there before this install, are unknown. Unknown is not `.localOnly`: a
    /// "not on the server" badge on someone else's photo would be false.
    @MainActor
    func test_statusForServerAssetID_unknownUUIDIsNil() {
        let index = enabledIndex(ledger: ledgerWithOneUploadedAsset())

        XCTAssertNil(index.status(forServerAssetID: "uuid-inconnu"))
    }

    /// An edit sent and stacked is the head of its stack, the one tile the
    /// timeline shows: it carries the badge. An edit waiting for its stack is on
    /// the server too. The local side stays the original's.
    @MainActor
    func test_AC_41_statusForServerAssetID_countsTheEditsOfTheEditLedger() {
        let editLedger = BackupEditLedger.inMemory()
        editLedger.upsert(id: "lib-1", BackupEditRecord(
            signature: "s", checksum: "c", serverAssetId: "edit-stacked", originalServerAssetId: "srv-1",
            previousServerAssetId: nil, isStacked: true, fileName: "a.jpg"
        ))
        editLedger.upsert(id: "lib-2", BackupEditRecord(
            signature: "s", checksum: "c2", serverAssetId: "edit-pending", originalServerAssetId: nil,
            previousServerAssetId: nil, isStacked: false, fileName: "b.jpg"
        ))
        let index = CloudBackupStatusIndex()
        index.setEnabled(true)

        index.refresh(ledger: ledgerWithOneUploadedAsset(), editLedger: editLedger)

        XCTAssertEqual(index.status(forServerAssetID: "edit-stacked"), .uploaded)
        XCTAssertEqual(index.status(forServerAssetID: "edit-pending"), .uploaded)
        XCTAssertEqual(index.status(forServerAssetID: "srv-1"), .uploaded)
        XCTAssertEqual(index.status(forLocalAssetID: "lib-2"), .localOnly, "the local side is the original ledger's")
    }

    /// With the setting off no tile carries a badge, whatever the ledger holds.
    @MainActor
    func test_isEnabledFalse_suppressesEveryStatus() {
        let index = CloudBackupStatusIndex()
        index.refresh(ledger: ledgerWithOneUploadedAsset(), editLedger: BackupEditLedger.inMemory())
        XCTAssertFalse(index.isEnabled, "le réglage par défaut est éteint")

        XCTAssertNil(index.status(forServerAssetID: "srv-1"))
        XCTAssertNil(index.status(forLocalAssetID: "lib-1"))
        XCTAssertNil(index.status(forLocalAssetID: "jamais-vu"))

        // Off is a gate, not a reason to drop what was loaded: turning the
        // setting back on must not need a second ledger read.
        XCTAssertEqual(index.uploadedServerIDs, ["srv-1"])
        XCTAssertEqual(index.uploadedLocalIDs, ["lib-1"])
    }

    // MARK: - Ledger v3

    /// The UUID has to survive a relaunch: without it the badge would go dark
    /// on every tile the app had already proven, after every restart.
    func test_ledgerV3RoundTripsServerAssetID() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = BackupLedger(fileURL: url)
        first.markBackedUp(id: "lib-1", signature: "sig-1", checksum: "sum-1", serverAssetId: "srv-1")
        first.save()

        // `save()` is coalesced onto a background queue; wait for the file.
        let flushed = expectation(description: "ledger flushed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)

        let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(snapshot?["version"] as? Int, 3)

        let second = BackupLedger(fileURL: url)
        XCTAssertEqual(second.uploadedServerAssetIDs(), ["srv-1"])
        XCTAssertEqual(second.uploadedLocalAssetIDs(), ["lib-1"])
        XCTAssertTrue(second.hasUploaded(id: "lib-1"))
    }

    /// A v2 file (no `serverAssetId` anywhere) must still load as-is: dropping
    /// it would re-download and re-hash a whole library. Its entries have no
    /// server UUID, so they light no badge — no information, no badge.
    func test_ledgerV2FileLoadsWithoutServerAssetID() throws {
        let url = try writeLedgerFile(
            #"{"version":2,"entries":{"lib-1":{"signature":"sig-1","checksum":"sum-1"}}}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = BackupLedger(fileURL: url)

        XCTAssertEqual(ledger.trackedCount(), 1)
        XCTAssertTrue(ledger.uploadedServerAssetIDs().isEmpty)
        XCTAssertEqual(ledger.uploadedLocalAssetIDs(), ["lib-1"],
                       "l'entrée reste sauvegardée : seule la clé serveur manque")
    }

    /// A v1 entry has no checksum at all — `entriesForReconciliation()` skips
    /// it, but it *is* backed up, so the local-id set (the badge's other half)
    /// must keep it.
    func test_ledgerV1EntryIsStillInTheUploadedLocalSet() throws {
        let url = try writeLedgerFile(#"{"lib-1":"sig-1"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = BackupLedger(fileURL: url)

        XCTAssertTrue(ledger.entriesForReconciliation().isEmpty)
        XCTAssertEqual(ledger.uploadedLocalAssetIDs(), ["lib-1"])
        XCTAssertTrue(ledger.hasUploaded(id: "lib-1"))
        XCTAssertTrue(ledger.uploadedServerAssetIDs().isEmpty,
                      "une entrée v1 n'a pas d'UUID serveur : aucun badge de sauvegarde")
    }

    /// Re-marking the same asset with the UUID the server just answered is a
    /// real write: the run that learns the id must not be a no-op.
    func test_markBackedUp_keepsServerAssetIDOnReMark() {
        let ledger = BackupLedger.inMemory()
        ledger.markBackedUp(id: "lib-1", signature: "sig-1", checksum: "sum-1")
        XCTAssertTrue(ledger.uploadedServerAssetIDs().isEmpty)

        ledger.markBackedUp(id: "lib-1", signature: "sig-1", checksum: "sum-1", serverAssetId: "srv-1")
        XCTAssertEqual(ledger.uploadedServerAssetIDs(), ["srv-1"])

        // A later write that carries none — a `reject` the server answered
        // without `assetId` — must not dark the badge on an asset already
        // proven.
        ledger.markBackedUp(id: "lib-1", signature: "sig-1", checksum: "sum-1")
        XCTAssertEqual(ledger.uploadedServerAssetIDs(), ["srv-1"])
    }
}

/// The engine half of the bridge: the ledger only becomes useful to the badge
/// if the UUIDs the server hands out during a run land in it, and the UI is
/// only told to redraw if the write is announced.
final class CloudBackupStatusRecordingTests: XCTestCase {

    private func candidate(_ id: String) -> BackupCandidate {
        BackupCandidate(
            id: id, kind: .image, fileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            duration: nil, isFavorite: false
        )
    }

    /// Both paths that hold a server UUID — the `reject` of `bulk-upload-check`
    /// (the server already has this checksum and says under which id) and the
    /// upload response — must record it.
    @MainActor
    func test_engine_recordsServerAssetIDFromBothLedgerPaths() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1"), candidate("c2")]
        source.dataProvider = { _ in Data(repeating: 7, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "c1", action: "reject", reason: "duplicate", assetId: "srv-1"),
            .init(id: "c2", action: "accept"),
        ])
        mock.uploadResponsesByFilename = ["c2.jpg": AssetMediaResponseDto(id: "srv-2", status: "created")]
        let ledger = BackupLedger.inMemory()
        let engine = BackupEngine(
            client: mock, source: source,
            environment: MockBackupEnvironment(), ledger: ledger
        )

        await engine.run(settings: BackupSettings(isEnabled: true))

        XCTAssertEqual(ledger.uploadedServerAssetIDs(), ["srv-1", "srv-2"])
        XCTAssertEqual(ledger.uploadedLocalAssetIDs(), ["c1", "c2"])
    }

    /// The wiring the app runs on: the engine announces a ledger write, and
    /// what the index then answers is what the tiles draw.
    @MainActor
    func test_engine_ledgerChangeHookPublishesTheNewStateToTheIndex() async {
        let mock = MockImmichClient()
        let source = MockBackupAssetSource()
        source.candidates = [candidate("c1")]
        source.dataProvider = { _ in Data(repeating: 7, count: 16) }
        mock.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "c1", action: "accept"),
        ])
        mock.uploadResponsesByFilename = ["c1.jpg": AssetMediaResponseDto(id: "srv-1", status: "created")]
        let ledger = BackupLedger.inMemory()
        let engine = BackupEngine(
            client: mock, source: source,
            environment: MockBackupEnvironment(), ledger: ledger
        )
        let index = CloudBackupStatusIndex()
        index.setEnabled(true)
        engine.onLedgerChange = { index.refresh(ledger: ledger, editLedger: BackupEditLedger.inMemory()) }

        await engine.run(settings: BackupSettings(isEnabled: true))

        XCTAssertEqual(index.status(forServerAssetID: "srv-1"), .uploaded,
                       "le run a poussé l'UUID serveur jusqu'à l'index")
    }
}
