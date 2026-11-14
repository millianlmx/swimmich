import XCTest
@testable import ImmichSwiftUI

/// The first page of the Photos tab and its startup reachability probe
/// (L-28, B-32.7): a silent server shows the error state within the probe's
/// delay, a slow one keeps the loading state, and a page that arrives late
/// replaces the error.
final class TimelineReachabilityTests: XCTestCase {

    /// Holds the first-page request (`getTimeBuckets`) until the test opens it.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private var arrivals = 0

        var arrived: Int { lock.lock(); defer { lock.unlock() }; return arrivals }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                arrivals += 1
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    private func columnar(ids: [String]) -> TimeBucketAssetResponseDto {
        TimeBucketAssetResponseDto(
            id: ids,
            ownerId: ids.map { _ in "owner" },
            ratio: ids.map { _ in 1.0 },
            isFavorite: ids.map { _ in false },
            visibility: ids.map { _ in "timeline" },
            isTrashed: ids.map { _ in false },
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

    private func makeMock(page gate: Gate) -> MockImmichClient {
        let mock = MockImmichClient()
        mock.bucketsResponse = [TimeBucketsResponseDto(timeBucket: "2024-07-01", count: 2)]
        mock.bucketResponses = ["2024-07-01": columnar(ids: ["a1", "a2"])]
        mock.timelineGate = { key in
            if key == "buckets" { await gate.wait() }
        }
        return mock
    }

    @MainActor
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    // AC-341: a server that does not answer the probe puts the error state on screen, with its retry.
    @MainActor
    func test_AC_341_silentServerShowsTheErrorStateNotTheSkeleton() async {
        let gate = Gate()
        let mock = makeMock(page: gate)
        mock.pingError = URLError(.timedOut)
        let vm = TimelineViewModel(client: mock)

        let load = Task { @MainActor in await vm.load() }
        await waitUntil("the error state") { vm.loadErrorMessage != nil }

        XCTAssertEqual(vm.loadErrorMessage, UserFacingError.offlineMessage)
        XCTAssertFalse(vm.isLoading, "the skeleton gives way to the error state")
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertEqual(mock.pingTimeouts, [TimelineViewModel.reachabilityTimeout], "the probe has its own short delay")
        XCTAssertLessThan(TimelineViewModel.reachabilityTimeout, 3, "the budget of the launch")

        gate.open()
        await load.value
    }

    // AC-341: the server comes back and the user touches "Try Again": the content loads.
    @MainActor
    func test_AC_341_retryAfterTheErrorLoadsTheContent() async {
        let gate = Gate()
        let mock = makeMock(page: gate)
        mock.pingError = URLError(.timedOut)
        let vm = TimelineViewModel(client: mock)
        let first = Task { @MainActor in await vm.load() }
        await waitUntil("the error state") { vm.loadErrorMessage != nil }

        // "Try Again" replaces the page still in flight; the server is still silent.
        let retry = Task { @MainActor in await vm.refresh() }
        await waitUntil("the second probe") { mock.pingTimeouts.count == 2 }
        await waitUntil("the second page request") { gate.arrived == 2 }
        await waitUntil("the second error") { vm.loadErrorMessage != nil }
        XCTAssertEqual(vm.loadErrorMessage, UserFacingError.offlineMessage, "a server that stays silent returns to the error")

        // The server is back: the stale page and the new one both come out of the gate.
        mock.pingError = nil
        gate.open()
        await first.value
        await retry.value

        XCTAssertEqual(Set(vm.items.map(\.id)), ["a1", "a2"])
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    // AC-341: a server that answers the probe but serves the page slowly keeps the loading state.
    @MainActor
    func test_AC_341_slowServerKeepsTheLoadingStateUntilItsContent() async {
        let gate = Gate()
        let mock = makeMock(page: gate)
        let vm = TimelineViewModel(client: mock)

        let load = Task { @MainActor in await vm.load() }
        await waitUntil("the probe and the page request") { mock.pingTimeouts.count == 1 && gate.arrived == 1 }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(vm.isLoading)
        XCTAssertNil(vm.loadErrorMessage, "no error while a server that answers is slow")

        gate.open()
        await load.value
        XCTAssertEqual(Set(vm.items.map(\.id)), ["a1", "a2"])
        XCTAssertNil(vm.loadErrorMessage)
    }

    // A reply of any status proves the server is there: only a missing answer is "offline".
    @MainActor
    func test_probeAnswerWithAnErrorStatusIsNotOffline() async {
        let gate = Gate()
        let mock = makeMock(page: gate)
        mock.pingError = APIError.serverError(500, nil)
        let vm = TimelineViewModel(client: mock)

        let load = Task { @MainActor in await vm.load() }
        await waitUntil("the probe and the page request") { mock.pingTimeouts.count == 1 && gate.arrived == 1 }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(vm.isLoading)
        XCTAssertNil(vm.loadErrorMessage)

        gate.open()
        await load.value
    }

    // AC-341: a probe that timed out and a page that arrives afterwards: the content replaces the
    // error without a gesture — the server was joinable, only slow to connect.
    @MainActor
    func test_AC_341_lateFirstPageReplacesError() async {
        let gate = Gate()
        let mock = makeMock(page: gate)
        mock.pingError = URLError(.timedOut)
        let vm = TimelineViewModel(client: mock)
        let load = Task { @MainActor in await vm.load() }
        await waitUntil("the error state") { vm.loadErrorMessage != nil }

        gate.open()
        await load.value

        XCTAssertEqual(Set(vm.items.map(\.id)), ["a1", "a2"])
        XCTAssertNil(vm.loadErrorMessage, "the photos replace the probe's error")
        XCTAssertFalse(vm.isLoading)
    }

    // AC-341: a page that fails after the probe's error shows its own message.
    @MainActor
    func test_AC_341_pageFailureAfterTheProbeShowsItsOwnMessage() async {
        let gate = Gate()
        let mock = makeMock(page: gate)
        mock.pingError = URLError(.timedOut)
        let vm = TimelineViewModel(client: mock)
        let load = Task { @MainActor in await vm.load() }
        await waitUntil("the error state") { vm.loadErrorMessage != nil }

        mock.globalError = APIError.serverError(500, nil)
        gate.open()
        await load.value

        XCTAssertEqual(vm.loadErrorMessage, UserFacingError.serverErrorMessage)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertFalse(vm.isLoading)
    }

    // The view reappearing while the first page is in flight starts neither a second page nor a second probe.
    @MainActor
    func test_loadWhileFirstPageInFlightWaitsForIt() async {
        let gate = Gate()
        let mock = makeMock(page: gate)
        let vm = TimelineViewModel(client: mock)

        let first = Task { @MainActor in await vm.load() }
        await waitUntil("the first page request") { gate.arrived == 1 }
        let second = Task { @MainActor in await vm.load() }
        for _ in 0..<20 { await Task.yield() }
        gate.open()
        await first.value
        await second.value

        XCTAssertEqual(mock.pingTimeouts.count, 1)
        XCTAssertEqual(gate.arrived, 1, "one page request, not two")
        XCTAssertEqual(vm.items.count, 2)
    }

    // With photos on screen there is no probe: the banner path is unchanged.
    @MainActor
    func test_noProbeWhenPhotosAreShown() async {
        let gate = Gate()
        gate.open()
        let mock = makeMock(page: gate)
        let vm = TimelineViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(mock.pingTimeouts.count, 1, "an empty grid probes")

        await vm.refresh()

        XCTAssertEqual(mock.pingTimeouts.count, 1, "a grid with photos does not")
        XCTAssertEqual(vm.items.count, 2)
    }
}
