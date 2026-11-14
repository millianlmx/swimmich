import XCTest
@testable import ImmichSwiftUI

@MainActor
final class BackupSettingsStoreEditsTests: XCTestCase {

    func test_AC_200_defaultsOffPersistsAndReachesSnapshot() {
        let suite = "backup-edits-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let fresh = BackupSettingsStore(suiteName: suite)
        XCTAssertFalse(fresh.backUpEdits, "off on a new install")
        XCTAssertFalse(fresh.snapshot().backUpEdits)

        fresh.backUpEdits = true

        XCTAssertTrue(fresh.snapshot().backUpEdits, "the engine runs against the setting")
        // A relaunch reads it back.
        XCTAssertTrue(BackupSettingsStore(suiteName: suite).backUpEdits)

        fresh.backUpEdits = false
        XCTAssertFalse(BackupSettingsStore(suiteName: suite).backUpEdits)
    }
}
