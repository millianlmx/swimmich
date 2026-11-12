import XCTest
@testable import ImmichSwiftUI

/// Behaviour of the connected-devices screen (gap G19): what actually reaches
/// the server, what the guards refuse **before** any request, and how the two
/// projections split the list.
///
/// Nothing here pins a user-visible label: every string on that screen is a
/// catalog key resolved against the interface language, which is exactly the
/// trap this suite must not walk into.
final class DeviceSessionsViewModelTests: XCTestCase {

    private struct BoomError: Error {}
    private struct ProbeError: Error {}

    /// `GET /api/auth/status` as the mock answers it — the elevation the screen
    /// is allowed to believe.
    private func status(isElevated: Bool) -> AuthStatusResponseDto {
        AuthStatusResponseDto(
            expiresAt: nil,
            isElevated: isElevated,
            password: true,
            pinCode: true,
            pinExpiresAt: nil
        )
    }

    private func session(
        id: String,
        current: Bool = false,
        os: String = "iOS",
        type: String = "iPhone",
        version: String? = "1.135.0",
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        expiresAt: Date? = nil
    ) -> SessionResponseDto {
        SessionResponseDto(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: updatedAt,
            expiresAt: expiresAt,
            current: current,
            deviceType: type,
            deviceOS: os,
            appVersion: version,
            isPendingSyncReset: false
        )
    }

    // MARK: - Loading

    @MainActor
    func test_load_populatesSessionsAndFlagsCurrent() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [
            session(id: "phone", current: true),
            session(id: "laptop", os: "macOS", updatedAt: Date(timeIntervalSince1970: 1_700_100_000)),
            session(id: "tablet", os: "iOS", updatedAt: Date(timeIntervalSince1970: 1_700_200_000)),
        ]
        let vm = DeviceSessionsViewModel(client: mock)

        await vm.load()

        // The current session is pinned first, the others by last activity
        // descending — the server's own order is not kept.
        XCTAssertEqual(vm.sessions.map(\.id), ["phone", "tablet", "laptop"])
        XCTAssertEqual(vm.currentSession?.id, "phone")
        XCTAssertEqual(vm.otherSessions.map(\.id), ["tablet", "laptop"])
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.loadErrorMessage)
    }

    @MainActor
    func test_load_failure_surfacesErrorMessageAndKeepsListEmpty() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [session(id: "phone", current: true)]
        mock.sessionsError = BoomError()
        let vm = DeviceSessionsViewModel(client: mock)

        await vm.load()

        XCTAssertNotNil(vm.loadErrorMessage)
        XCTAssertNil(vm.errorMessage, "the read never writes the action error")
        XCTAssertTrue(vm.sessions.isEmpty)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - Revocation

    @MainActor
    func test_revoke_sendsDeleteForTheGivenIdAndReloads() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [session(id: "phone", current: true), session(id: "laptop")]
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.load()

        mock.sessionsResponse = [session(id: "phone", current: true)]

        await vm.revoke(vm.otherSessions[0])

        XCTAssertEqual(mock.deletedSessionIDs, ["laptop"])
        // load + delete + reload: the row must not outlive the server call.
        XCTAssertEqual(vm.sessions.map(\.id), ["phone"])
        // + the elevation probe: four round trips, one of them the answer.
        XCTAssertEqual(mock.requestCount, 4)
        XCTAssertEqual(mock.authStatusCallCount, 1)
    }

    @MainActor
    func test_revoke_ignoresTheCurrentSession() async {
        let mock = MockImmichClient()
        let phone = session(id: "phone", current: true)
        mock.sessionsResponse = [phone]
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.load()
        let requestsBefore = mock.requestCount

        await vm.revoke(phone)

        XCTAssertTrue(mock.deletedSessionIDs.isEmpty)
        XCTAssertEqual(mock.requestCount, requestsBefore)
        // Nothing reached the server, so there is nothing to re-read.
        XCTAssertEqual(mock.authStatusCallCount, 0)
        // The surface cannot even arm the confirmation for it.
        vm.requestRevoke(phone)
        XCTAssertNil(vm.pendingRevocation)
    }

    @MainActor
    func test_revokeAllOthers_deletesWithoutIdAndReloads() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [
            session(id: "phone", current: true),
            session(id: "laptop"),
            session(id: "tablet"),
        ]
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.load()

        mock.sessionsResponse = [session(id: "phone", current: true)]

        await vm.revokeAllOthers()

        XCTAssertEqual(mock.deleteAllSessionsCallCount, 1)
        // The bulk route names no id — that is what leaves the current session
        // alone, and it is not a loop over `deleteSession`.
        XCTAssertTrue(mock.deletedSessionIDs.isEmpty)
        XCTAssertEqual(vm.sessions.map(\.id), ["phone"])
        XCTAssertEqual(mock.authStatusCallCount, 1)
    }

    // MARK: - Elevation

    /// The elevation goes down because the server says so, not because this
    /// screen asked for it — the two are only the same when the answer arrives.
    @MainActor
    func test_lock_clearsElevation() async {
        let mock = MockImmichClient()
        mock.authStatus = status(isElevated: true)
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.unlock(pinCode: "123456")
        XCTAssertTrue(vm.isElevated)

        mock.authStatus = status(isElevated: false)
        await vm.lockCurrentSession()

        XCTAssertEqual(mock.lockSessionCallCount, 1)
        XCTAssertEqual(mock.authStatusCallCount, 2)
        XCTAssertFalse(vm.isElevated)
    }

    /// Every mutation ends on the probe — there is no path that writes
    /// `isElevated` from the action it just performed.
    @MainActor
    func test_everyAction_probesTheServerForElevation() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [session(id: "phone", current: true), session(id: "laptop")]
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(mock.authStatusCallCount, 0)

        await vm.revoke(vm.otherSessions[0])
        XCTAssertEqual(mock.authStatusCallCount, 1)

        await vm.revokeAllOthers()
        XCTAssertEqual(mock.authStatusCallCount, 2)

        await vm.lockCurrentSession()
        XCTAssertEqual(mock.authStatusCallCount, 3)

        await vm.unlock(pinCode: "123456")
        XCTAssertEqual(mock.authStatusCallCount, 4)
    }

    /// The unlock route answered, so "the session is elevated" is exactly what a
    /// local mirror would have written. The probe says otherwise, and the server
    /// wins.
    @MainActor
    func test_elevationIsTheServersAnswerNotTheActions() async {
        let mock = MockImmichClient()
        mock.authStatus = status(isElevated: false)
        let vm = DeviceSessionsViewModel(client: mock)

        await vm.unlock(pinCode: "123456")

        XCTAssertEqual(mock.unlockedPINs, ["123456"])
        XCTAssertEqual(mock.authStatusCallCount, 1)
        XCTAssertFalse(vm.isElevated)
        XCTAssertFalse(vm.isElevationStale)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_unlock_rejectsPinShorterThanSixDigitsWithoutCallingTheClient() async {
        let mock = MockImmichClient()
        let vm = DeviceSessionsViewModel(client: mock)

        await vm.unlock(pinCode: "12345")

        XCTAssertTrue(mock.unlockedPINs.isEmpty)
        XCTAssertEqual(mock.requestCount, 0)
        XCTAssertEqual(mock.authStatusCallCount, 0)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isElevated)
    }

    @MainActor
    func test_unlock_withSixDigitPin_raisesElevation() async {
        let mock = MockImmichClient()
        mock.authStatus = status(isElevated: true)
        let vm = DeviceSessionsViewModel(client: mock)

        await vm.unlock(pinCode: "123456")

        XCTAssertEqual(mock.unlockedPINs, ["123456"])
        XCTAssertEqual(mock.authStatusCallCount, 1)
        XCTAssertTrue(vm.isElevated)
        XCTAssertFalse(vm.isElevationStale)
        XCTAssertNil(vm.errorMessage)
    }

    /// The API-key account: the elevation route answers 400, a call that can
    /// only fail. That message is what the screen shows — the probe that follows
    /// does not replace it with a verdict of its own.
    @MainActor
    func test_unlock_serverRefusal_surfacesMessageAndLeavesElevationOff() async {
        let mock = MockImmichClient()
        mock.unlockAuthSessionError = BoomError()
        let vm = DeviceSessionsViewModel(client: mock)

        await vm.unlock(pinCode: "123456")

        XCTAssertEqual(mock.unlockedPINs, ["123456"])
        XCTAssertEqual(mock.authStatusCallCount, 1)
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
        XCTAssertFalse(vm.isElevated)
    }

    // MARK: - A probe that fails

    /// The unlock went through, but nothing came back to confirm it: the screen
    /// must not claim an elevation it was never told about.
    @MainActor
    func test_probeFailure_afterUnlock_doesNotClaimElevation() async {
        let mock = MockImmichClient()
        mock.authStatus = status(isElevated: true)
        mock.authStatusError = ProbeError()
        let vm = DeviceSessionsViewModel(client: mock)

        await vm.unlock(pinCode: "123456")

        XCTAssertEqual(mock.unlockedPINs, ["123456"])
        XCTAssertEqual(mock.authStatusCallCount, 1)
        XCTAssertFalse(vm.isElevated)
        XCTAssertTrue(vm.isElevationStale)
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
    }

    /// The mirror image: the last confirmed state was elevated, the lock call
    /// went through, and the probe failed. The screen keeps what the server did
    /// say and flags it, instead of reading a new state off a request.
    @MainActor
    func test_probeFailure_afterLock_keepsTheLastConfirmedElevation() async {
        let mock = MockImmichClient()
        mock.authStatus = status(isElevated: true)
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.unlock(pinCode: "123456")
        XCTAssertTrue(vm.isElevated)

        mock.authStatusError = ProbeError()
        await vm.lockCurrentSession()

        XCTAssertEqual(mock.lockSessionCallCount, 1)
        XCTAssertEqual(mock.authStatusCallCount, 2)
        XCTAssertTrue(vm.isElevated)
        XCTAssertTrue(vm.isElevationStale)
    }

    /// Two failures in one action: the mutation's is the one the user can act
    /// on, so the probe's must not overwrite it — it only marks the elevation
    /// stale.
    @MainActor
    func test_probeFailure_keepsTheMutationError() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [session(id: "phone", current: true), session(id: "laptop")]
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.load()

        mock.deleteSessionError = BoomError()
        mock.authStatusError = ProbeError()
        await vm.revoke(vm.otherSessions[0])

        XCTAssertEqual(mock.authStatusCallCount, 1)
        XCTAssertTrue(vm.isElevationStale)
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
    }

    // MARK: - List states (L-16)

    private let serverError = APIError.serverError(500, "x")

    /// Holds the first request of a route on `latch`; later ones pass.
    private func holdingFirstCall(_ latch: TestLatch) -> (() async throws -> Void) {
        let calls = TestBox(0)
        return {
            calls.value += 1
            if calls.value == 1 { try await latch.wait() }
        }
    }

    @MainActor
    func test_AC_142_deviceSessions_loadingUntilFirstAnswer() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [session(id: "phone", current: true)]
        let latch = TestLatch()
        mock.sessionsGate = { try await latch.wait() }
        let vm = DeviceSessionsViewModel(client: mock)
        XCTAssertEqual(vm.renderState, .loading)

        let read = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_149_deviceSessions_firstReadFailsShowsErrorNotEmpty() async {
        let mock = MockImmichClient()
        mock.sessionsError = serverError
        let vm = DeviceSessionsViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.sessions.isEmpty)
    }

    @MainActor
    func test_AC_149_deviceSessions_successfulEmptyReadIsEmpty() async {
        let vm = DeviceSessionsViewModel(client: MockImmichClient())

        await vm.load()

        XCTAssertEqual(vm.renderState, .empty)
        XCTAssertTrue(vm.hasLoaded)
    }

    @MainActor
    func test_AC_149_deviceSessions_retryShowsLoadingThenData() async {
        let mock = MockImmichClient()
        mock.sessionsError = serverError
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.load()
        mock.sessionsError = nil
        mock.sessionsResponse = [session(id: "phone", current: true)]
        let latch = TestLatch()
        mock.sessionsGate = { try await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.load() }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(vm.sessions.map(\.id), ["phone"])
    }

    @MainActor
    func test_AC_159_deviceSessions_failureNeverEmptyThenRetry() async {
        let mock = MockImmichClient()
        mock.sessionsError = serverError
        let vm = DeviceSessionsViewModel(client: mock)

        await vm.load()
        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage), "never the empty state")

        mock.sessionsError = nil
        mock.sessionsResponse = [session(id: "phone", current: true), session(id: "laptop")]
        await vm.load()

        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(vm.sessions.map(\.id), ["phone", "laptop"])
    }

    @MainActor
    func test_AC_152_deviceSessions_refreshFailureKeepsDataThenRetryClears() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [session(id: "phone", current: true)]
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.load()

        mock.sessionsError = serverError
        await vm.refresh()

        XCTAssertEqual(vm.renderState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.sessions.map(\.id), ["phone"])

        mock.sessionsError = nil
        await vm.load()
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_deviceSessions_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.renderState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        mock.sessionsGate = { try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 1 }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .empty)
        mock.sessionsResponse = [session(id: "phone", current: true)]
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .data(.idle))

        // From the error state.
        mock.sessionsGate = nil
        mock.sessionsResponse = nil
        let failing = DeviceSessionsViewModel(client: mock)
        mock.sessionsError = serverError
        await failing.load()
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        mock.sessionsGate = { try await errorLatch.wait() }
        mock.sessionsResponse = [session(id: "phone", current: true)]
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refresh() }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 1 }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        mock.sessionsError = nil
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_deviceSessions_refreshDuringReadIsNotIgnored() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [session(id: "phone", current: true)]
        let latch = TestLatch()
        mock.sessionsGate = holdingFirstCall(latch)
        let vm = DeviceSessionsViewModel(client: mock)

        let first = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }
        await vm.refresh()
        XCTAssertEqual(mock.requestCount, 2, "a pull during a read is a request of its own")
        XCTAssertEqual(vm.renderState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.sessionsError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func test_AC_149_deviceSessions_actionErrorDoesNotSetTheReadError() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [session(id: "phone", current: true), session(id: "laptop")]
        let vm = DeviceSessionsViewModel(client: mock)
        await vm.load()

        mock.deleteSessionError = serverError
        await vm.revoke(vm.otherSessions[0])

        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertEqual(vm.renderState, .data(.idle))
    }
}
