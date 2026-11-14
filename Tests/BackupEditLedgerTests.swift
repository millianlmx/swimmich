import Foundation
import XCTest
@testable import ImmichSwiftUI

/// The memory of edited versions already sent (`immich-backup-edits.json`):
/// it must survive a relaunch, or every edited photo would be exported — and
/// downloaded from iCloud — again at each pass.
final class BackupEditLedgerTests: XCTestCase {

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edits-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func record(stacked: Bool = false) -> BackupEditRecord {
        BackupEditRecord(
            signature: "2024-07-02T00:00:00.000Z", checksum: "sum", serverAssetId: "edit-1",
            originalServerAssetId: "orig-1", previousServerAssetId: "prev-1",
            isStacked: stacked, fileName: "IMG_0001.jpg"
        )
    }

    func test_AC_201_recordsSurviveReopen() {
        let url = tempURL()
        let first = BackupEditLedger(fileURL: url)
        first.upsert(id: "a", record())
        XCTAssertEqual(first.pendingStackIDs(), ["a"])
        first.markStacked(id: "a")
        first.save()
        BackupEditLedger.drainIO()

        let second = BackupEditLedger(fileURL: url)

        XCTAssertEqual(second.record(id: "a"), record(stacked: true))
        XCTAssertTrue(second.pendingStackIDs().isEmpty)
        XCTAssertEqual(second.allRecords().count, 1)
    }

    func test_AC_201_unreadableFileIsAnEmptyMemory() throws {
        let url = tempURL()
        try Data("not json".utf8).write(to: url)

        let ledger = BackupEditLedger(fileURL: url)

        XCTAssertTrue(ledger.allRecords().isEmpty)
        XCTAssertNil(ledger.record(id: "a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a bad file is left alone until the next change")
    }

    func test_AC_201_removeAllEmptiesMemoryAndDeletesFile() {
        let url = tempURL()
        let ledger = BackupEditLedger(fileURL: url)
        ledger.upsert(id: "a", record())
        ledger.save()
        BackupEditLedger.drainIO()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        ledger.removeAll()
        BackupEditLedger.drainIO()

        XCTAssertTrue(ledger.allRecords().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_forgetAndReconciliationEntries() {
        let ledger = BackupEditLedger.inMemory()
        ledger.upsert(id: "a", record())
        ledger.upsert(id: "b", record(stacked: true))

        XCTAssertEqual(Set(ledger.entriesForReconciliation().map(\.id)), ["a", "b"])
        ledger.forget(ids: ["a"])

        XCTAssertNil(ledger.record(id: "a"))
        XCTAssertNotNil(ledger.record(id: "b"))
        XCTAssertEqual(ledger.pendingStackIDs(), [])
    }
}
