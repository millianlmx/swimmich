import XCTest
@testable import ImmichSwiftUI

/// The administration list states (L-16): users, jobs and libraries are read
/// together, and `renderState` follows the users. Mutations keep their own
/// `errorMessage`.
@MainActor
final class AdminViewModelTests: XCTestCase {

    private let serverError = APIError.serverError(500, "x")

    private let alice = UserAdminResponseDto(id: "u1", name: "Alice", email: "alice@example.com")

    /// A gate whose first call waits for `latch`; the following ones pass.
    private func holdingFirstCall(_ latch: TestLatch) -> (() async throws -> Void) {
        let calls = TestBox(0)
        return {
            calls.value += 1
            if calls.value == 1 { try await latch.wait() }
        }
    }

    /// One read asks users, jobs and libraries: three requests.
    private let requestsPerRead = 3

    func test_AC_142_admin_loadingUntilFirstAnswer() async {
        let mock = MockImmichClient()
        mock.adminUsersResponse = [alice]
        let latch = TestLatch()
        mock.adminUsersGate = { try await latch.wait() }
        let vm = AdminViewModel(client: mock)
        XCTAssertEqual(vm.renderState, .loading)

        let read = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == self.requestsPerRead }

        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    func test_AC_147_admin_successfulEmptyReadIsEmptyState() async {
        let vm = AdminViewModel(client: MockImmichClient())

        await vm.load()

        XCTAssertEqual(vm.renderState, .empty)
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertTrue(vm.jobs.isEmpty, "the jobs section says so only after a successful read")
        XCTAssertTrue(vm.libraries.isEmpty, "the libraries section says so only after a successful read")
    }

    func test_AC_149_admin_firstReadFailsShowsErrorNotEmpty() async {
        let mock = MockImmichClient()
        mock.adminError = serverError
        let vm = AdminViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.users.isEmpty)
        XCTAssertNil(vm.errorMessage, "the read never writes the mutation error")
    }

    func test_AC_149_admin_retryShowsLoadingThenData() async {
        let mock = MockImmichClient()
        mock.adminError = serverError
        let vm = AdminViewModel(client: mock)
        await vm.load()
        mock.adminError = nil
        mock.adminUsersResponse = [alice]
        let latch = TestLatch()
        mock.adminUsersGate = { try await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.load(force: true) }
        await pollUntil("retry in flight") { mock.requestCount == before + self.requestsPerRead }

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(vm.users.map(\.id), ["u1"])
    }

    func test_AC_152_admin_refreshFailureKeepsDataThenRetryClears() async {
        let mock = MockImmichClient()
        mock.adminUsersResponse = [alice]
        let vm = AdminViewModel(client: mock)
        await vm.load()

        mock.adminError = serverError
        await vm.refresh()

        XCTAssertEqual(vm.renderState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.users.map(\.id), ["u1"])

        mock.adminError = nil
        await vm.load(force: true)
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    func test_AC_154_admin_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        let vm = AdminViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.renderState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        mock.adminUsersGate = { try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull from empty in flight") {
            mock.requestCount >= emptyBefore + self.requestsPerRead
        }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .empty)
        mock.adminUsersResponse = [alice]
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .data(.idle))

        // From the error state.
        mock.adminUsersGate = nil
        mock.adminUsersResponse = nil
        let failing = AdminViewModel(client: mock)
        mock.adminError = serverError
        await failing.load()
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        mock.adminUsersGate = { try await errorLatch.wait() }
        mock.adminUsersResponse = [alice]
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refresh() }
        await pollUntil("pull from error in flight") {
            mock.requestCount >= errorBefore + self.requestsPerRead
        }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        mock.adminError = nil
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.renderState, .data(.idle))
    }

    func test_AC_154_admin_refreshDuringReadIsNotIgnored() async {
        let mock = MockImmichClient()
        mock.adminUsersResponse = [alice]
        let latch = TestLatch()
        mock.adminUsersGate = holdingFirstCall(latch)
        let vm = AdminViewModel(client: mock)

        let first = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == self.requestsPerRead }
        await vm.refresh()
        XCTAssertEqual(vm.renderState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.adminError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }

    func test_AC_149_admin_mutationErrorDoesNotSetTheReadError() async {
        let mock = MockImmichClient()
        mock.adminUsersResponse = [alice]
        let vm = AdminViewModel(client: mock)
        await vm.load()

        mock.adminError = serverError
        await vm.runJob(name: "thumbnailGeneration", command: "start")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertEqual(vm.renderState, .data(.idle))
    }
}
