import XCTest
@testable import ImmichSwiftUI

/// The "Advanced" section's log level and image cache (B-31). The cache is a
/// scripted double: it answers a queue of measurements (or failures) and counts
/// its emptyings, so the model's rules — measure, never assume, never write a
/// zero of its own — are what is under test.
@MainActor
final class AdvancedSettingsViewModelTests: XCTestCase {

    private enum MeasureError: Error { case unreadable }

    private final class MockImageCache: ImageCacheManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [Result<Int64, Error>]
        private var _clearCount = 0

        /// Once the queue is exhausted the last answer repeats.
        init(_ readings: [Result<Int64, Error>]) {
            self.readings = readings
        }

        var clearCount: Int { lock.lock(); defer { lock.unlock() }; return _clearCount }

        func diskUsageBytes() async throws -> Int64 {
            lock.lock()
            let next = readings.count > 1 ? readings.removeFirst() : readings[0]
            lock.unlock()
            return try next.get()
        }

        func clear() async {
            lock.lock(); _clearCount += 1; lock.unlock()
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AdvancedSettingsViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeViewModel(
        _ cache: MockImageCache, attempts: Int = 3
    ) -> AdvancedSettingsViewModel {
        AdvancedSettingsViewModel(
            log: AppLogStore(defaults: defaults), imageCache: cache,
            rereadAttempts: attempts, rereadInterval: .zero
        )
    }

    // MARK: - Emptying

    func test_AC_52_clearDropsToZeroAndSucceeds() async {
        let cache = MockImageCache([.success(150_400_000), .success(0)])
        let vm = makeViewModel(cache)
        await vm.loadImageCacheSize()
        XCTAssertEqual(vm.imageCacheBytes, 150_400_000)

        await vm.clearImageCache()

        XCTAssertEqual(cache.clearCount, 1)
        XCTAssertEqual(vm.imageCacheBytes, 0)
        XCTAssertEqual(vm.imageCacheResult, .cleared)
        XCTAssertTrue(AdvancedSettingsViewModel.formattedSize(0).hasPrefix("0"))
        XCTAssertFalse(vm.isClearingImageCache)
    }

    func test_AC_274_noClearKeepsTheMeasuredSize() async {
        let cache = MockImageCache([.success(150_400_000)])
        let vm = makeViewModel(cache)

        await vm.loadImageCacheSize()
        await vm.loadImageCacheSize()

        XCTAssertEqual(cache.clearCount, 0, "measuring never empties")
        XCTAssertEqual(vm.imageCacheBytes, 150_400_000)
        XCTAssertNil(vm.imageCacheResult)
    }

    /// 0.4 MB is the index `URLCache` keeps on an empty disk cache: a success,
    /// shown as whole megabytes.
    func test_AC_276_indexResidueBelowOneMegabyteIsSuccess() async {
        let cache = MockImageCache([.success(150_400_000), .success(400_000)])
        let vm = makeViewModel(cache)
        await vm.loadImageCacheSize()

        await vm.clearImageCache()

        XCTAssertEqual(vm.imageCacheResult, .cleared)
        XCTAssertTrue(vm.formattedImageCacheSize.hasPrefix("0"), "whole megabytes rounded down: \(vm.formattedImageCacheSize)")
        XCTAssertTrue(AdvancedSettingsViewModel.formattedSize(999_999).hasPrefix("0"))
    }

    func test_AC_276_remainingSizeIsShownNeverZero() async {
        let cache = MockImageCache([.success(150_400_000)])
        let vm = makeViewModel(cache)
        await vm.loadImageCacheSize()

        await vm.clearImageCache()

        guard case .failed = vm.imageCacheResult else { return XCTFail("expected a failure, got \(String(describing: vm.imageCacheResult))") }
        XCTAssertNotNil(vm.imageCacheFailureMessage)
        XCTAssertEqual(vm.imageCacheBytes, 150_400_000)
        XCTAssertTrue(vm.formattedImageCacheSize.hasPrefix("150"), "shown as measured: \(vm.formattedImageCacheSize)")
    }

    func test_AC_276_unmeasurableAfterClearFails() async {
        let cache = MockImageCache([.success(150_400_000), .failure(MeasureError.unreadable)])
        let vm = makeViewModel(cache)
        await vm.loadImageCacheSize()

        await vm.clearImageCache()

        guard case .failed = vm.imageCacheResult else { return XCTFail("expected a failure") }
        XCTAssertEqual(vm.imageCacheBytes, 150_400_000, "keeps the measure from before, never a zero")
    }

    /// The disk's bookkeeping can lag: 5 MB first, then empty — not yet a failure.
    func test_AC_276_rereadsBeforeDeciding() async {
        let cache = MockImageCache([.success(150_400_000), .success(5_000_000), .success(0)])
        let vm = makeViewModel(cache)
        await vm.loadImageCacheSize()

        await vm.clearImageCache()

        XCTAssertEqual(vm.imageCacheResult, .cleared)
        XCTAssertEqual(vm.imageCacheBytes, 0)
    }

    func test_AC_52_sizeIsUnavailableUntilMeasured() async {
        let cache = MockImageCache([.failure(MeasureError.unreadable)])
        let vm = makeViewModel(cache)

        await vm.loadImageCacheSize()

        XCTAssertNil(vm.imageCacheBytes)
        XCTAssertEqual(vm.formattedImageCacheSize, String(localized: "Unavailable"))
    }

    // MARK: - Log level

    func test_AC_273_logLevelWritesTheStore() {
        let log = AppLogStore(defaults: defaults)
        let vm = AdvancedSettingsViewModel(log: log, imageCache: MockImageCache([.success(0)]))
        XCTAssertEqual(vm.logLevel, .info)

        vm.logLevel = .warning

        XCTAssertEqual(vm.logLevel, .warning)
        XCTAssertEqual(log.currentMinimumLevel(), .warning)
        XCTAssertEqual(AppLogStore(defaults: defaults).currentMinimumLevel(), .warning, "persisted")
    }
}
