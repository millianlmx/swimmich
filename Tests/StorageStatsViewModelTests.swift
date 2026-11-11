import XCTest
@testable import ImmichSwiftUI

/// Account storage (L-01, B-3): usage and quota from `GET /api/users/me`, own
/// counts from `GET /api/assets/statistics`. Instance totals
/// (`GET /api/server/statistics`) are never read by these view models.
final class StorageStatsViewModelTests: XCTestCase {

    private let hundredGiB = 107_374_182_400
    private let twentyGiB = 21_474_836_480

    private func makeUser(quota: Int?, usage: Int?) -> UserAdminResponseDto {
        UserAdminResponseDto(
            id: "me", name: "Me", email: "me@example.com",
            quotaSizeInBytes: quota, quotaUsageInBytes: usage
        )
    }

    private func makeMock(quota: Int? = nil, usage: Int? = nil, images: Int = 128, videos: Int = 7) -> MockImmichClient {
        let mock = MockImmichClient()
        mock.getMyUserResponse = makeUser(quota: quota ?? hundredGiB, usage: usage ?? twentyGiB)
        mock.assetStatisticsResponse = AssetStatsResponseDto(images: images, videos: videos, total: images + videos + 5)
        return mock
    }

    private let serverError = APIError.serverError(500, "x")

    @MainActor
    func test_AC_67_load_readsUsageQuotaAndOwnCounts() async {
        let mock = makeMock()
        let vm = StorageStatsViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.usage, .loaded(.init(usedBytes: Int64(twentyGiB), quotaBytes: Int64(hundredGiB))))
        guard case .loaded(let usage) = vm.usage else { return XCTFail("usage not loaded") }
        XCTAssertEqual(try XCTUnwrap(usage.fraction), 0.2, accuracy: 1e-9)
        // `total` (140 + audio/other) is never what is shown.
        XCTAssertEqual(vm.counts, .loaded(.init(photos: 128, videos: 7)))
        XCTAssertEqual(mock.serverStatisticsCallCount, 0)
        XCTAssertEqual(mock.getMyUserCallCount, 1)
        XCTAssertEqual(mock.assetStatisticsCallCount, 1)
    }

    func test_AC_67_format_isTheSharedDecimalFormatter() {
        XCTAssertEqual(StorageStatsViewModel.format(21_474_836_480).filter(\.isNumber), "2147")
        XCTAssertEqual(StorageStatsViewModel.format(107_374_182_400).filter(\.isNumber), "10737")
    }

    @MainActor
    func test_AC_68_nilOrZeroQuota_isUnlimited() async {
        let mock = makeMock()
        let vm = StorageStatsViewModel(client: mock)
        for quota in [nil, 0] as [Int?] {
            mock.getMyUserResponse = makeUser(quota: quota, usage: 5_000)
            await vm.load()
            guard case .loaded(let usage) = vm.usage else { return XCTFail("usage not loaded for quota \(String(describing: quota))") }
            XCTAssertNil(usage.quotaBytes)
            XCTAssertNil(usage.fraction)
            XCTAssertEqual(usage.usedBytes, 5_000)
        }
    }

    @MainActor
    func test_AC_70_countsFail_usageShown_countsUnavailable() async {
        let mock = makeMock()
        mock.assetStatisticsError = serverError
        let vm = StorageStatsViewModel(client: mock)

        await vm.load()

        guard case .loaded = vm.usage else { return XCTFail("usage must be shown") }
        XCTAssertEqual(vm.counts, .unavailable(message: UserFacingError.serverErrorMessage))

        mock.assetStatisticsError = nil
        await vm.load()
        XCTAssertEqual(vm.counts, .loaded(.init(photos: 128, videos: 7)))
    }

    @MainActor
    func test_AC_70_usageFails_countsShown_usageUnavailable() async {
        let mock = makeMock()
        mock.getMyUserError = serverError
        let vm = StorageStatsViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.usage, .unavailable(message: UserFacingError.serverErrorMessage))
        XCTAssertEqual(vm.counts, .loaded(.init(photos: 128, videos: 7)))

        mock.getMyUserError = nil
        await vm.load()
        guard case .loaded = vm.usage else { return XCTFail("usage must be read again") }
    }

    @MainActor
    func test_AC_71_refreshFailure_dropsOldValue_otherPartRefreshes() async {
        let mock = makeMock()
        let vm = StorageStatsViewModel(client: mock)
        await vm.load()
        guard case .loaded = vm.usage else { return XCTFail("first read must succeed") }

        mock.getMyUserError = serverError
        mock.assetStatisticsResponse = AssetStatsResponseDto(images: 130, videos: 8, total: 140)
        await vm.load()

        XCTAssertEqual(vm.usage, .unavailable(message: UserFacingError.serverErrorMessage))
        XCTAssertEqual(vm.counts, .loaded(.init(photos: 130, videos: 8)))
    }

    @MainActor
    func test_AC_71_cancellation_keepsWhatWasShown() async {
        let cancellations: [Error] = [
            CancellationError(),
            URLError(.cancelled),
            APIError.network(URLError(.cancelled)),
        ]
        for cancellation in cancellations {
            for cancelUsage in [true, false] {
                // After a successful read: the cancelled half keeps its value, the other updates.
                let mock = makeMock()
                let vm = StorageStatsViewModel(client: mock)
                await vm.load()
                let oldUsage = vm.usage
                let oldCounts = vm.counts
                if cancelUsage { mock.getMyUserError = cancellation } else { mock.assetStatisticsError = cancellation }
                mock.getMyUserResponse = makeUser(quota: nil, usage: 1)
                mock.assetStatisticsResponse = AssetStatsResponseDto(images: 1, videos: 2, total: 3)
                await vm.load()
                if cancelUsage {
                    XCTAssertEqual(vm.usage, oldUsage, "\(cancellation)")
                    XCTAssertEqual(vm.counts, .loaded(.init(photos: 1, videos: 2)), "\(cancellation)")
                } else {
                    XCTAssertEqual(vm.counts, oldCounts, "\(cancellation)")
                    XCTAssertEqual(vm.usage, .loaded(.init(usedBytes: 1, quotaBytes: nil)), "\(cancellation)")
                }

                // On a fresh view model: the cancelled half stays "not loaded", never "unavailable".
                let fresh = makeMock()
                if cancelUsage { fresh.getMyUserError = cancellation } else { fresh.assetStatisticsError = cancellation }
                let freshVM = StorageStatsViewModel(client: fresh)
                await freshVM.load()
                if cancelUsage {
                    XCTAssertEqual(freshVM.usage, .notLoaded, "\(cancellation)")
                } else {
                    XCTAssertEqual(freshVM.counts, .notLoaded, "\(cancellation)")
                }
            }
        }
    }

    @MainActor
    func test_load_isNotReentrant() async {
        let mock = makeMock()
        mock.getMyUserGate = { try? await Task.sleep(nanoseconds: 200_000_000) }
        let vm = StorageStatsViewModel(client: mock)

        async let first: Void = vm.load()
        // Let the first load reach the gate before the second call.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await vm.load()
        await first

        XCTAssertEqual(mock.getMyUserCallCount, 1)
        XCTAssertEqual(mock.assetStatisticsCallCount, 1)
    }
}

/// Media Stats keeps its device half and reads the account, never the instance.
@MainActor
final class MediaStatsViewModelTests: XCTestCase {

    private var folder: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-stats-tests-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "media-stats-tests-\(UUID().uuidString)")!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func makeSUT(client: MockImmichClient) -> (MediaStatsViewModel, BackupLedger) {
        let ledger = BackupLedger.inMemory()
        let store = OfflineAssetStore(rootURL: folder, transport: MockFileDownloadTransport(), defaults: defaults)
        store.setActiveAccount(OfflineAssetStoreTests.accountA, otherAccountsRegistered: false)
        let offline = OfflineDownloadViewModel(
            store: store, client: client, index: OfflineAssetIndex(), accountID: OfflineAssetStoreTests.accountA
        )
        return (MediaStatsViewModel(client: client, ledger: ledger, offline: offline), ledger)
    }

    func test_AC_5_mediaStats_readsTheAccountNotTheInstance() async {
        let mock = MockImmichClient()
        mock.getMyUserResponse = UserAdminResponseDto(
            id: "me", name: "Me", email: "me@example.com",
            quotaSizeInBytes: 1_000_000, quotaUsageInBytes: 123_456
        )
        mock.assetStatisticsResponse = AssetStatsResponseDto(images: 12, videos: 3, total: 20)
        let (vm, _) = makeSUT(client: mock)

        await vm.load()

        XCTAssertEqual(vm.storage.usage, .loaded(.init(usedBytes: 123_456, quotaBytes: 1_000_000)))
        XCTAssertEqual(vm.storage.counts, .loaded(.init(photos: 12, videos: 3)))
        XCTAssertEqual(mock.serverStatisticsCallCount, 0)
    }

    func test_AC_72_mediaStats_serverDown_keepsLocalHalf() async {
        let mock = MockImmichClient()
        mock.globalError = APIError.network(URLError(.notConnectedToInternet))
        let (vm, ledger) = makeSUT(client: mock)
        let tracked = ledger.trackedCount()

        await vm.load()

        XCTAssertEqual(vm.storage.usage, .unavailable(message: UserFacingError.offlineMessage))
        XCTAssertEqual(vm.storage.counts, .unavailable(message: UserFacingError.offlineMessage))
        XCTAssertEqual(vm.trackedCount, tracked)
        XCTAssertEqual(vm.offlineCount, 0)
        XCTAssertEqual(vm.offlineBytes, 0)
    }
}

/// Administration reads the instance totals on their own (L-01, AC-73).
@MainActor
final class AdminInstanceStatsTests: XCTestCase {

    private let serverError = APIError.serverError(500, "x")

    private func makeStats() -> ServerStatsResponseDto {
        ServerStatsResponseDto(
            photos: 900, videos: 90, usage: 999_000_000_000,
            usagePhotos: 800_000_000_000, usageVideos: 199_000_000_000, usageByUser: []
        )
    }

    func test_AC_73_loadInstanceStats_success() async {
        let mock = MockImmichClient()
        mock.serverStatisticsResponse = makeStats()
        let vm = AdminViewModel(client: mock)

        await vm.loadInstanceStats()

        XCTAssertEqual(vm.instanceStats, makeStats())
        XCTAssertNil(vm.instanceStatsError)
        XCTAssertFalse(vm.isLoadingInstanceStats)
    }

    func test_AC_73_failure_isIsolatedFromOtherSections() async {
        let mock = MockImmichClient()
        mock.serverStatisticsError = serverError
        mock.adminUsersResponse = [UserAdminResponseDto(id: "u1", name: "Other User", email: "o@example.com")]
        mock.jobsStatusResponse = [
            "thumbnailGeneration": QueueResponseLegacyDto(
                queueStatus: QueueStatusLegacyDto(isActive: false, isPaused: false),
                jobCounts: QueueStatisticsDto(active: 0, completed: 12, failed: 0, delayed: 0, waiting: 3, paused: 0)
            )
        ]
        mock.librariesResponse = [LibraryResponseDto(id: "lib-1", ownerId: "me", name: "Stub Library")]
        let vm = AdminViewModel(client: mock)

        await vm.loadInstanceStats()
        XCTAssertEqual(vm.instanceStatsError, UserFacingError.serverErrorMessage)
        XCTAssertNil(vm.instanceStats)

        await vm.load()
        XCTAssertEqual(vm.users.count, 1)
        XCTAssertEqual(vm.jobs.count, 1)
        XCTAssertEqual(vm.libraries.count, 1)
        XCTAssertNil(vm.errorMessage)

        mock.serverStatisticsError = nil
        mock.serverStatisticsResponse = makeStats()
        await vm.loadInstanceStats()
        XCTAssertEqual(vm.instanceStats, makeStats())
        XCTAssertNil(vm.instanceStatsError)
    }

    func test_AC_73_refresh_readsTotalsAndSectionsTogether() async {
        let mock = MockImmichClient()
        mock.serverStatisticsResponse = makeStats()
        mock.adminUsersResponse = [UserAdminResponseDto(id: "u1", name: "Other User", email: "o@example.com")]
        let vm = AdminViewModel(client: mock)

        await vm.refresh()

        XCTAssertEqual(vm.instanceStats, makeStats())
        XCTAssertEqual(vm.users.count, 1)
        XCTAssertEqual(mock.serverStatisticsCallCount, 1)
    }

    func test_AC_73_cancellation_keepsPreviousStats() async {
        let mock = MockImmichClient()
        mock.serverStatisticsResponse = makeStats()
        let vm = AdminViewModel(client: mock)
        await vm.loadInstanceStats()

        mock.serverStatisticsError = CancellationError()
        await vm.loadInstanceStats()

        XCTAssertEqual(vm.instanceStats, makeStats())
        XCTAssertNil(vm.instanceStatsError)
    }
}
