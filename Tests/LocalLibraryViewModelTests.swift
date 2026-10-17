import Photos
import XCTest
@testable import ImmichSwiftUI

/// "On this device" (P2 local-library, gap G3): the ViewModel *is* the screen —
/// what it reads from the device, what it asks the server, and what it sends.
///
/// `PHAsset` cannot be built with a real `localIdentifier` (a bare instance has
/// no library backing), so the fixtures are subclasses that override exactly the
/// properties the screen reads. That keeps the production code free of a test
/// seam: no closure or protocol exists only so this file can run.
@MainActor
final class LocalLibraryViewModelTests: XCTestCase {

    private var photos: LocalLibraryPhotoLibrary!
    private var source: MockBackupAssetSource!
    private var client: MockImmichClient!
    private var vm: LocalLibraryViewModel!

    override func setUp() {
        super.setUp()
        photos = LocalLibraryPhotoLibrary()
        source = MockBackupAssetSource()
        client = MockImmichClient()
        vm = LocalLibraryViewModel(photoLibrary: photos, albumSource: source, client: client)
    }

    override func tearDown() {
        photos = nil
        source = nil
        client = nil
        vm = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func asset(_ id: String, video: Bool = false) -> PHAsset {
        LocalLibraryFakeAsset(id: id, mediaType: video ? .video : .image)
    }

    private func album(_ id: String, _ name: String, count: Int, smart: Bool = false) -> BackupAlbum {
        BackupAlbum(id: id, name: name, count: count, isSmart: smart)
    }

    // MARK: - Enumeration

    func test_loadAlbums_exposesUserAndSmartAlbums() async {
        source.albums = [
            album("album/trip", "Trip", count: 3),
            album(BackupAlbum.SmartID.screenshots, "Screenshots", count: 2, smart: true),
        ]

        vm.loadAlbums()

        XCTAssertEqual(vm.albums.map(\.id), ["album/trip", BackupAlbum.SmartID.screenshots])
        XCTAssertEqual(vm.albums.map(\.name), ["Trip", "Screenshots"])
        XCTAssertEqual(vm.albums.last?.isSmart, true)
    }

    func test_loadAssets_withoutAlbumID_returnsWholeLibrary() async {
        photos.library = [asset("L1"), asset("L2", video: true), asset("L3")]

        await vm.loadAssets(albumID: nil)

        XCTAssertEqual(vm.assets.map(\.localIdentifier), ["L1", "L2", "L3"])
        // Photos/videos/summary come from the media type alone; the device column
        // never carries bytes (counting them means reading every resource).
        XCTAssertEqual(vm.localSummary, LocalLibraryViewModel.MediaSummary(photos: 2, videos: 1, bytes: 0))
        XCTAssertEqual(vm.localSummary.total, 3)
        XCTAssertNil(vm.selectedAlbumID)
        XCTAssertNil(vm.selectedAlbumName)
        XCTAssertTrue(vm.didLoad)
        XCTAssertEqual(vm.phase, .idle)
    }

    func test_loadAssets_withAlbumID_scopesToThatAlbum() async {
        photos.library = [asset("L1"), asset("L2"), asset("L3")]
        photos.scoped = ["album/trip": [asset("L3")]]
        source.albums = [album("album/trip", "Trip", count: 1)]
        vm.loadAlbums()

        await vm.loadAssets(albumID: "album/trip")

        XCTAssertEqual(vm.assets.map(\.localIdentifier), ["L3"])
        XCTAssertEqual(vm.selectedAlbumID, "album/trip")
        XCTAssertEqual(vm.selectedAlbumName, "Trip")
        XCTAssertEqual(vm.localSummary.photos, 1)
    }

    func test_switchingAlbum_dropsSelectionAndVerdict() async {
        photos.library = [asset("L1"), asset("L2")]
        photos.scoped = ["album/trip": [asset("L2")]]
        await vm.loadAssets(albumID: nil)
        vm.toggle("L1")
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [.init(id: "L1", action: "accept")])
        await vm.checkSelection()
        XCTAssertTrue(vm.hasVerdict)

        await vm.loadAssets(albumID: "album/trip")

        // A verdict describes the assets it was asked about: it does not follow
        // the user into another album.
        XCTAssertTrue(vm.selectedIDs.isEmpty)
        XCTAssertTrue(vm.localOnlyIDs.isEmpty)
        XCTAssertTrue(vm.savedIDs.isEmpty)
        XCTAssertFalse(vm.hasVerdict)
    }

    // MARK: - The server verdict

    func test_checkSelection_splitsAcceptedAndRejected() async {
        photos.library = [asset("A"), asset("B")]
        photos.checksums = ["A": "sum-a", "B": "sum-b"]
        await vm.loadAssets(albumID: nil)
        vm.toggle("A")
        vm.toggle("B")
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "B", action: "reject"),
            .init(id: "A", action: "accept"),
        ])

        await vm.checkSelection()

        // `reject` = the server has it, `accept` = it does not.
        XCTAssertEqual(vm.savedIDs, ["B"])
        XCTAssertEqual(vm.localOnlyIDs, ["A"])
        XCTAssertEqual(vm.savedCount, 1)
        XCTAssertEqual(vm.localOnlyCount, 1)
        XCTAssertTrue(vm.hasVerdict)
        XCTAssertEqual(vm.phase, .idle)
        // One request, carrying the local checksums of exactly the selection.
        XCTAssertEqual(client.bulkUploadCheckChunks.count, 1)
        XCTAssertEqual(client.bulkUploadCheckChunks[0].map(\.id), ["A", "B"])
        XCTAssertEqual(client.bulkUploadCheckChunks[0].map(\.checksum), ["sum-a", "sum-b"])
    }

    // MARK: - Sending

    func test_uploadSelection_sendsOnlyAcceptedIDs() async {
        photos.library = [asset("A"), asset("B")]
        photos.data = ["A": Data([0xAA]), "B": Data([0xBB])]
        photos.checksums = ["A": "sum-a", "B": "sum-b"]
        await vm.loadAssets(albumID: nil)
        vm.toggle("A")
        vm.toggle("B")
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "A", action: "accept"),
            .init(id: "B", action: "reject"),
        ])
        await vm.checkSelection()

        await vm.uploadSelection()

        // The asset the server already had never leaves the device.
        XCTAssertEqual(client.uploads.map { $0.deviceAssetId }, ["A"])
        XCTAssertEqual(client.uploads.map { $0.visibility }, [.timeline])
        XCTAssertEqual(client.lastUploadData, Data([0xAA]))
        XCTAssertEqual(client.lastUploadFilename, "A.jpg")
        XCTAssertEqual(client.lastUploadChecksum, "sum-a")
        // Sent assets swap columns; the progress bar goes away with the phase.
        XCTAssertEqual(vm.savedIDs, ["A", "B"])
        XCTAssertTrue(vm.localOnlyIDs.isEmpty)
        XCTAssertNil(vm.uploadProgress)
        XCTAssertEqual(vm.phase, .idle)
    }

    func test_uploadSelection_isNoOp_whenNothingIsLocalOnly() async {
        photos.library = [asset("A")]
        photos.checksums = ["A": "sum-a"]
        await vm.loadAssets(albumID: nil)
        vm.toggle("A")
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [.init(id: "A", action: "reject")])
        await vm.checkSelection()

        await vm.uploadSelection()

        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertNil(vm.uploadProgress)
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.savedIDs, ["A"])
    }

    // MARK: - Failure and selection state

    func test_loadRemoteSummary_failure_leavesRemoteNil() async {
        client.globalError = APIError.decoding("server unreachable")

        await vm.loadRemoteSummary()

        // An unreachable server is not an empty server: the column shows nothing
        // rather than a zero it cannot vouch for.
        XCTAssertNil(vm.remoteSummary)
        XCTAssertNotNil(vm.errorMessage)

        client.globalError = nil
        client.serverStatisticsResponse = ServerStatsResponseDto(
            photos: 12, videos: 3, usage: 2048, usagePhotos: 0, usageVideos: 0, usageByUser: []
        )

        await vm.loadRemoteSummary()

        XCTAssertEqual(vm.remoteSummary, LocalLibraryViewModel.MediaSummary(photos: 12, videos: 3, bytes: 2048))
        XCTAssertEqual(vm.remoteSummary?.total, 15)
        XCTAssertNil(vm.errorMessage)
    }

    func test_selectionState_togglesAndClears() async {
        photos.library = [asset("L1"), asset("L2")]
        await vm.loadAssets(albumID: nil)

        vm.toggle("L1")
        vm.toggle("L2")
        vm.toggle("L2")

        XCTAssertEqual(vm.selectedIDs, ["L1"])
        XCTAssertEqual(vm.selectionCount, 1)
        XCTAssertTrue(vm.hasSelection)

        vm.toggle("L1")
        XCTAssertFalse(vm.hasSelection)
        XCTAssertEqual(vm.selectionCount, 0)

        vm.toggle("L1")
        vm.clearSelection()
        XCTAssertTrue(vm.selectedIDs.isEmpty)
    }

    func test_requestAccess_denied_keepsLibraryUnreadable() async {
        photos.status = .denied

        await vm.requestAccess()

        XCTAssertEqual(vm.authorization, .denied)
        XCTAssertFalse(vm.canReadLibrary)
        // Nothing is enumerated for a library we are not allowed to read — an
        // empty grid here would read as "no photos".
        XCTAssertTrue(vm.assets.isEmpty)
        XCTAssertFalse(vm.didLoad)
    }

    /// The thumbnail point this screen added must *terminate* for an asset that
    /// has no on-device image: `ContinuationGate` exists precisely because a
    /// dropped resume used to leave the caller parked forever, and a parked tile
    /// freezes the grid behind a skeleton. Run against the real
    /// `PhotoLibraryServiceImpl` — a mock would prove nothing about the gate.
    func test_loadThumbnail_withoutLocalImage_completesInsteadOfHanging() async {
        let service = PhotoLibraryServiceImpl()
        let orphan = asset("no-such-asset-in-any-library")

        let returned = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await service.loadThumbnail(for: orphan, targetSize: CGSize(width: 64, height: 64), scale: 2)
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(returned, "loadThumbnail never resumed — the tile would hang forever")
    }

    // MARK: - No read without a gesture (AC-5, AC-7)

    func test_AC5_reload_undetermined_readsNoAlbumNorAssetAndNeverPrompts() async {
        photos.status = .notDetermined
        photos.library = [asset("L1")]
        source.albums = [album("album/trip", "Trip", count: 1)]
        let vmNotDetermined = LocalLibraryViewModel(photoLibrary: photos, albumSource: source, client: client)

        await vmNotDetermined.reload()

        XCTAssertEqual(photos.requestCount, 0)
        XCTAssertEqual(source.fetchAlbumsCallCount, 0)
        XCTAssertTrue(vmNotDetermined.assets.isEmpty)
        XCTAssertFalse(vmNotDetermined.didLoad)
        XCTAssertFalse(vmNotDetermined.canReadLibrary)
    }

    func test_AC5_reload_denied_stillReadsTheServerSummary() async {
        photos.status = .denied
        client.serverStatisticsResponse = ServerStatsResponseDto(
            photos: 4, videos: 1, usage: 10, usagePhotos: 0, usageVideos: 0, usageByUser: []
        )

        await vm.reload()

        XCTAssertEqual(source.fetchAlbumsCallCount, 0)
        XCTAssertEqual(vm.remoteSummary?.photos, 4)
    }

    func test_AC5_reload_afterAccessIsGranted_loadsTheDevice() async {
        photos.status = .notDetermined
        photos.library = [asset("L1"), asset("L2")]
        await vm.reload()
        XCTAssertFalse(vm.didLoad)

        photos.status = .limited
        await vm.reload()

        XCTAssertEqual(vm.assets.count, 2)
        XCTAssertTrue(vm.didLoad)
    }
}

/// Minimal `PhotoLibraryService` for this screen: tables instead of Photos.
private final class LocalLibraryPhotoLibrary: PhotoLibraryService, @unchecked Sendable {
    var status: PHAuthorizationStatus = .authorized
    /// How many times the Photos prompt was raised.
    var requestCount = 0
    var library: [PHAsset] = []
    var scoped: [String: [PHAsset]] = [:]
    var checksums: [String: String] = [:]
    var data: [String: Data] = [:]

    func authorizationStatus() -> PHAuthorizationStatus { status }

    func requestAuthorization(_ handler: @escaping (PHAuthorizationStatus) -> Void) {
        requestCount += 1
        handler(status)
    }

    func fetchAssets() -> [PHAsset] { library }

    func fetchAssets(inAlbumID albumID: String) -> [PHAsset] { scoped[albumID] ?? [] }

    func loadData(for asset: PHAsset) async throws -> Data { data[asset.localIdentifier] ?? Data() }

    func checksum(for asset: PHAsset) async throws -> String {
        checksums[asset.localIdentifier] ?? "sum-\(asset.localIdentifier)"
    }

    func isoTimestamps(for asset: PHAsset) -> (createdAt: String, modifiedAt: String) {
        ("2024-07-01T10:00:00.000Z", "2024-07-01T10:00:00.000Z")
    }

    func saveImage(data: Data) async throws -> String { "saved-image" }

    func saveVideo(at fileURL: URL) async throws -> String { "saved-video" }
}

/// A `PHAsset` that answers the four properties the screen reads. `PHAsset`
/// cannot be given a `localIdentifier` (KVC rejects it), so the only way to get
/// two distinguishable assets is to subclass it.
private final class LocalLibraryFakeAsset: PHAsset, @unchecked Sendable {
    private let identifier: String
    private let kind: PHAssetMediaType

    init(id: String, mediaType: PHAssetMediaType) {
        self.identifier = id
        self.kind = mediaType
        super.init()
    }

    override var localIdentifier: String { identifier }
    override var mediaType: PHAssetMediaType { kind }
    override var duration: TimeInterval { kind == .video ? 12 : 0 }
    override var isFavorite: Bool { false }
}
