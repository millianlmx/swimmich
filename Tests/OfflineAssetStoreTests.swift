import XCTest
@testable import ImmichSwiftUI

/// Offline cache (issue #18) — file layout, index reconciliation, budget
/// eviction and the local rendering path.
///
/// Every test points the store at its own temp folder, so nothing touches the
/// real Application Support directory and tests stay order-independent.
///
/// `XCTAssert*` macros take autoclosures that reject `await`, so every store
/// call is hoisted into a `let` first.
final class OfflineAssetStoreTests: XCTestCase {

    static let accountA = "https://photos.example.com|alice@example.com"
    static let accountB = "https://other.example.com|bob@example.com"

    /// `OfflineAssets/` of this test (its parent is removed in `tearDown`).
    private var root: URL!
    /// Folder of account A under `root`.
    private var folder: URL!
    private var defaults: UserDefaults!
    private var transport: MockFileDownloadTransport!
    private var store: OfflineAssetStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("OfflineAssets", isDirectory: true)
        // A private suite keeps the budget out of the app's real defaults.
        defaults = UserDefaults(suiteName: "offline-tests-\(UUID().uuidString)")!
        transport = MockFileDownloadTransport()
        store = OfflineAssetStore(
            rootURL: root,
            transport: transport,
            defaults: defaults
        )
        store.setActiveAccount(Self.accountA, otherAccountsRegistered: false)
        folder = store.folderURL(forAccount: Self.accountA)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func download(
        _ id: String,
        fileName: String? = "photo.jpg",
        isVideo: Bool = false,
        announcedSize: Int64? = nil,
        accountID: String = OfflineAssetStoreTests.accountA,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> CachedAssetInfo {
        try await store.download(
            accountID: accountID,
            assetID: id,
            url: URL(string: "https://example.com/api/assets/\(id)/original")!,
            token: "tok",
            fileName: fileName,
            isVideo: isVideo,
            ratio: 0.75,
            fileCreatedAt: "2024-07-01T10:00:00.000Z",
            duration: isVideo ? 12 : nil,
            thumbhash: "thumb",
            announcedSize: announcedSize,
            onProgress: onProgress
        )
    }

    /// Same folder, fresh actor — proves persistence rather than in-memory state.
    private func reopenedStore() -> OfflineAssetStore {
        let reopened = OfflineAssetStore(rootURL: root, transport: transport, defaults: defaults)
        reopened.setActiveAccount(Self.accountA, otherAccountsRegistered: false)
        return reopened
    }

    // MARK: - Write + index

    func test_download_writesFileAndIndexesMetadata() async throws {
        transport.payload = Data(repeating: 0xAB, count: 512)

        let info = try await download("asset-1", fileName: "holiday.jpg")

        XCTAssertEqual(info.id, "asset-1")
        XCTAssertEqual(info.fileName, "asset-1.jpg")
        XCTAssertEqual(info.size, 512)
        XCTAssertEqual(info.ratio, 0.75)
        XCTAssertEqual(info.fileCreatedAt, "2024-07-01T10:00:00.000Z")
        XCTAssertFalse(info.isVideo)

        let onDisk = await store.fileURL(assetID: "asset-1")
        XCTAssertNotNil(onDisk)
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk!.path))
        let cached = await store.isCached(assetID: "asset-1")
        XCTAssertTrue(cached)
        let total = await store.totalBytes()
        XCTAssertEqual(total, 512)

        // Metadata survives a fresh store instance pointed at the same folder:
        // the grid must render after a relaunch, without the server.
        let restored = await reopenedStore().cachedInfo(assetID: "asset-1")
        XCTAssertEqual(restored?.fileCreatedAt, "2024-07-01T10:00:00.000Z")
        XCTAssertEqual(restored?.ratio, 0.75)
        XCTAssertEqual(restored?.thumbhash, "thumb")
    }

    func test_download_forwardsBearerTokenAndReportsProgressToCompletion() async throws {
        transport.payload = Data(repeating: 0x01, count: 100)
        transport.progressSteps = [(25, 100), (50, 100), (100, 100)]
        let recorder = ProgressRecorder()

        try await download("asset-1", onProgress: { recorder.record(received: $0, expected: $1) })

        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(recorder.fractions.sorted(), [0.25, 0.5, 1.0])
    }

    func test_download_usesTheServerFileNameExtension() async throws {
        transport.payload = Data(repeating: 0x01, count: 10)
        transport.contentType = "video/quicktime"

        let info = try await download("asset-1", fileName: "clip.mov", isVideo: true)

        XCTAssertEqual(info.fileName, "asset-1.mov")
        XCTAssertTrue(info.isVideo)
        XCTAssertEqual(info.duration, 12)
    }

    // MARK: - Hit / miss

    func test_cacheHit_returnsInfoAndFileURL() async throws {
        try await download("asset-1")

        let info = await store.cachedInfo(assetID: "asset-1")
        let url = await store.fileURL(assetID: "asset-1")
        XCTAssertEqual(info?.id, "asset-1")
        XCTAssertNotNil(url)
    }

    func test_cacheMiss_isNotCachedAndHasNoFile() async {
        let cached = await store.isCached(assetID: "absent")
        let info = await store.cachedInfo(assetID: "absent")
        let url = await store.fileURL(assetID: "absent")
        let total = await store.totalBytes()

        XCTAssertFalse(cached)
        XCTAssertNil(info)
        XCTAssertNil(url)
        XCTAssertEqual(total, 0)
    }

    // MARK: - Removal

    func test_remove_deletesPayloadAndIndexEntry() async throws {
        try await download("asset-1")
        let file = await store.fileURL(assetID: "asset-1")!

        await store.remove(assetID: "asset-1", accountID: Self.accountA)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let cached = await store.isCached(assetID: "asset-1")
        let total = await store.totalBytes()
        XCTAssertFalse(cached)
        XCTAssertEqual(total, 0)
    }

    func test_clearAll_removesEveryPayloadAndLeavesAnEmptyFolder() async throws {
        try await download("asset-1", fileName: "a.jpg")
        try await download("asset-2", fileName: "b.jpg")
        let before = await store.allCached()
        XCTAssertEqual(before.count, 2)

        await store.clearAll(accountID: Self.accountA)

        let after = await store.allCached()
        let total = await store.totalBytes()
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(total, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(leftovers, ["index.json"], "Only the (empty) index may remain")
    }

    // MARK: - Budget

    func test_download_refusesAnOversizedAssetBeforeAnyByteIsPulled() async throws {
        await store.setMaxCacheSize(1000)

        do {
            try await download("asset-1", announcedSize: 5000)
            XCTFail("Expected the download to be refused")
        } catch let error as OfflineStoreError {
            XCTAssertEqual(error, .exceedsCacheLimit(size: 5000, limit: 1000))
        }

        XCTAssertEqual(transport.downloadCount, 0, "The refusal must happen before the transfer")
        let cached = await store.isCached(assetID: "asset-1")
        XCTAssertFalse(cached)
    }

    func test_eviction_dropsOldestEntriesAndKeepsTheFreshOne() async throws {
        await store.setMaxCacheSize(1000)
        transport.payload = Data(repeating: 0x01, count: 400)

        try await download("oldest")
        try await Task.sleep(nanoseconds: 20_000_000)
        try await download("middle")
        try await Task.sleep(nanoseconds: 20_000_000)
        try await download("newest")

        let cached = await store.allCached()
        let total = await store.totalBytes()
        XCTAssertEqual(cached.map(\.id), ["newest", "middle"], "The oldest entry is evicted first")
        XCTAssertLessThanOrEqual(total, 1000)
        let oldestStillThere = await store.isCached(assetID: "oldest")
        XCTAssertFalse(oldestStillThere)
    }

    // MARK: - Reconciliation

    func test_reconcile_dropsStaleEntriesAndAdoptsOrphanFiles() async throws {
        try await download("stale")
        // File deleted behind the store's back (a disk purge, a failed write).
        let staleFile = await store.fileURL(assetID: "stale")!
        try FileManager.default.removeItem(at: staleFile)

        // A payload with no index entry — e.g. the index was lost.
        let orphan = folder.appendingPathComponent("orphan-asset.jpg")
        try Data(repeating: 0x02, count: 64).write(to: orphan)

        let cached = await reopenedStore().allCached()

        XCTAssertEqual(cached.map(\.id), ["orphan-asset"], "Stale entry dropped, orphan adopted")
        XCTAssertEqual(cached.first?.size, 64)
        let staleCached = await store.isCached(assetID: "stale")
        XCTAssertFalse(staleCached)
    }

    func test_interruptedDownload_leavesNoPartialFile() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("leftover.jpg.partial")
        try Data("half".utf8).write(to: partial)

        _ = await reopenedStore().allCached()

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: - Errors

    func test_serverError_isNotCached() async throws {
        transport.statusCode = 500

        do {
            try await download("asset-1")
            XCTFail("Expected the bad status to surface")
        } catch let error as OfflineStoreError {
            XCTAssertEqual(error, .badStatus(500))
        }

        let cached = await store.isCached(assetID: "asset-1")
        XCTAssertFalse(cached)
    }

    func test_emptyPayload_isRejected() async throws {
        transport.payload = Data()

        do {
            try await download("asset-1")
            XCTFail("Expected the empty payload to surface")
        } catch let error as OfflineStoreError {
            XCTAssertEqual(error, .emptyPayload)
        }

        let cached = await store.isCached(assetID: "asset-1")
        XCTAssertFalse(cached)
    }

    // MARK: - Local rendering (the actual offline promise)

    func test_localImage_rendersWithoutNetwork() async throws {
        // A real JPEG on disk, written through the store's own path. Scale 1 so
        // the pixel size matches the point size the assertion then checks.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 24), format: format)
        transport.payload = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 24))
        }.jpegData(compressionQuality: 1)!

        try await download("asset-1", fileName: "photo.jpg")
        let cached = await store.fileURL(assetID: "asset-1")!

        // No network client is involved at all: the image comes from the file.
        let image = ImageDownsampler.image(at: cached, maxPixelSize: 512)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width, 40)
    }

    func test_downsampler_capsTheDecodedSize() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downsample-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }.jpegData(compressionQuality: 1)!.write(to: url)

        let image = ImageDownsampler.image(at: url, maxPixelSize: 100)

        XCTAssertNotNil(image)
        XCTAssertLessThanOrEqual(max(image?.size.width ?? 0, image?.size.height ?? 0), 100)
    }

    /// A cached VIDEO has no ImageIO still frame, so its tile would show the
    /// failure placeholder offline — the poster frame is what keeps the offline
    /// grid readable for videos.
    func test_videoPoster_rendersAFrameFromALocalMovie() async throws {
        transport.payload = try VideoFixture.makeMovieData()
        try await download("clip-1", fileName: "clip.mp4", isVideo: true)
        let cached = await store.fileURL(assetID: "clip-1")!

        XCTAssertNil(ImageDownsampler.image(at: cached, maxPixelSize: 256),
                     "ImageIO cannot read a movie — this is why the poster path exists")

        let poster = ImageDownsampler.videoPoster(at: cached, maxPixelSize: 256)

        XCTAssertNotNil(poster, "a cached video must still produce a tile")
        XCTAssertLessThanOrEqual(max(poster?.size.width ?? 0, poster?.size.height ?? 0), 256)
    }

    func test_videoPoster_returnsNilForANonVideo() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-movie-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a movie".utf8).write(to: url)

        XCTAssertNil(ImageDownsampler.videoPoster(at: url, maxPixelSize: 128))
    }

    // MARK: - Purge while a download is in flight

    /// `clearAll()` must win even over a transport that ignores the cancellation
    /// and hands a finished file back: nothing may be written afterwards.
    func test_clearAll_dropsADownloadThatFinishesDespiteTheCancellation() async throws {
        transport.gate = {
            // Not cancelled by the parent: models a transport that finishes anyway.
            await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value
        }
        let store = self.store!
        let pending = Task { () -> Result<CachedAssetInfo, Error> in
            do {
                return .success(try await store.download(
                    accountID: Self.accountA, assetID: "late", url: URL(string: "https://example.com/late")!, token: nil,
                    fileName: "late.jpg", isVideo: false, ratio: 1, fileCreatedAt: "", duration: nil,
                    thumbhash: nil, announcedSize: nil
                ))
            } catch { return .failure(error) }
        }
        while transport.downloadCount == 0 { try await Task.sleep(for: .milliseconds(10)) }

        await store.clearAll(accountID: Self.accountA)

        guard case .failure(let error) = await pending.value else {
            return XCTFail("a download overtaken by clearAll() must not succeed")
        }
        XCTAssertTrue(UserFacingError.isCancellation(error), "got \(error)")
        let cached = await store.allCached()
        XCTAssertTrue(cached.isEmpty)
        let payloads = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0 != "index.json" }
        XCTAssertTrue(payloads.isEmpty, "no payload may be written after the purge: \(payloads)")

        // A download started after the purge works normally.
        transport.gate = nil
        try await download("after")
        let after = await store.isCached(assetID: "after")
        XCTAssertTrue(after)
    }
    // MARK: - Per-account scoping (ACC)

    static let legacyInfos: [CachedAssetInfo] = [
        CachedAssetInfo(
            id: "legacy-1", fileName: "legacy-1.jpg", originalFileName: "IMG_0001.jpg",
            cachedAt: Date(timeIntervalSince1970: 1_700_000_000), size: 100, isVideo: false,
            ratio: 0.75, fileCreatedAt: "2024-07-01T10:00:00.000Z", duration: nil, thumbhash: "th-1"
        ),
        CachedAssetInfo(
            id: "legacy-2", fileName: "legacy-2.jpg", originalFileName: "IMG_0002.jpg",
            cachedAt: Date(timeIntervalSince1970: 1_700_000_100), size: 300, isVideo: false,
            ratio: 1.5, fileCreatedAt: "2024-07-02T10:00:00.000Z", duration: nil, thumbhash: "th-2"
        ),
    ]

    /// An `index.json` and two payloads (100 + 300 bytes) as the single-folder
    /// layout left them directly under `root`.
    static func seedLegacyContent(into root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder.immich
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(legacyInfos).write(to: root.appendingPathComponent("index.json"))
        for info in legacyInfos {
            try Data(repeating: 0x07, count: Int(info.size)).write(to: root.appendingPathComponent(info.fileName))
        }
    }

    private func regularFileSizes(under directory: URL) -> [String: Int] {
        var sizes: [String: Int] = [:]
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { sizes[url.lastPathComponent] = values?.fileSize ?? 0 }
        }
        return sizes
    }

    /// Read on a **new** URL: `URL` caches the resource values it has read.
    private func excluded(_ url: URL) -> Bool? {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        return try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    func test_ACC_AC7_legacyContent_movesIntoTheOnlyAccount() async throws {
        try Self.seedLegacyContent(into: root)

        store.setActiveAccount(Self.accountA, otherAccountsRegistered: false)
        let listing = await store.listing()

        XCTAssertEqual(listing.items.count, 2)
        XCTAssertEqual(listing.items.sorted { $0.id < $1.id }, Self.legacyInfos, "original metadata survives the move")
        XCTAssertEqual(listing.totalBytes, 400)
        let sizes = regularFileSizes(under: folder)
        XCTAssertEqual(sizes["legacy-1.jpg"], 100)
        XCTAssertEqual(sizes["legacy-2.jpg"], 300)
        let rootChildren = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(rootChildren, ["Accounts"], "no copy and no index.json left at the root")
    }

    func test_OFF_AC15_ACC_AC8_legacyContent_withOtherAccounts_goesToUnassigned() async throws {
        try Self.seedLegacyContent(into: root)

        store.setActiveAccount(Self.accountA, otherAccountsRegistered: true)
        let forA = await store.listing()
        let legacy1ForA = await store.isCached(assetID: "legacy-1")
        let legacy2ForA = await store.isCached(assetID: "legacy-2")
        store.setActiveAccount(Self.accountB, otherAccountsRegistered: true)
        let forB = await store.listing()
        let legacy1ForB = await store.isCached(assetID: "legacy-1")
        let legacy2ForB = await store.isCached(assetID: "legacy-2")

        XCTAssertTrue(forA.items.isEmpty)
        XCTAssertTrue(forB.items.isEmpty)
        XCTAssertFalse(legacy1ForA)
        XCTAssertFalse(legacy2ForA)
        XCTAssertFalse(legacy1ForB)
        XCTAssertFalse(legacy2ForB)
        let unassigned = regularFileSizes(under: store.unassignedURL)
        XCTAssertEqual(unassigned["legacy-1.jpg"], 100)
        XCTAssertEqual(unassigned["legacy-2.jpg"], 300)
        XCTAssertNotNil(unassigned["index.json"])
        XCTAssertEqual(regularFileSizes(under: store.folderURL(forAccount: Self.accountA)).filter { $0.key != "index.json" }, [:])
        XCTAssertEqual(regularFileSizes(under: store.folderURL(forAccount: Self.accountB)).filter { $0.key != "index.json" }, [:])
        XCTAssertEqual(try rootChildren(), ["Accounts", "Unassigned"])
    }

    func test_ACC_AC9_rootIsExcludedFromBackup_durably() async throws {
        _ = await store.listing()
        XCTAssertEqual(excluded(root), true, "serving a account excludes the root")
        XCTAssertNotEqual(excluded(root.deletingLastPathComponent()), true, "the parent is never excluded")

        try await download("a1")
        XCTAssertEqual(excluded(root), true, "after a download")

        await store.clearAll(accountID: Self.accountA)
        XCTAssertEqual(excluded(root), true, "after clearAll")

        await store.clearEveryAccount()
        XCTAssertEqual(excluded(root), true, "after clearEveryAccount")

        try FileManager.default.removeItem(at: root)
        try await download("a2")
        XCTAssertEqual(excluded(root), true, "after the folders were recreated")
        XCTAssertNotEqual(excluded(root.deletingLastPathComponent()), true)
    }

    func test_ACC_AC19_capAppliesToEachAccountSeparately() async throws {
        await store.setMaxCacheSize(1000)
        transport.payload = Data(repeating: 0x01, count: 900)
        try await download("a1")

        store.setActiveAccount(Self.accountB, otherAccountsRegistered: true)
        transport.payload = Data(repeating: 0x02, count: 400)
        try await download("b1", announcedSize: 400, accountID: Self.accountB)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await download("b2", announcedSize: 400, accountID: Self.accountB)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await download("b3", announcedSize: 400, accountID: Self.accountB)

        let cachedForB = await store.allCached()
        let totalForB = await store.totalBytes()
        XCTAssertEqual(cachedForB.map(\.id), ["b3", "b2"])
        XCTAssertEqual(totalForB, 800)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a1.jpg").path))

        store.setActiveAccount(Self.accountA, otherAccountsRegistered: true)
        let forA = await store.listing()
        XCTAssertEqual(forA.items.map(\.id), ["a1"])
    }

    func test_ACC_AC22_loweringTheCap_trimsOnlyTheActiveAccount() async throws {
        await store.setMaxCacheSize(1000)
        transport.payload = Data(repeating: 0x01, count: 450)
        try await download("a1")
        try await Task.sleep(nanoseconds: 20_000_000)
        try await download("a2")

        store.setActiveAccount(Self.accountB, otherAccountsRegistered: true)
        transport.payload = Data(repeating: 0x02, count: 400)
        try await download("b1", accountID: Self.accountB)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await download("b2", accountID: Self.accountB)

        await store.setMaxCacheSize(500)

        let cachedForB = await store.allCached()
        XCTAssertEqual(cachedForB.map(\.id), ["b2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a1.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a2.jpg").path))

        store.setActiveAccount(Self.accountA, otherAccountsRegistered: true)
        let forA = await store.listing()
        XCTAssertEqual(forA.items.map(\.id), ["a2", "a1"], "activation never trims")
        XCTAssertEqual(forA.totalBytes, 900)

        transport.payload = Data(repeating: 0x03, count: 100)
        try await download("a3")
        let afterDownload = await store.allCached()
        let total = await store.totalBytes()
        XCTAssertEqual(afterDownload.map(\.id), ["a3"])
        XCTAssertEqual(total, 100)
    }
}

// MARK: - Legacy content takeover (OFF)

extension OfflineAssetStoreTests {

    /// Children of the root, sorted (the order `contentsOfDirectory` returns is unspecified).
    private func rootChildren() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    private func nameMatches(_ file: String, uuidPrefixedName name: String) -> Bool {
        let pattern = "^[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}-\(NSRegularExpression.escapedPattern(for: name))$"
        return file.range(of: pattern, options: .regularExpression) != nil
    }

    private func makeStore(
        _ fileManager: FileManager = .default, active: String, others: Bool
    ) -> OfflineAssetStore {
        let fresh = OfflineAssetStore(
            rootURL: root, transport: MockFileDownloadTransport(),
            fileManager: fileManager, defaults: UserDefaults(suiteName: "offline-tests-\(UUID().uuidString)")!
        )
        fresh.setActiveAccount(active, otherAccountsRegistered: others)
        return fresh
    }

    private func writeIndex(_ infos: [CachedAssetInfo], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder.immich
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(infos).write(to: directory.appendingPathComponent("index.json"))
    }

    private func ownInfo(_ id: String, original: String) -> CachedAssetInfo {
        CachedAssetInfo(
            id: id, fileName: "\(id).jpg", originalFileName: original,
            cachedAt: Date(timeIntervalSince1970: 1_700_000_200), size: 50, isVideo: false,
            ratio: 1, fileCreatedAt: "2024-07-03T10:00:00.000Z", duration: nil, thumbhash: nil
        )
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    func test_OFF_AC16_legacyAttachedOrSetAside_neverReachesALaterAccount() async throws {
        let folderA = store.folderURL(forAccount: Self.accountA)
        let folderB = store.folderURL(forAccount: Self.accountB)

        // a: attached to A.
        try Self.seedLegacyContent(into: root)
        let forA = await store.listing()
        XCTAssertEqual(forA.items.count, 2)
        let attachedSizes = regularFileSizes(under: folderA)
        store.setActiveAccount(Self.accountB, otherAccountsRegistered: false)
        let bAlone = await store.listing()
        let bAloneCached = await store.isCached(assetID: "legacy-1")
        store.setActiveAccount(Self.accountB, otherAccountsRegistered: true)
        let bWithOthers = await store.listing()
        XCTAssertTrue(bAlone.items.isEmpty)
        XCTAssertTrue(bWithOthers.items.isEmpty)
        XCTAssertFalse(bAloneCached)
        XCTAssertEqual(regularFileSizes(under: folderA), attachedSizes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.unassignedURL.path))

        // b: set aside.
        try FileManager.default.removeItem(at: root)
        store = makeStore(active: Self.accountA, others: true)
        try Self.seedLegacyContent(into: root)
        let forAAside = await store.listing()
        XCTAssertTrue(forAAside.items.isEmpty)
        let asideSizes = regularFileSizes(under: store.unassignedURL)
        XCTAssertEqual(asideSizes["legacy-1.jpg"], 100)
        store.setActiveAccount(Self.accountB, otherAccountsRegistered: false)
        let bLater = await store.listing()
        let bLaterCached = await store.isCached(assetID: "legacy-1")
        XCTAssertTrue(bLater.items.isEmpty)
        XCTAssertFalse(bLaterCached)
        XCTAssertEqual(regularFileSizes(under: store.unassignedURL), asideSizes)
        XCTAssertEqual(regularFileSizes(under: folderB).filter { $0.key != "index.json" }, [:])
    }

    func test_OFF_AC17bis_unassignedIsExcludedFromBackup_durably() async throws {
        try Self.seedLegacyContent(into: root)
        store.setActiveAccount(Self.accountA, otherAccountsRegistered: true)
        _ = await store.listing()

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.unassignedURL.appendingPathComponent("legacy-1.jpg").path))
        XCTAssertEqual(excluded(store.unassignedURL), true)
    }

    func test_OFF_AC47_recreatedUnassigned_isExcludedAgain_parentNever() async throws {
        try Self.seedLegacyContent(into: root)
        store.setActiveAccount(Self.accountA, otherAccountsRegistered: true)
        _ = await store.listing()
        try FileManager.default.removeItem(at: store.unassignedURL)
        try Self.seedLegacyContent(into: root)

        let later = makeStore(active: Self.accountB, others: true)
        _ = await later.listing()

        XCTAssertTrue(FileManager.default.fileExists(atPath: later.unassignedURL.appendingPathComponent("legacy-1.jpg").path))
        XCTAssertEqual(excluded(later.unassignedURL), true)
        XCTAssertNotEqual(excluded(root.deletingLastPathComponent()), true)
    }

    func test_OFF_AC40_legacyPartial_isDeleted_neverMoved() async throws {
        for others in [false, true] {
            if others { try FileManager.default.removeItem(at: root) }
            let current = makeStore(active: Self.accountA, others: others)
            try Self.seedLegacyContent(into: root)
            try Data(repeating: 0x09, count: 10).write(to: root.appendingPathComponent("legacy-3.jpg.partial"))

            let listing = await current.listing()

            let everything = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
            XCTAssertEqual(everything.filter { $0.hasSuffix(".partial") }, [], "others=\(others)")
            XCTAssertFalse(listing.items.contains { $0.id == "legacy-3" || $0.id == "legacy-3.jpg" }, "others=\(others)")
            XCTAssertEqual(try rootChildren(), others ? ["Accounts", "Unassigned"] : ["Accounts"], "others=\(others)")
        }
    }

    func test_OFF_AC41_nameTakenInAccountFolder_goesToUnassignedWithUUIDPrefix() async throws {
        let folderA = store.folderURL(forAccount: Self.accountA)

        // The colliding item is a payload.
        let scripted1 = ScriptedFileManager(root: root, firstAtRoot: "legacy-1.jpg")
        let jpgStore = makeStore(scripted1, active: Self.accountA, others: false)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 50).write(to: folderA.appendingPathComponent("legacy-1.jpg"))
        try Self.seedLegacyContent(into: root)
        _ = await jpgStore.listing()

        XCTAssertGreaterThanOrEqual(scripted1.rootListings, 1)
        XCTAssertEqual(try Data(contentsOf: folderA.appendingPathComponent("legacy-1.jpg")), Data(repeating: 0x55, count: 50))
        let aside1 = regularFileSizes(under: jpgStore.unassignedURL)
        XCTAssertEqual(aside1.count, 1)
        XCTAssertTrue(nameMatches(aside1.keys.first ?? "", uuidPrefixedName: "legacy-1.jpg"))
        XCTAssertEqual(aside1.values.first, 100)
        XCTAssertEqual(regularFileSizes(under: folderA)["legacy-2.jpg"], 300)
        XCTAssertNotNil(regularFileSizes(under: folderA)["index.json"])
        XCTAssertEqual(try rootChildren(), ["Accounts", "Unassigned"])

        // The colliding item is the legacy index.
        try FileManager.default.removeItem(at: root)
        let scripted2 = ScriptedFileManager(root: root, firstAtRoot: "index.json")
        let indexStore = makeStore(scripted2, active: Self.accountA, others: false)
        try writeIndex([ownInfo("own-1", original: "OWN.jpg")], in: folderA)
        try Data(repeating: 0x33, count: 50).write(to: folderA.appendingPathComponent("own-1.jpg"))
        try Self.seedLegacyContent(into: root)
        let listing = await indexStore.listing()

        XCTAssertGreaterThanOrEqual(scripted2.rootListings, 1)
        let items = listing.items.sorted { $0.id < $1.id }
        XCTAssertEqual(items.map(\.id), ["legacy-1", "legacy-2", "own-1"])
        XCTAssertEqual(items.first { $0.id == "own-1" }?.originalFileName, "OWN.jpg")
        XCTAssertNil(items.first { $0.id == "legacy-1" }?.originalFileName)
        XCTAssertNil(items.first { $0.id == "legacy-2" }?.originalFileName)
        let aside2 = try FileManager.default.contentsOfDirectory(atPath: indexStore.unassignedURL.path)
        XCTAssertEqual(aside2.count, 1)
        let movedName = aside2.first ?? ""
        XCTAssertTrue(nameMatches(movedName, uuidPrefixedName: "index.json"))
        let decoded = try JSONDecoder.immich.decode(
            [CachedAssetInfo].self, from: Data(contentsOf: indexStore.unassignedURL.appendingPathComponent(movedName))
        )
        XCTAssertEqual(decoded.sorted { $0.id < $1.id }, Self.legacyInfos)
    }

    func test_OFF_AC42_existingUnassigned_isNeverListedNorTouched() async throws {
        let unassigned = store.unassignedURL
        try FileManager.default.createDirectory(at: unassigned, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 64).write(to: unassigned.appendingPathComponent("u1.jpg"))
        try writeIndex([ownInfo("u1", original: "U1.jpg")], in: unassigned)
        let before = regularFileSizes(under: unassigned)

        let first = await store.listing()
        let cached = await store.isCached(assetID: "u1")
        let reopened = await reopenedStore().listing()

        XCTAssertTrue(first.items.isEmpty)
        XCTAssertTrue(reopened.items.isEmpty)
        XCTAssertFalse(cached)
        XCTAssertFalse((first.items + reopened.items).contains { $0.id == "Accounts" || $0.id == "Unassigned" })
        XCTAssertEqual(regularFileSizes(under: unassigned), before)
        XCTAssertEqual(try rootChildren(), ["Accounts", "Unassigned"])
    }

    func test_OFF_AC45_failedMoves_leaveTheItemAtTheRoot_andNeverHandItToALaterAccount() async throws {
        let folderA = store.folderURL(forAccount: Self.accountA)
        try Self.seedLegacyContent(into: root)
        let scripted = ScriptedFileManager(failingMoves: ["legacy-1.jpg"], root: root, firstAtRoot: "legacy-1.jpg")
        let failing = makeStore(scripted, active: Self.accountA, others: false)

        let listing = await failing.listing()
        let cached = await failing.isCached(assetID: "legacy-1")

        XCTAssertEqual(listing.items.map(\.id), ["legacy-2"])
        XCTAssertFalse(cached)
        XCTAssertEqual(fileSize(root.appendingPathComponent("legacy-1.jpg")), 100)
        XCTAssertEqual(scripted.attempts.count, 2)
        XCTAssertEqual(scripted.attempts.first?.path, folderA.appendingPathComponent("legacy-1.jpg").path)
        XCTAssertEqual(scripted.attempts.last?.deletingLastPathComponent().lastPathComponent, "Unassigned")
        XCTAssertTrue(nameMatches(scripted.attempts.last?.lastPathComponent ?? "", uuidPrefixedName: "legacy-1.jpg"))
        XCTAssertGreaterThanOrEqual(scripted.rootListings, 1)

        let later = makeStore(active: Self.accountB, others: false)
        let forB = await later.listing()
        let cachedForB = await later.isCached(assetID: "legacy-1")

        XCTAssertTrue(forB.items.isEmpty)
        XCTAssertFalse(cachedForB)
        let aside = regularFileSizes(under: later.unassignedURL)
        XCTAssertEqual(aside["legacy-1.jpg"] ?? aside.first { nameMatches($0.key, uuidPrefixedName: "legacy-1.jpg") }?.value, 100)
        XCTAssertEqual(regularFileSizes(under: later.folderURL(forAccount: Self.accountB)).filter { $0.key != "index.json" }, [:])
        XCTAssertEqual(try rootChildren(), ["Accounts", "Unassigned"])
    }

    func test_OFF_AC46_traceOfAnEarlierReprise_sendsLeftoversToUnassigned() async throws {
        for variant in ["unassigned", "accounts"] {
            if variant == "accounts" { try FileManager.default.removeItem(at: root) }
            let later = makeStore(active: Self.accountB, others: false)
            let folderA = later.folderURL(forAccount: Self.accountA)
            if variant == "unassigned" {
                try FileManager.default.createDirectory(at: later.unassignedURL, withIntermediateDirectories: true)
                try Data(repeating: 0x42, count: 64).write(to: later.unassignedURL.appendingPathComponent("u1.jpg"))
            } else {
                try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
            }
            try Data(repeating: 0x07, count: 100).write(to: root.appendingPathComponent("legacy-1.jpg"))

            let listing = await later.listing()
            let cached = await later.isCached(assetID: "legacy-1")

            XCTAssertTrue(listing.items.isEmpty, variant)
            XCTAssertFalse(cached, variant)
            XCTAssertEqual(regularFileSizes(under: later.unassignedURL)["legacy-1.jpg"], 100, variant)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: later.folderURL(forAccount: Self.accountB).appendingPathComponent("legacy-1.jpg").path), variant)
            if variant == "unassigned" {
                XCTAssertEqual(regularFileSizes(under: later.unassignedURL)["u1.jpg"], 64, variant)
            } else {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folderA.path), [], variant)
            }
        }
    }
}

/// Real file operations, except that chosen moves fail (recording their
/// destination) and the root listing can be reordered, so a test can pin the
/// order in which `adoptLegacyContent` meets the items.
final class ScriptedFileManager: FileManager {
    private let failingMoves: Set<String>
    private let root: URL?
    private let firstAtRoot: String?
    private(set) var attempts: [URL] = []
    private(set) var rootListings = 0

    init(failingMoves: Set<String> = [], root: URL? = nil, firstAtRoot: String? = nil) {
        self.failingMoves = failingMoves
        self.root = root
        self.firstAtRoot = firstAtRoot
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failingMoves.contains(srcURL.lastPathComponent) {
            attempts.append(dstURL)
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func contentsOfDirectory(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        let contents = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        guard let root, let firstAtRoot, url.standardizedFileURL.path == root.standardizedFileURL.path else {
            return contents
        }
        rootListings += 1
        return contents.filter { $0.lastPathComponent == firstAtRoot }
            + contents.filter { $0.lastPathComponent != firstAtRoot }
    }
}
