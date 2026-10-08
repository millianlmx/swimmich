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
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_load_failure_surfacesErrorMessageAndKeepsListEmpty() async {
        let mock = MockImmichClient()
        mock.sessionsResponse = [session(id: "phone", current: true)]
        mock.sessionsError = BoomError()
        let vm = DeviceSessionsViewModel(client: mock)

        await vm.load()

        XCTAssertNotNil(vm.errorMessage)
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
}
