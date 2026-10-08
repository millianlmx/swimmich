import XCTest
@testable import ImmichSwiftUI

final class StorageStatsViewModelTests: XCTestCase {

    private func makeStats(
        photos: Int = 10,
        videos: Int = 3,
        usage: Int = 123_456,
        quota: Int = 1_000_000
    ) -> ServerStatsResponseDto {
        ServerStatsResponseDto(
            photos: photos,
            videos: videos,
            usage: usage,
            usagePhotos: usage / 2,
            usageVideos: usage / 2,
            usageByUser: [
                UsageByUserDto(
                    userId: "u1", userName: "me", photos: photos, videos: videos,
                    usage: usage, usagePhotos: usage / 2, usageVideos: usage / 2,
                    quotaSizeInBytes: quota
                )
            ]
        )
    }

    // P1 storage-stats: success maps photos/videos/usage + quota from the
    // first usageByUser entry carrying a quota.
    @MainActor
    func test_storageStats_success_mapsUsageAndQuota() async {
        let mock = MockImmichClient()
        mock.serverStatisticsResponse = makeStats(photos: 10, videos: 3, usage: 123_456, quota: 1_000_000)
        let vm = StorageStatsViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.photos, 10)
        XCTAssertEqual(vm.videos, 3)
        XCTAssertEqual(vm.usage, 123_456)
        XCTAssertEqual(vm.quotaSizeInBytes, 1_000_000)
        XCTAssertTrue(vm.didLoad)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    // P1 storage-stats: no quota entry (or quota 0) → quota stays nil so the
    // view skips the quota bar.
    @MainActor
    func test_storageStats_zeroQuotaLeavesQuotaNil() async {
        let mock = MockImmichClient()
        mock.serverStatisticsResponse = makeStats(quota: 0)
        let vm = StorageStatsViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.usage, 123_456)
        XCTAssertNil(vm.quotaSizeInBytes)
    }

    @MainActor
    func test_storageStats_defaultResponse_noQuotaNoCrash() async {
        let mock = MockImmichClient()
        let vm = StorageStatsViewModel(client: mock)

        await vm.load()

        XCTAssertTrue(vm.didLoad)
        XCTAssertEqual(vm.photos, 0)
        XCTAssertNil(vm.quotaSizeInBytes)
        XCTAssertNil(vm.errorMessage)
    }

    // P1 storage-stats: failure surfaces in errorMessage, usage untouched,
    // didLoad stays false (view can retry).
    @MainActor
    func test_storageStats_failure_setsError() async {
        let mock = MockImmichClient()
        mock.globalError = APIError.serverError(500, "boom")
        let vm = StorageStatsViewModel(client: mock)

        await vm.load()

        XCTAssertFalse(vm.didLoad)
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
        XCTAssertEqual(vm.usage, 0)
        XCTAssertFalse(vm.isLoading)
    }

    // P1 storage-stats: re-entrancy guard — a second load while in flight is
    // refused (no duplicate fetch).
    @MainActor
    func test_storageStats_loadIsNotReentrant() async {
        let mock = MockImmichClient()
        mock.serverStatisticsResponse = makeStats()
        // Gate holds the first load in flight so the second call deterministically
        // hits the isLoading guard (async-let alone was racy: the mock can
        // complete before the second call ever starts).
        mock.statisticsGate = { try? await Task.sleep(nanoseconds: 200_000_000) }
        let vm = StorageStatsViewModel(client: mock)

        async let first: Void = vm.load()
        await vm.load()
        await first

        XCTAssertEqual(mock.requestCount, 1)
    }

    // P1 storage-stats: locale-safe formatting (en "MB" / fr "Mo").
    @MainActor
    func test_storageStats_formatByteSizes() {
        let mb = StorageStatsViewModel.format(1_048_576).uppercased()
        XCTAssertTrue(mb.contains("MB") || mb.contains("MO"))

        let gb = StorageStatsViewModel.format(1_073_741_824).uppercased()
        XCTAssertTrue(gb.contains("GB") || gb.contains("GO"))
    }
}