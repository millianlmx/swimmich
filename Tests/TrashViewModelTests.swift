import XCTest
@testable import ImmichSwiftUI

@MainActor
final class TrashViewModelTests: XCTestCase {

    /// Columnar bucket helper with isTrashed=true (trash semantics).
    private func columnar(ids: [String]) -> TimeBucketAssetResponseDto {
        TimeBucketAssetResponseDto(
            id: ids,
            ownerId: ids.map { _ in "owner" },
            ratio: ids.map { _ in 1.0 },
            isFavorite: ids.map { _ in false },
            visibility: ids.map { _ in "timeline" },
            isTrashed: ids.map { _ in true }, // trash items
            isImage: ids.map { _ in true },
            thumbhash: ids.map { _ in nil },
            createdAt: ids.map { _ in "2024-07-01T00:00:00.000Z" },
            fileCreatedAt: ids.map { _ in "2024-07-01T00:00:00.000Z" },
            localOffsetHours: ids.map { _ in 0.0 },
            duration: ids.map { _ in nil },
            livePhotoVideoId: ids.map { _ in nil },
            projectionType: ids.map { _ in nil },
            stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
        )
    }

    private func makeMock() -> MockImmichClient {
        let mock = MockImmichClient()
        mock.bucketsResponse = [
            TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2),
            TimeBucketsResponseDto(timeBucket: "2024-06-01", count: 2)
        ]
        mock.bucketResponses = [
            "2024-07-01": columnar(ids: ["a1", "a2"]),
            "2024-06-01": columnar(ids: ["a3", "a4"])
        ]
        return mock
    }

    // MARK: - AC-300: load() filters isTrashed=true + error path

    func test_AC_300_load_uses_trash_filter() async {
        let mock = makeMock()
        let vm = TrashViewModel(client: mock)
        await vm.load()

        XCTAssertEqual(mock.lastTimeBucketsIsTrashed, true, "load must request trashed buckets")
        XCTAssertTrue(vm.items.allSatisfy { $0.isTrashed }, "every item must be trashed")
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertEqual(Set(vm.items.map(\.id)), ["a1", "a2"])
        XCTAssertFalse(vm.isLoading)
    }

    func test_AC_300_load_error_preserves_state() async {
        let mock = makeMock()
        struct Boom: Error {}
        mock.globalError = Boom()
        let vm = TrashViewModel(client: mock)
        await vm.load()

        XCTAssertTrue(vm.items.isEmpty, "items empty on error")
        XCTAssertTrue(vm.buckets.isEmpty)
        XCTAssertEqual(vm.loadErrorMessage, localizedString("Something went wrong. Please try again."))
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - AC-301: restore(id:) success + error path

    func test_AC_301_restore_single() async {
        let mock = makeMock()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.items.count, 2)

        await vm.restore(id: "a1")

        XCTAssertEqual(mock.lastRestoreTrashAssetsIds, ["a1"])
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.items.first?.id, "a2")
        XCTAssertFalse(vm.loadedIds.contains("a1"))
    }

    // MARK: - AC-302: restoreAll() success path

    func test_AC_302_restore_all() async {
        let mock = makeMock()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 4)
        XCTAssertFalse(vm.buckets.isEmpty)

        await vm.restoreAll()

        XCTAssertEqual(mock.restoreAllTrashCallCount, 1)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertTrue(vm.loadedIds.isEmpty)
        XCTAssertTrue(vm.buckets.isEmpty)
        XCTAssertEqual(vm.bucketIndex, 0)
    }

    // MARK: - AC-302b: restoreAll() error path preserves state

    func test_AC_302b_restore_all_error_preserves_state() async {
        let mock = makeMock()
        struct Boom: Error {}
        mock.restoreAllTrashError = Boom()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        let itemsBefore = vm.items.count
        let bucketsBefore = vm.buckets.count
        let loadedBefore = vm.loadedIds
        let indexBefore = vm.bucketIndex

        await vm.restoreAll()

        XCTAssertEqual(mock.restoreAllTrashCallCount, 1)
        XCTAssertEqual(vm.items.count, itemsBefore, "items preserved on throw")
        XCTAssertEqual(vm.buckets.count, bucketsBefore)
        XCTAssertEqual(vm.loadedIds, loadedBefore)
        XCTAssertEqual(vm.bucketIndex, indexBefore)
        XCTAssertEqual(vm.actionErrorMessage, localizedString("Something went wrong. Please try again."))
    }

    // MARK: - AC-303: deletePermanently(id:) success

    func test_AC_303_delete_permanently_single() async {
        let mock = makeMock()
        let vm = TrashViewModel(client: mock)
        await vm.load()

        await vm.deletePermanently(id: "a2")

        XCTAssertEqual(mock.lastDeleteBody?.ids, ["a2"])
        XCTAssertEqual(mock.lastDeleteBody?.force, true, "permanent delete requires force:true")
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.items.first?.id, "a1")
        XCTAssertFalse(vm.loadedIds.contains("a2"))
    }

    // MARK: - AC-304: emptyTrash() success path — clears ALL state

    func test_AC_304_empty_trash() async {
        let mock = makeMock()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        await vm.loadMore()
        XCTAssertFalse(vm.items.isEmpty)
        XCTAssertFalse(vm.buckets.isEmpty)
        XCTAssertGreaterThan(vm.bucketIndex, 0)

        await vm.emptyTrash()

        XCTAssertEqual(mock.emptyTrashCallCount, 1)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertTrue(vm.loadedIds.isEmpty)
        XCTAssertTrue(vm.buckets.isEmpty)
        XCTAssertEqual(vm.bucketIndex, 0)
    }

    // MARK: - AC-304b: emptyTrash() error path preserves EVERY field

    func test_AC_304b_empty_trash_error_preserves_all() async {
        let mock = makeMock()
        struct Boom: Error {}
        mock.emptyTrashError = Boom()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        await vm.loadMore()
        let itemsBefore = vm.items.count
        let bucketsBefore = vm.buckets.count
        let loadedBefore = vm.loadedIds
        let indexBefore = vm.bucketIndex

        await vm.emptyTrash()

        XCTAssertEqual(mock.emptyTrashCallCount, 1)
        XCTAssertEqual(vm.items.count, itemsBefore, "items preserved")
        XCTAssertEqual(vm.buckets.count, bucketsBefore, "buckets preserved")
        XCTAssertEqual(vm.loadedIds, loadedBefore, "loadedIds preserved")
        XCTAssertEqual(vm.bucketIndex, indexBefore, "bucketIndex preserved")
        XCTAssertEqual(vm.actionErrorMessage, localizedString("Something went wrong. Please try again."))
    }

    // MARK: - AC-305: refresh() resets + first bucket only + error path

    func test_AC_305_refresh_trash() async {
        let mock = makeMock()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 4)

        await vm.refresh()

        XCTAssertEqual(mock.lastTimeBucketsIsTrashed, true, "refresh must keep trash filter")
        XCTAssertEqual(vm.items.count, 2, "refresh loads only the first bucket")
        XCTAssertEqual(Set(vm.items.map(\.id)), ["a1", "a2"])
        XCTAssertTrue(vm.canLoadMore)
    }

    func test_AC_305b_refresh_error_preserves_state() async {
        let mock = makeMock()
        struct Boom: Error {}
        let vm = TrashViewModel(client: mock)
        await vm.load()
        let beforeCount = vm.items.count
        mock.globalError = Boom()

        await vm.refresh()

        // Throw at getTimeBuckets happens BEFORE any mutation, so prior state
        // is preserved; only loadErrorMessage is set.
        XCTAssertEqual(vm.loadErrorMessage, localizedString("Something went wrong. Please try again."))
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.items.count, beforeCount, "items preserved on refresh error")
        XCTAssertFalse(vm.buckets.isEmpty, "buckets preserved on refresh error")
    }

    // MARK: - AC-306: loadMore() no duplicates

    func test_AC_306_loadMore_no_duplicates() async {
        let mock = makeMock()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 4)
        XCTAssertEqual(Set(vm.items.map(\.id)).count, 4, "no duplicate ids")
        XCTAssertEqual(vm.loadedIds.count, vm.items.count)

        // loadMore past the last bucket is a no-op.
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 4)
        XCTAssertFalse(vm.canLoadMore)
    }

    // MARK: - AC-307: VM dispatches POST /trash/restore/assets via client.restoreTrashAssets

    func test_AC_307_api_restore_assets() async {
        let mock = makeMock()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        await vm.restore(id: "a1")
        XCTAssertEqual(mock.lastRestoreTrashAssetsIds, ["a1"], "client.restoreTrashAssets must receive the id")
    }

    // MARK: - AC-308: VM dispatches POST /trash/restore via client.restoreAllTrash

    func test_AC_308_api_restore_all() async {
        let mock = makeMock()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        await vm.restoreAll()
        XCTAssertEqual(mock.restoreAllTrashCallCount, 1, "client.restoreAllTrash must be invoked exactly once")
    }

    // MARK: - AC-309: VM dispatches POST /trash/empty via client.emptyTrash

    func test_AC_309_api_empty_trash() async {
        let mock = makeMock()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        await vm.emptyTrash()
        XCTAssertEqual(mock.emptyTrashCallCount, 1, "client.emptyTrash must be invoked exactly once")
    }

    // MARK: - AC-313: restore(id:) error preserves state

    func test_AC_313_restore_error_preserves_state() async {
        let mock = makeMock()
        struct Boom: Error {}
        mock.restoreTrashAssetsError = Boom()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        let itemsBefore = vm.items.count
        let loadedBefore = vm.loadedIds

        await vm.restore(id: "a1")

        XCTAssertEqual(mock.lastRestoreTrashAssetsIds, ["a1"], "call still fired")
        XCTAssertEqual(vm.items.count, itemsBefore, "items unchanged on throw")
        XCTAssertEqual(vm.loadedIds, loadedBefore, "loadedIds unchanged on throw")
        XCTAssertEqual(vm.actionErrorMessage, localizedString("Something went wrong. Please try again."))
    }

    // MARK: - AC-314: deletePermanently(id:) error preserves state

    func test_AC_314_delete_permanent_error_preserves_state() async {
        let mock = makeMock()
        struct Boom: Error {}
        mock.deleteError = Boom()
        let vm = TrashViewModel(client: mock)
        await vm.load()
        let itemsBefore = vm.items.count
        let loadedBefore = vm.loadedIds

        await vm.deletePermanently(id: "a2")

        XCTAssertEqual(mock.lastDeleteBody?.ids, ["a2"])
        XCTAssertEqual(mock.lastDeleteBody?.force, true)
        XCTAssertEqual(vm.items.count, itemsBefore, "items unchanged on throw")
        XCTAssertEqual(vm.loadedIds, loadedBefore, "loadedIds unchanged on throw")
        XCTAssertEqual(vm.actionErrorMessage, localizedString("Something went wrong. Please try again."))
    }
}
