import XCTest
@testable import ImmichSwiftUI

/// The merged Photos timeline: this device's photos not on the server yet,
/// folded month by month into the server's timeline.
final class MergedTimelineTests: XCTestCase {

    /// A scripted device library: `excluding` is honored like the PhotoKit
    /// source honors the ledger, and the calls are counted.
    private final class ScriptedDeviceSource: DeviceTimelineSource, @unchecked Sendable {
        let items: [AssetReactItem]
        private(set) var calls: [(excluding: Set<String>, favoritesOnly: Bool)] = []
        init(_ items: [AssetReactItem]) { self.items = items }

        func deviceOnlyItems(excluding uploaded: Set<String>, favoritesOnly: Bool) async -> [AssetReactItem] {
            calls.append((uploaded, favoritesOnly))
            return items.filter { item in
                guard let id = item.deviceAssetID, !uploaded.contains(id) else { return false }
                return !favoritesOnly || item.isFavorite
            }
        }
    }

    private func deviceItem(_ localID: String, _ fileCreatedAt: String, favorite: Bool = false) -> AssetReactItem {
        AssetReactItem(
            id: AssetReactItem.deviceIDPrefix + localID, ownerId: "", ratio: 1, isFavorite: favorite,
            visibility: "timeline", isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: fileCreatedAt, fileCreatedAt: fileCreatedAt, localOffsetHours: 0, duration: nil,
            livePhotoVideoId: nil, projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil,
            stack: [], deviceAssetID: localID
        )
    }

    private func serverItem(_ id: String, _ fileCreatedAt: String) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1, isFavorite: false, visibility: "timeline", isTrashed: false,
            isImage: true, thumbhash: nil, createdAt: fileCreatedAt, fileCreatedAt: fileCreatedAt,
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, projectionType: nil, city: nil,
            country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func columnar(_ ids: [String], at fileCreatedAt: String) -> TimeBucketAssetResponseDto {
        TimeBucketAssetResponseDto(
            id: ids, ownerId: ids.map { _ in "owner" }, ratio: ids.map { _ in 1.0 },
            isFavorite: ids.map { _ in false }, visibility: ids.map { _ in "timeline" },
            isTrashed: ids.map { _ in false }, isImage: ids.map { _ in true }, thumbhash: ids.map { _ in nil },
            createdAt: ids.map { _ in fileCreatedAt }, fileCreatedAt: ids.map { _ in fileCreatedAt },
            localOffsetHours: ids.map { _ in 0.0 }, duration: ids.map { _ in nil },
            livePhotoVideoId: ids.map { _ in nil }, projectionType: ids.map { _ in nil },
            stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
        )
    }

    // MARK: - Pure arithmetic

    func test_deviceIDs_neverReadAsServerIDs() {
        let item = deviceItem("ABC-123/L0/001", "2024-07-01T10:00:00.000Z")
        XCTAssertTrue(item.isDeviceOnly)
        XCTAssertEqual(item.id, "device:ABC-123/L0/001")
        XCTAssertEqual(AssetReactItem.deviceAssetID(fromID: item.id), "ABC-123/L0/001")
        XCTAssertTrue(AssetReactItem.isDeviceOnlyID(item.id))
        XCTAssertNil(AssetReactItem.deviceAssetID(fromID: "5c7ab000-2024-4007-8111-000000000001"))
        XCTAssertFalse(serverItem("s1", "2024-07-01T10:00:00.000Z").isDeviceOnly)
        // A copy keeps it: a favorite or visibility patch must not turn it into a server item.
        XCTAssertEqual(item.with(isFavorite: true).deviceAssetID, "ABC-123/L0/001")
        XCTAssertEqual(item.with(visibility: "timeline").deviceAssetID, "ABC-123/L0/001")
    }

    func test_buckets_addTheDeviceCountsAndInsertDeviceOnlyMonths() {
        let server = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-05-01", count: 3),
        ]
        let merged = MergedTimeline.buckets(server: server, deviceCounts: ["2024-07": 1, "2024-06": 4])
        XCTAssertEqual(merged.map(\.timeBucket), ["2024-07-01", "2024-06-01", "2024-05-01"], "newest first")
        XCTAssertEqual(merged.map(\.count), [3, 4, 3])
        XCTAssertEqual(MergedTimeline.buckets(server: server, deviceCounts: [:]), server)
    }

    func test_items_mixNewestFirst() {
        let server = [serverItem("s1", "2024-07-20T10:00:00.000Z"), serverItem("s2", "2024-07-02T10:00:00.000Z")]
        let device = [deviceItem("d1", "2024-07-10T10:00:00.000Z")]
        XCTAssertEqual(MergedTimeline.items(server: server, device: device).map(\.id), ["s1", "device:d1", "s2"])
    }

    // MARK: - The Photos tab's view model

    @MainActor
    private func makeVM(
        _ mock: MockImmichClient, device: [AssetReactItem], uploaded: Set<String>
    ) -> (TimelineViewModel, ScriptedDeviceSource) {
        let source = ScriptedDeviceSource(device)
        let vm = TimelineViewModel(client: mock)
        vm.deviceSource = source
        vm.uploadedDeviceIDs = { uploaded }
        return (vm, source)
    }

    @MainActor
    func test_deviceMonthIsMergedAndNeverAskedOfTheServer() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)]
        mock.bucketResponses = ["2024-07-01": columnar(["s1"], at: "2024-07-05T10:00:00.000Z")]
        let (vm, _) = makeVM(mock, device: [
            deviceItem("new", "2024-08-01T09:00:00.000Z"),
            deviceItem("july", "2024-07-09T09:00:00.000Z"),
            deviceItem("sent", "2024-07-08T09:00:00.000Z"),
        ], uploaded: ["sent"])

        await vm.load()
        XCTAssertEqual(vm.buckets.map(\.timeBucket), ["2024-08-01", "2024-07-01"])
        XCTAssertEqual(vm.buckets.map(\.count), [1, 2], "the backed-up photo is counted once, by its server copy")
        XCTAssertEqual(vm.items.map(\.id), ["device:new"])
        XCTAssertTrue(mock.timeBucketCalls.isEmpty, "a month only the device has is not asked of the server")

        await vm.loadMore()
        XCTAssertEqual(vm.items.map(\.id), ["device:new", "device:july", "s1"])
        XCTAssertEqual(mock.timeBucketCalls.map(\.timeBucket), ["2024-07-01"])
    }

    /// A photo the server has without the ledger knowing it (sent by another
    /// app, or before this install) is shown once — by its server copy —
    /// from the very first launch, with no backup pass needed.
    @MainActor
    func test_withoutTheLedger_serverCopyIsRecognisedByCaptureTime() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1)]
        mock.bucketResponses = ["2024-07-01": columnar(["s1"], at: "2024-07-05T10:00:00.000Z")]
        let (vm, _) = makeVM(mock, device: [
            deviceItem("same", "2024-07-05T10:00:00.250Z"),
            deviceItem("other", "2024-07-09T09:00:00.000Z"),
        ], uploaded: [])
        await vm.load()
        XCTAssertEqual(vm.items.map(\.id), ["device:other", "s1"])
    }

    /// The server's copy can sit in the next month the server sends (a photo
    /// taken near midnight on the 1st): the device photo shown earlier leaves.
    @MainActor
    func test_serverCopyInALaterMonth_prunesTheDevicePhoto() async {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-08-01", count: 1),
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 1),
        ]
        mock.bucketResponses = [
            "2024-08-01": columnar(["aug"], at: "2024-08-10T10:00:00.000Z"),
            "2024-07-01": columnar(["edge"], at: "2024-08-01T02:30:00.000Z"),
        ]
        let (vm, _) = makeVM(mock, device: [deviceItem("edge", "2024-08-01T02:30:00.000Z")], uploaded: [])
        await vm.load()
        XCTAssertEqual(Set(vm.items.map(\.id)), ["aug", "device:edge"])
        await vm.loadMore()
        XCTAssertEqual(Set(vm.items.map(\.id)), ["aug", "edge"], "shown once, by its server copy")
        XCTAssertEqual(vm.loadedIds, Set(vm.items.map(\.id)))
    }

    func test_dedupeKey_kindAndSecond() {
        let photo = deviceItem("a", "2024-07-05T10:00:00.250Z")
        XCTAssertEqual(MergedTimeline.dedupeKey(photo), MergedTimeline.dedupeKey(serverItem("s", "2024-07-05T10:00:00.000Z")))
        XCTAssertNotEqual(MergedTimeline.dedupeKey(photo), MergedTimeline.dedupeKey(serverItem("s", "2024-07-05T10:00:01.000Z")))
    }

    @MainActor
    func test_filters_archivedHasNoDevicePhotos_favoritesOnlyItsFavorites() async {
        let mock = MockImmichClient()
        let (vm, source) = makeVM(mock, device: [
            deviceItem("fav", "2024-07-09T09:00:00.000Z", favorite: true),
            deviceItem("plain", "2024-07-08T09:00:00.000Z"),
        ], uploaded: ["other"])

        await vm.setFilter(.favorites)
        XCTAssertEqual(vm.items.map(\.id), ["device:fav"])
        XCTAssertEqual(source.calls.last?.favoritesOnly, true)

        await vm.setFilter(.archived)
        XCTAssertTrue(vm.items.isEmpty)
    }

    @MainActor
    func test_switchedOff_theTimelineIsTheServersAlone() async {
        let mock = MockImmichClient()
        let (vm, source) = makeVM(mock, device: [deviceItem("d1", "2024-07-09T09:00:00.000Z")], uploaded: ["x"])
        vm.showsDeviceAssets = { false }
        await vm.load()
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertTrue(source.calls.isEmpty, "the library is not even read")
    }

    @MainActor
    func test_devicePhotosAreNotSelectable() {
        let vm = TimelineViewModel(client: MockImmichClient())
        vm.enterSelectionMode()
        vm.toggleSelection(id: "device:d1")
        XCTAssertTrue(vm.selectedIds.isEmpty, "the batch actions send server ids only")
        vm.toggleSelection(id: "s1")
        XCTAssertEqual(vm.selectedIds, ["s1"])
    }

    // MARK: - Viewer

    func test_viewerActions_devicePhoto_shareBackUpDeleteOnly() {
        let actions = ViewerActions(
            asset: deviceItem("d1", "2024-07-09T09:00:00.000Z"), visibility: "timeline", isTrash: false, currentUserId: "me"
        )
        XCTAssertTrue(actions.showsShare)
        XCTAssertTrue(actions.showsBackUp)
        XCTAssertTrue(actions.showsDelete)
        XCTAssertFalse(actions.showsFavorite)
        XCTAssertFalse(actions.showsEdit)
        XCTAssertNil(actions.archive)
        XCTAssertFalse(actions.allowsInfoEdits)

        let server = ViewerActions(
            asset: serverItem("s1", "2024-07-09T09:00:00.000Z"), visibility: "timeline", isTrash: false, currentUserId: "owner"
        )
        XCTAssertFalse(server.showsBackUp)
    }

    // MARK: - Server ↔ device bridge

    @MainActor
    func test_ledgerBridge_serverIDToLibraryID() {
        let ledger = BackupLedger.inMemory()
        ledger.markBackedUp(id: "local-1", signature: "s", checksum: "c", serverAssetId: "server-1")
        ledger.markBackedUp(id: "local-2", signature: "s", checksum: "c", serverAssetId: nil)
        XCTAssertEqual(ledger.localIDsByServerID(), ["server-1": "local-1"])

        let index = CloudBackupStatusIndex()
        index.refresh(ledger: ledger, editLedger: BackupEditLedger.inMemory())
        XCTAssertEqual(index.localID(forServerAssetID: "server-1"), "local-1")
        XCTAssertNil(index.localID(forServerAssetID: "unknown"))
    }
}
