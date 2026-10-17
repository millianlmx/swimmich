import XCTest
@testable import ImmichSwiftUI

/// Offline download view model (issue #18): the state the storage screen and
/// the viewer's share sheet read, and its synchronisation with the on-disk
/// store and the badge index.
@MainActor
final class OfflineDownloadViewModelTests: XCTestCase {

    private var folder: URL!
    private var defaults: UserDefaults!
    private var transport: MockFileDownloadTransport!
    private var store: OfflineAssetStore!
    private var client: MockImmichClient!
    private var index: OfflineAssetIndex!
    private var vm: OfflineDownloadViewModel!

    private let baseURL = URL(string: "https://example.com")!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-vm-tests-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "offline-vm-tests-\(UUID().uuidString)")!
        transport = MockFileDownloadTransport()
        store = OfflineAssetStore(folderURL: folder, transport: transport, defaults: defaults)
        client = MockImmichClient()
        index = OfflineAssetIndex()
        vm = OfflineDownloadViewModel(store: store, client: client, index: index)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func makeAsset(id: String = "asset-1", isVideo: Bool = false) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 0.75, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: !isVideo, thumbhash: "thumb",
            createdAt: "2024-07-01T10:00:00.000Z", fileCreatedAt: "2024-07-01T10:00:00.000Z",
            localOffsetHours: 0, duration: isVideo ? 12 : nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    // MARK: - Load

    func test_load_populatesListUsageAndIndexFromDisk() async throws {
        transport.payload = Data(repeating: 0x01, count: 300)
        await vm.downloadAsset(makeAsset(id: "asset-1"), baseURL: baseURL, token: "tok")
        await vm.downloadAsset(makeAsset(id: "asset-2"), baseURL: baseURL, token: "tok")

        // A fresh view model over the same folder sees what is on disk.
        let reopenedIndex = OfflineAssetIndex()
        let fresh = OfflineDownloadViewModel(store: store, client: client, index: reopenedIndex)
        await fresh.load()

        XCTAssertEqual(fresh.cachedAssets.count, 2)
        XCTAssertEqual(fresh.cacheUsage, 600)
        XCTAssertTrue(reopenedIndex.isCached("asset-1"))
        XCTAssertNotNil(reopenedIndex.localURL(for: "asset-1"))
        XCTAssertEqual(fresh.maxCacheSize, OfflineAssetStore.defaultMaxCacheSize)
    }

    // MARK: - Download

    func test_downloadAsset_cachesAndPublishesTheFreshState() async {
        transport.payload = Data(repeating: 0x01, count: 128)

        await vm.downloadAsset(makeAsset(), baseURL: baseURL, token: "tok")

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.lastDownloadedID, "asset-1")
        XCTAssertEqual(vm.cachedAssets.map(\.id), ["asset-1"])
        XCTAssertEqual(vm.cacheUsage, 128)
        // The badge index follows: a timeline tile must show the pill without
        // waiting for a reload.
        XCTAssertTrue(index.isCached("asset-1"))
        XCTAssertFalse(vm.isDownloading("asset-1"))
    }

    func test_downloadAsset_surfacesTransportFailureWithoutCaching() async {
        transport.error = URLError(.notConnectedToInternet)

        await vm.downloadAsset(makeAsset(), baseURL: baseURL, token: "tok")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.cachedAssets.isEmpty)
        XCTAssertFalse(index.isCached("asset-1"))
        XCTAssertNil(vm.lastDownloadedID)
    }

    func test_downloadAsset_cancellationIsNotAnError() async {
        transport.error = URLError(.cancelled)

        await vm.downloadAsset(makeAsset(), baseURL: baseURL, token: "tok")

        XCTAssertNil(vm.errorMessage, "a purge-cancelled download is not a failure to show")
        XCTAssertFalse(vm.isDownloading("asset-1"))
    }

    func test_downloadAsset_reportsDeterminateProgress() async {
        transport.payload = Data(repeating: 0x01, count: 100)
        transport.progressSteps = [(50, 100), (100, 100)]

        let asset = makeAsset()
        var observed: [Double] = []
        // Observe the published fraction while the download runs.
        let observation = Task { @MainActor in
            while !Task.isCancelled {
                if let fraction = vm.progress(for: asset.id) { observed.append(fraction) }
                await Task.yield()
            }
        }
        await vm.downloadAsset(asset, baseURL: baseURL, token: "tok")
        observation.cancel()

        XCTAssertEqual(observed.last, 1.0, "Progress must reach completion; saw \(observed)")
    }

    // MARK: - Removal

    func test_removeFromOffline_deletesAndUpdatesEverySurface() async {
        transport.payload = Data(repeating: 0x01, count: 64)
        await vm.downloadAsset(makeAsset(), baseURL: baseURL, token: "tok")

        await vm.removeFromOffline("asset-1")

        XCTAssertTrue(vm.cachedAssets.isEmpty)
        XCTAssertEqual(vm.cacheUsage, 0)
        XCTAssertFalse(index.isCached("asset-1"))
        XCTAssertNil(vm.index.localURL(for: "asset-1"))
    }

    func test_clearAll_emptiesTheCacheAndTheIndex() async {
        transport.payload = Data(repeating: 0x01, count: 64)
        await vm.downloadAsset(makeAsset(id: "asset-1"), baseURL: baseURL, token: "tok")
        await vm.downloadAsset(makeAsset(id: "asset-2"), baseURL: baseURL, token: "tok")

        await vm.clearAll()

        XCTAssertTrue(vm.cachedAssets.isEmpty)
        XCTAssertEqual(vm.cacheUsage, 0)
        XCTAssertTrue(index.isEmpty)
    }

    // MARK: - Derived state

    func test_searchFiltersCachedAssetsByFileName() async {
        transport.payload = Data(repeating: 0x01, count: 64)
        client.getAssetResponse["asset-1"] = assetDTO(id: "asset-1", fileName: "beach.jpg")
        client.getAssetResponse["asset-2"] = assetDTO(id: "asset-2", fileName: "mountain.jpg")
        await vm.downloadAsset(makeAsset(id: "asset-1"), baseURL: baseURL, token: "tok")
        await vm.downloadAsset(makeAsset(id: "asset-2"), baseURL: baseURL, token: "tok")

        vm.searchQuery = "beach"

        XCTAssertEqual(vm.filteredAssets.map(\.id), ["asset-1"])
        vm.searchQuery = ""
        XCTAssertEqual(vm.filteredAssets.count, 2)
    }

    func test_usageFraction_isNilWhenTheBudgetIsUnlimited() async {
        await vm.setMaxCacheSize(0)
        XCTAssertNil(vm.usageFraction)

        await vm.setMaxCacheSize(1000)
        transport.payload = Data(repeating: 0x01, count: 500)
        await vm.downloadAsset(makeAsset(), baseURL: baseURL, token: "tok")

        XCTAssertEqual(vm.usageFraction, 0.5)
        XCTAssertEqual(vm.maxCacheSize, 1000)
    }

    // MARK: - Helpers

    private func assetDTO(id: String, fileName: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T00:00:00.000Z", ownerId: "owner", originalPath: "/x",
            originalFileName: fileName, fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z", updatedAt: "2024-07-01T00:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "abc", isEdited: false
        )
    }
}
