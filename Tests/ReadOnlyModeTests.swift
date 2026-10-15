import XCTest
@testable import ImmichSwiftUI

/// Read-only mode (gap G17): the device boolean, and the single client
/// decorator that refuses every library write while it is on.
///
/// Every refusal is asserted on **two** facts: the error (`APIError.readOnlyMode`)
/// *and* the untouched request count of the mock. The error alone would also
/// pass if the call had reached the server and the server had said no — the
/// point of the guard is that nothing gets there.
@MainActor
final class ReadOnlyModeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "read-only-mode-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A `Sendable` box so a test can flip the mode while the guard is already
    /// holding it: the real guard reads the setting at call time, and a test
    /// that only ever built a fresh guard could not tell that apart from a
    /// captured value.
    private final class Flag: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private func guarded() -> (client: ReadOnlyGuardClient, inner: MockImmichClient, flag: Flag) {
        let inner = MockImmichClient()
        let flag = Flag(false)
        let client = ReadOnlyGuardClient(inner: inner, isEnabled: { flag.value })
        return (client, inner, flag)
    }

    /// Asserts the guard refused `operation`: the call threw `.readOnlyMode`
    /// and nothing else.
    private func assertRefused(
        _ operation: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("\(operation) went through while read-only mode is on", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error, .readOnlyMode, operation, file: file, line: line)
        } catch {
            XCTFail("\(operation) threw \(error), not APIError.readOnlyMode", file: file, line: line)
        }
    }

    private func uploadGuard(_ client: ReadOnlyGuardClient) async throws {
        _ = try await client.uploadAsset(
            fileURL: URL(fileURLWithPath: "/tmp/read-only-mode.jpg"),
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            filename: "read-only-mode.jpg",
            duration: nil,
            isFavorite: false,
            visibility: .timeline,
            livePhotoVideoId: nil,
            checksum: "checksum",
            deviceAssetId: "device-asset",
            deviceId: "device"
        )
    }

    // MARK: - The store

    func test_defaultsToDisabled() {
        let store = ReadOnlyModeStore(defaults: defaults)
        XCTAssertFalse(store.isEnabled)
    }

    func test_setEnabled_persistsAcrossInstances() {
        let store = ReadOnlyModeStore(defaults: defaults)
        store.setEnabled(true)

        XCTAssertTrue(store.isEnabled)
        // A second store on the same defaults — what the next launch builds —
        // reads the setting back, and the guard's non-isolated read agrees.
        XCTAssertTrue(ReadOnlyModeStore(defaults: defaults).isEnabled)
        XCTAssertTrue(ReadOnlyModeStore.isEnabledIn(defaults))
    }

    func test_toggle_flipsAndPersists() {
        let store = ReadOnlyModeStore(defaults: defaults)

        store.toggle()
        XCTAssertTrue(store.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: ReadOnlyModeStore.defaultsKey))

        store.toggle()
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(ReadOnlyModeStore(defaults: defaults).isEnabled)
    }

    // MARK: - The guard

    func test_guardClient_blocksDeletion() async {
        let (client, inner, flag) = guarded()
        flag.value = true

        await assertRefused("deleteAssets") {
            try await client.deleteAssets(ids: ["a1"], force: true)
        }

        XCTAssertEqual(inner.requestCount, 0)
        XCTAssertNil(inner.lastDeleteBody)
    }

    func test_guardClient_blocksUpload() async {
        let (client, inner, flag) = guarded()
        flag.value = true

        await assertRefused("uploadAsset") { try await uploadGuard(client) }

        XCTAssertEqual(inner.requestCount, 0)
        XCTAssertTrue(inner.uploads.isEmpty)
    }

    func test_guardClient_forwardsReadsWhenEnabled() async throws {
        let (client, inner, flag) = guarded()
        flag.value = true

        let buckets = try await client.getTimeBuckets(
            isFavorite: nil,
            isTrashed: nil,
            personId: nil,
            withPartners: nil,
            visibility: nil,
            withStacked: nil,
            orderBy: nil
        )
        let asset = try await client.getAsset(id: "a1")

        XCTAssertEqual(buckets.count, 0)
        XCTAssertEqual(asset.id, "a1")
        XCTAssertEqual(inner.requestCount, 2)
    }

    func test_guardClient_forwardsWritesWhenDisabled() async throws {
        let (client, inner, flag) = guarded()
        flag.value = false

        try await client.deleteAssets(ids: ["a1"], force: false)

        XCTAssertEqual(inner.requestCount, 1)
        XCTAssertEqual(inner.lastDeleteBody?.ids, ["a1"])
    }

    /// The mode is a runtime switch, not a launch-time decision: the same guard
    /// instance stops writing the moment the flag turns on, and writes again
    /// once it turns off.
    func test_guardClient_seesTheModeFlipWithoutBeingRebuilt() async throws {
        let (client, inner, flag) = guarded()

        try await client.deleteAssets(ids: ["a1"], force: false)
        XCTAssertEqual(inner.requestCount, 1)

        flag.value = true
        await assertRefused("deleteAssets") {
            try await client.deleteAssets(ids: ["a2"], force: false)
        }
        XCTAssertEqual(inner.requestCount, 1)

        flag.value = false
        try await client.deleteAssets(ids: ["a3"], force: false)
        XCTAssertEqual(inner.requestCount, 2)
    }

    // MARK: - Every blocked family

    func test_guardClient_blocksAssetAndTrashFamily() async {
        let (client, inner, flag) = guarded()
        flag.value = true

        await assertRefused("deleteAssets") {
            try await client.deleteAssets(ids: ["a1"], force: true)
        }
        await assertRefused("restoreTrashAssets") {
            _ = try await client.restoreTrashAssets(ids: ["a1"])
        }
        await assertRefused("restoreAllTrash") {
            _ = try await client.restoreAllTrash()
        }
        await assertRefused("emptyTrash") {
            _ = try await client.emptyTrash()
        }

        XCTAssertEqual(inner.requestCount, 0)
        XCTAssertEqual(inner.emptyTrashCallCount, 0)
        XCTAssertEqual(inner.restoreAllTrashCallCount, 0)
    }

    func test_guardClient_blocksAlbumStackLinkAndPartnerFamily() async {
        let (client, inner, flag) = guarded()
        flag.value = true
        let albumEdit = UpdateAlbumDto(
            albumName: nil,
            description: nil,
            albumThumbnailAssetId: nil,
            isActivityEnabled: nil,
            order: nil
        )

        await assertRefused("deleteAlbum") {
            try await client.deleteAlbum(id: "al1")
        }
        await assertRefused("removeAssetsFromAlbum") {
            _ = try await client.removeAssetsFromAlbum(albumId: "al1", dto: BulkIdsDto(ids: ["a1"]))
        }
        await assertRefused("updateAlbum") {
            _ = try await client.updateAlbum(id: "al1", dto: albumEdit)
        }
        await assertRefused("deleteSharedLink") {
            try await client.deleteSharedLink(id: "sl1")
        }
        await assertRefused("deleteStack") {
            try await client.deleteStack(id: "s1")
        }
        await assertRefused("removeAssetFromStack") {
            try await client.removeAssetFromStack(stackId: "s1", assetId: "a1")
        }
        await assertRefused("updateStack") {
            _ = try await client.updateStack(id: "s1", primaryAssetId: "a1")
        }
        await assertRefused("removePartner") {
            try await client.removePartner(id: "u1")
        }

        XCTAssertEqual(inner.requestCount, 0)
        XCTAssertEqual(inner.deleteAlbumCallCount, 0)
        XCTAssertEqual(inner.deleteSharedLinkCallCount, 0)
    }

    func test_guardClient_blocksTagMemoryActivityAdminAndEditFamily() async {
        let (client, inner, flag) = guarded()
        flag.value = true

        await assertRefused("updateAsset") {
            _ = try await client.updateAsset(id: "a1", dto: UpdateAssetDto(isFavorite: true))
        }
        await assertRefused("updateTag") {
            _ = try await client.updateTag(id: "t1", color: "#ff0000")
        }
        await assertRefused("deleteTag") {
            try await client.deleteTag(id: "t1")
        }
        await assertRefused("updateMemory") {
            _ = try await client.updateMemory(id: "m1", dto: MemoryUpdateDto(isSaved: true))
        }
        await assertRefused("deleteMemory") {
            try await client.deleteMemory(id: "m1")
        }
        await assertRefused("deleteActivity") {
            try await client.deleteActivity(id: "ac1")
        }
        await assertRefused("deleteAdminUser") {
            _ = try await client.deleteAdminUser(id: "u1", force: true)
        }
        await assertRefused("deleteLibrary") {
            try await client.deleteLibrary(id: "lib1")
        }
        await assertRefused("deleteAPIKey") {
            try await client.deleteAPIKey(id: "k1")
        }

        XCTAssertEqual(inner.requestCount, 0)
        XCTAssertEqual(inner.deleteMemoryCallCount, 0)
    }

    // MARK: - The backup run

    /// The upload refusal is upstream, not per asset: one message for the whole
    /// run, published where the Backup screen renders it, and no request at all.
    func test_uploadViewModel_refusesTheRunWhenTheModeIsOn() async {
        let store = ReadOnlyModeStore(defaults: defaults)
        let flag = Flag(true)
        let inner = MockImmichClient()
        let engine = BackupEngine(
            client: inner,
            source: MockBackupAssetSource(),
            environment: MockBackupEnvironment()
        )
        let vm = UploadViewModel(
            client: ReadOnlyGuardClient(inner: inner, isEnabled: { flag.value }),
            photos: MockPhotoLibraryService(),
            engine: engine,
            settings: BackupSettingsStore(suiteName: suiteName),
            scheduler: MockBackupScheduler(),
            activityService: MockBackupLiveActivityService(),
            readOnly: store
        )
        store.setEnabled(true)

        await vm.runBackup(manual: true)

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(inner.requestCount, 0)
        XCTAssertEqual(
            engine.lastError,
            localizedString("Read-only mode is on. Turn it off in Me to change your library.")
        )
    }
}

extension ReadOnlyModeStore {
    /// A store no device can influence.
    ///
    /// Unit tests run INSIDE the app host, so the app's own store reads
    /// `UserDefaults.standard` — including the `readOnlyModeEnabled` flag a UI
    /// scenario left behind. A suite that ran after `ReadOnlyModeUITests` then
    /// saw every `runBackup()` refuse at `UploadViewModel.swift`'s first guard:
    /// 20 failures in `SyncStatusViewModelTests` on 2026-09-16, with no code
    /// change to blame. Every harness therefore passes one of these.
    static func ephemeral() -> ReadOnlyModeStore {
        ReadOnlyModeStore(defaults: UserDefaults(suiteName: "read-only-tests-\(UUID().uuidString)")!)
    }
}
