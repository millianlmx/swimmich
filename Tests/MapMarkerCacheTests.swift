import XCTest
@testable import ImmichSwiftUI

final class MapMarkerCacheTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapMarkerCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func marker(_ id: String) -> MapMarkerResponseDto {
        MapMarkerResponseDto(id: id, lat: 48.85, lon: 2.35, city: nil, state: nil, country: nil)
    }

    func test_ACC_AC10_otherAccountReadsEmptyCache() {
        for variant in [nil, "fav"] as [String?] {
            let a = MapMarkerCache(accountID: "https://s|alice", directory: dir, variant: variant)
            let b = MapMarkerCache(accountID: "https://s|bob", directory: dir, variant: variant)
            a.save([marker("a1")])

            XCTAssertNotNil(a.age(), "A's own cache is readable (variant \(variant ?? "nil"))")
            XCTAssertNil(b.load(), "variant \(variant ?? "nil")")
            XCTAssertNil(b.age(), "variant \(variant ?? "nil")")
        }
    }

    func test_ACC_AC11_eachAccountReadsOwnMarkers() {
        let a = MapMarkerCache(accountID: "https://s|alice", directory: dir)
        let b = MapMarkerCache(accountID: "https://s|bob", directory: dir)
        a.save([marker("a1"), marker("a2")])
        b.save([marker("b1")])

        XCTAssertEqual(a.load()?.map(\.id), ["a1", "a2"])
        XCTAssertEqual(b.load()?.map(\.id), ["b1"])
        // A variant keeps the account.
        a.variant("fav").save([marker("a-fav")])
        XCTAssertEqual(a.variant("fav").load()?.map(\.id), ["a-fav"])
        XCTAssertNil(b.variant("fav").load())
    }

    func test_ACC_AC13_removeAll_deletesEveryAccountVariantAndLegacyFile() throws {
        MapMarkerCache(accountID: "alice", directory: dir).save([marker("a1")])
        MapMarkerCache(accountID: "alice", directory: dir, variant: "fav").save([marker("a2")])
        MapMarkerCache(accountID: "bob", directory: dir).save([marker("b1")])
        let folder = dir.appendingPathComponent("MapMarkers", isDirectory: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("markers.json"))

        MapMarkerCache.removeAll(directory: dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(MapMarkerCache(accountID: "alice", directory: dir).load())
        // Absent folder: no-op.
        MapMarkerCache.removeAll(directory: dir)
    }

    func test_ACC_AC10_AC11_storageKey_isStableLowercaseHexSHA256() {
        let key = SavedAccount.storageKey(forID: "https://s|alice")
        XCTAssertEqual(key, SavedAccount.storageKey(forID: "https://s|alice"))
        XCTAssertNotEqual(key, SavedAccount.storageKey(forID: "https://s|bob"))
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(
            SavedAccount.storageKey(forID: ""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }
}
