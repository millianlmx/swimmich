import XCTest
@testable import ImmichSwiftUI

/// The transport buffer's contract (gap G24): bounded, ordered, emptyable — and
/// safe under the concurrency it actually sees, since every request that
/// finishes records from its own task.
final class AppLogStoreTests: XCTestCase {

    private static func entry(_ index: Int) -> AppLogEntry {
        AppLogEntry(
            level: .info,
            method: "GET",
            path: "/api/assets/\(index)",
            status: 200,
            durationMS: index,
            category: "HTTP",
            message: "GET /api/assets/\(index)"
        )
    }

    /// The list shows the most recent line first: the failure the operator is
    /// looking for is the one that just happened.
    func test_record_keepsNewestFirst() {
        let store = AppLogStore()
        for index in 0..<3 { store.record(Self.entry(index)) }

        XCTAssertEqual(store.snapshot().map(\.path), ["/api/assets/2", "/api/assets/1", "/api/assets/0"])
        XCTAssertEqual(store.count(), 3)
    }

    /// 510 lines into a 500-line buffer: the surplus leaves from the bottom, so
    /// the newest line is still there and the oldest is gone.
    func test_capacity_dropsOldestEntries() {
        let store = AppLogStore(capacity: 500)
        for index in 0..<510 { store.record(Self.entry(index)) }

        XCTAssertEqual(store.count(), 500)
        let paths = Set(store.snapshot().map(\.path))
        XCTAssertFalse(paths.contains("/api/assets/0"), "the oldest line should have been dropped")
        XCTAssertTrue(paths.contains("/api/assets/509"), "the newest line must survive")
    }

    func test_clear_emptiesTheBuffer() {
        let store = AppLogStore()
        store.record(Self.entry(0))
        store.record(Self.entry(1))

        store.clear()

        XCTAssertEqual(store.count(), 0)
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    /// The one property an unsynchronised buffer breaks: 100 concurrent appends
    /// must leave 100 lines, not 97 — two dispatches finishing at the same
    /// instant must not overwrite each other's index.
    func test_concurrentRecords_doNotLoseEntries() {
        let store = AppLogStore()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            store.record(Self.entry(index))
        }

        XCTAssertEqual(store.count(), 100)
    }

    // MARK: - Minimum level (B-31)

    private static func entry(_ level: AppLogLevel, path: String) -> AppLogEntry {
        AppLogEntry(level: level, method: "GET", path: path, status: 200, durationMS: 1, category: "HTTP", message: path)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "AppLogStoreTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Raising the level only filters what comes next: the lines already kept
    /// stay on screen.
    func test_AC_273_raisingTheLevelKeepsLinesAlreadyRecorded() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppLogStore(defaults: defaults)
        store.record(Self.entry(.info, path: "/before"))

        store.setMinimumLevel(.severe)
        store.record(Self.entry(.info, path: "/after-info"))
        store.record(Self.entry(.warning, path: "/after-warning"))
        store.record(Self.entry(.severe, path: "/after-severe"))

        XCTAssertEqual(store.snapshot().map(\.path), ["/after-severe", "/before"])
    }

    func test_AC_273_levelSurvivesANewStore() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        AppLogStore(defaults: defaults).setMinimumLevel(.severe)

        XCTAssertEqual(AppLogStore(defaults: defaults).currentMinimumLevel(), .severe)
    }

    func test_AC_273_unreadableLevelFallsBackToAll() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppLogStore(defaults: defaults).currentMinimumLevel(), .info, "nothing stored")

        defaults.set("verbose", forKey: AppLogStore.minimumLevelKey)
        XCTAssertEqual(AppLogStore(defaults: defaults).currentMinimumLevel(), .info)
    }

    func test_AC_273_levelsAreOrdered() {
        XCTAssertLessThan(AppLogLevel.info, .warning)
        XCTAssertLessThan(AppLogLevel.warning, .severe)
        XCTAssertFalse(AppLogLevel.severe < .info)
    }
}
