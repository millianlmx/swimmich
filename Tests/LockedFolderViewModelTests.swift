import XCTest
@testable import ImmichSwiftUI

/// The locked folder (gap G12).
///
/// The point of this feature is that the PIN is a **server** gate: every test
/// here asserts what reached `ImmichClient` (or did not) and which door the
/// folder shows — never how the ViewModel stores its state.
@MainActor
final class LockedFolderViewModelTests: XCTestCase {

    private static let account = "https://immich.example|user@example.com"

    private var client: MockImmichClient!
    private var pins: StubPINStore!
    private var probe: EvaluatorProbe!
    private var vm: LockedFolderViewModel!

    override func setUp() {
        super.setUp()
        client = MockImmichClient()
        pins = StubPINStore()
        // Captured as a local before the ViewModel: the evaluator is
        // `@Sendable`, so it must not reach back into the test case.
        let probe = EvaluatorProbe()
        self.probe = probe
        vm = LockedFolderViewModel(
            client: client,
            pins: pins,
            accountID: Self.account,
            evaluator: { probe.evaluate() },
            biometricsAvailable: { true }
        )
    }

    override func tearDown() {
        vm = nil
        probe = nil
        pins = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func status(isElevated: Bool, pinCode: Bool) {
        client.authStatus = AuthStatusResponseDto(
            expiresAt: nil,
            isElevated: isElevated,
            password: true,
            pinCode: pinCode,
            pinExpiresAt: nil
        )
    }

    /// One locked bucket, the way the server answers
    /// `timeline/buckets?visibility=locked` followed by `timeline/bucket`:
    /// appended to the bucket list (newest first) and given its assets.
    private func stubLockedBucket(ids: [String], day: String = "2024-07-01") {
        client.bucketsResponse.append(TimeBucketsResponseDto(timeBucket: day, count: ids.count))
        client.bucketResponses[day] = TimeBucketAssetResponseDto(
            id: ids,
            ownerId: ids.map { _ in "owner" },
            ratio: ids.map { _ in 1.0 },
            isFavorite: ids.map { _ in false },
            visibility: ids.map { _ in "locked" },
            isTrashed: ids.map { _ in false },
            isImage: ids.map { _ in true },
            thumbhash: ids.map { _ in nil },
            createdAt: ids.map { _ in "\(day)T10:00:00.000Z" },
            fileCreatedAt: ids.map { _ in "\(day)T10:00:00.000Z" },
            localOffsetHours: ids.map { _ in 0.0 },
            duration: ids.map { _ in nil },
            livePhotoVideoId: ids.map { _ in nil },
            projectionType: ids.map { _ in nil },
            stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
        )
    }

    // MARK: - The gate reads the server

    func test_refreshGate_needsSetupWhenNoPinCode() async {
        status(isElevated: false, pinCode: false)

        await vm.refreshGate()

        XCTAssertEqual(vm.gate, .needsSetup)
        XCTAssertTrue(vm.items.isEmpty)
    }

    func test_refreshGate_lockedWhenAPinCodeAlreadyExists() async {
        status(isElevated: false, pinCode: true)

        await vm.refreshGate()

        XCTAssertEqual(vm.gate, .locked)
    }

    func test_refreshGate_unlockedWhenSessionIsAlreadyElevated() async {
        status(isElevated: true, pinCode: true)
        stubLockedBucket(ids: ["locked-1"])

        await vm.refreshGate()

        XCTAssertEqual(vm.gate, .unlocked)
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])
    }

    /// The status route requires a session token — an API-key account is
    /// answered 400. The door must say so rather than loop on a PIN field.
    func test_refreshGate_surfacesTheServerRefusal() async {
        client.authStatusError = NSError(domain: "test", code: 400)

        await vm.refreshGate()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNotEqual(vm.gate, .unlocked)
    }

    // MARK: - Creating the PIN

    func test_setupPIN_rejectsFiveDigitPIN() async {
        vm.gate = .needsSetup
        vm.pinEntry = "12345"
        vm.confirmationEntry = "12345"

        await vm.setupPIN()

        XCTAssertEqual(vm.errorMessage, localizedString("Enter 6 digits"))
        XCTAssertEqual(vm.gate, .needsSetup)
        XCTAssertTrue(client.createdPINs.isEmpty, "a refused PIN must not reach the server")
        XCTAssertTrue(client.unlockedPINs.isEmpty)
    }

    func test_setupPIN_rejectsMismatchedConfirmation() async {
        vm.gate = .needsSetup
        vm.pinEntry = "123456"
        vm.confirmationEntry = "654321"

        await vm.setupPIN()

        XCTAssertEqual(vm.errorMessage, localizedString("PINs don't match"))
        XCTAssertEqual(vm.gate, .needsSetup)
        XCTAssertTrue(client.createdPINs.isEmpty)
        XCTAssertTrue(client.unlockedPINs.isEmpty)
        XCTAssertNil(pins.storedPIN(for: Self.account))
    }

    func test_setupPIN_createsThePINUnlocksAndRemembersIt() async {
        vm.gate = .needsSetup
        vm.pinEntry = "123456"
        vm.confirmationEntry = "123456"
        vm.rememberPIN = true
        stubLockedBucket(ids: ["locked-1"])

        await vm.setupPIN()

        XCTAssertEqual(client.createdPINs, ["123456"])
        XCTAssertEqual(client.unlockedPINs, ["123456"], "the folder opens only once the server accepted the elevation")
        XCTAssertEqual(pins.storedPIN(for: Self.account), "123456")
        XCTAssertEqual(vm.gate, .unlocked)
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])
    }

    func test_setupPIN_doesNotRememberThePINWhenTheToggleIsOff() async {
        vm.gate = .needsSetup
        vm.pinEntry = "123456"
        vm.confirmationEntry = "123456"

        await vm.setupPIN()

        XCTAssertNil(pins.storedPIN(for: Self.account), "Face ID must have nothing to replay")
    }

    // MARK: - Opening the door with the PIN

    func test_submitPIN_successUnlocksAndLoadsLockedItems() async {
        vm.pinEntry = "123456"
        stubLockedBucket(ids: ["locked-1", "locked-2"])

        await vm.submitPIN()

        XCTAssertEqual(client.unlockedPINs, ["123456"])
        XCTAssertEqual(vm.gate, .unlocked)
        XCTAssertEqual(vm.items.map(\.id), ["locked-1", "locked-2"])
        XCTAssertEqual(vm.pinEntry, "")
        XCTAssertEqual(vm.failedAttempts, 0)
    }

    func test_submitPIN_failureKeepsGateLocked() async {
        vm.gate = .locked
        vm.pinEntry = "000000"
        client.unlockAuthSessionError = NSError(domain: "test", code: 401)

        await vm.submitPIN()

        XCTAssertEqual(vm.gate, .locked)
        XCTAssertEqual(vm.failedAttempts, 1)
        XCTAssertEqual(vm.errorMessage, localizedString("Wrong PIN"))
        XCTAssertEqual(vm.pinEntry, "")
        XCTAssertTrue(vm.items.isEmpty)
    }

    func test_submitPIN_stopsCallingTheServerAfterFiveFailures() async {
        client.unlockAuthSessionError = NSError(domain: "test", code: 401)

        for _ in 0..<6 {
            vm.pinEntry = "000000"
            await vm.submitPIN()
        }

        XCTAssertEqual(client.unlockedPINs.count, 5)
        XCTAssertEqual(vm.failedAttempts, 5)
        XCTAssertTrue(vm.attemptsExhausted)
        XCTAssertEqual(vm.errorMessage, localizedString("Too many attempts"))
    }

    // MARK: - Error haptic on a refused PIN (AC-64, AC-807)

    func test_AC_64_serverRefusedPINBumpsFeedback() async {
        client.unlockAuthSessionError = APIError.serverError(400, "Wrong PIN code")
        vm.pinEntry = "000000"

        await vm.submitPIN()

        XCTAssertEqual(vm.pinRefusalFeedbackTick, 1)
    }

    func test_AC_807_eachServerRefusalBumpsFeedbackUpToTheLimit() async {
        client.unlockAuthSessionError = APIError.serverError(400, "Wrong PIN code")

        for expected in 1...5 {
            vm.pinEntry = "000000"
            await vm.submitPIN()
            XCTAssertEqual(vm.pinRefusalFeedbackTick, expected, "refusal \(expected), the one reaching the limit included")
        }
        vm.pinEntry = "000000"
        await vm.submitPIN()
        XCTAssertEqual(vm.pinRefusalFeedbackTick, 5, "the exhausted door sends no request, so it plays nothing")
    }

    func test_AC_807_acceptedPINDoesNotBumpFeedback() async {
        vm.pinEntry = "123456"
        stubLockedBucket(ids: [])

        await vm.submitPIN()

        XCTAssertEqual(vm.gate, .unlocked)
        XCTAssertEqual(vm.pinRefusalFeedbackTick, 0)
    }

    func test_AC_807_networkAndServerErrorsDoNotBumpFeedback() async {
        for error: APIError in [
            .network(URLError(.notConnectedToInternet)),
            .serverError(500, nil),
            .unauthorized,
            .http(503),
        ] {
            client.unlockAuthSessionError = error
            vm.pinEntry = "000000"
            await vm.submitPIN()
        }
        XCTAssertEqual(vm.pinRefusalFeedbackTick, 0, "only a 4xx answer is a refusal")
        XCTAssertEqual(vm.failedAttempts, 4, "the attempt counter is unchanged by the haptic rule")
    }

    func test_AC_807_faceIDReplayNeverBumpsFeedback() async {
        pins.storePIN("111111", for: Self.account)
        client.unlockAuthSessionError = APIError.serverError(400, "Wrong PIN code")

        await vm.unlockWithBiometrics()

        XCTAssertEqual(vm.pinRefusalFeedbackTick, 0)
    }

    // AC-807: what counts as "the server refused" (decision: 4xx only).
    func test_AC_807_isServerRefusalClassification() {
        XCTAssertTrue(APIError.serverError(400, "Wrong PIN code").isServerRefusal)
        XCTAssertTrue(APIError.serverError(429, "Too many attempts").isServerRefusal)
        XCTAssertTrue(APIError.http(403).isServerRefusal)
        XCTAssertFalse(APIError.serverError(500, nil).isServerRefusal)
        XCTAssertFalse(APIError.http(503).isServerRefusal)
        XCTAssertFalse(APIError.unauthorized.isServerRefusal)
        XCTAssertFalse(APIError.network(URLError(.timedOut)).isServerRefusal)
        XCTAssertFalse(APIError.decoding("x").isServerRefusal)
        XCTAssertFalse(APIError.readOnlyMode.isServerRefusal)
        XCTAssertFalse(APIError.proxyRejected.isServerRefusal)
        XCTAssertFalse(APIError.from(NSError(domain: "test", code: 400)).isServerRefusal, "a foreign error is not a server answer")
    }

    // MARK: - Opening the door with Face ID

    func test_unlockWithBiometrics_replaysStoredPIN() async {
        pins.storePIN("654321", for: Self.account)
        stubLockedBucket(ids: ["locked-1"])

        await vm.unlockWithBiometrics()

        XCTAssertEqual(probe.callCount, 1)
        XCTAssertEqual(client.unlockedPINs, ["654321"], "Face ID authorizes the replay, it does not open the folder by itself")
        XCTAssertEqual(vm.gate, .unlocked)
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])
    }

    func test_unlockWithBiometrics_withoutStoredPINNeverReachesTheServer() async {
        await vm.unlockWithBiometrics()

        XCTAssertEqual(probe.callCount, 0, "no PIN to replay means no prompt and no call")
        XCTAssertTrue(client.unlockedPINs.isEmpty)
        XCTAssertEqual(vm.gate, .locked)
    }

    func test_unlockWithBiometrics_refusedEvaluatorKeepsTheDoorShut() async {
        pins.storePIN("654321", for: Self.account)
        probe.answer = false

        await vm.unlockWithBiometrics()

        XCTAssertEqual(probe.callCount, 1)
        XCTAssertTrue(client.unlockedPINs.isEmpty)
        XCTAssertEqual(vm.gate, .locked)
    }

    func test_unlockWithBiometrics_dropsARememberedPINTheServerRefuses() async {
        pins.storePIN("111111", for: Self.account)
        client.unlockAuthSessionError = NSError(domain: "test", code: 401)

        await vm.unlockWithBiometrics()

        XCTAssertNil(pins.storedPIN(for: Self.account), "a stale PIN would loop forever otherwise")
        XCTAssertEqual(vm.gate, .locked)
    }

    // MARK: - The grid

    func test_loadFirstPage_readsTheLockedVisibilityOnBothCalls() async {
        stubLockedBucket(ids: ["locked-1"])

        await vm.loadFirstPage()

        XCTAssertEqual(client.lastTimeBucketsVisibility, "locked")
        XCTAssertEqual(client.lastTimeBucketVisibility, "locked")
    }

    func test_loadMore_pagesThroughTheNextBucket() async {
        stubLockedBucket(ids: ["locked-1"], day: "2024-07-01")
        stubLockedBucket(ids: ["locked-2"], day: "2024-06-30")

        await vm.loadFirstPage()
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])
        XCTAssertTrue(vm.canLoadMore)

        await vm.loadMore()

        XCTAssertEqual(vm.items.map(\.id), ["locked-1", "locked-2"])
        XCTAssertEqual(client.lastTimeBucketVisibility, "locked")
    }

    func test_restoreSelectionToTimeline_sendsTimelineVisibility() async {
        stubLockedBucket(ids: ["locked-1", "locked-2"])
        await vm.loadFirstPage()
        vm.toggleSelection(id: "locked-1")

        await vm.restoreSelectionToTimeline()

        XCTAssertEqual(client.lastBulkUpdateDto?.visibility, .timeline)
        XCTAssertEqual(client.lastBulkUpdateDto?.ids, ["locked-1"])
        XCTAssertEqual(vm.items.map(\.id), ["locked-2"])
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    func test_relock_locksTheSessionAndEmptiesTheGrid() async {
        vm.gate = .unlocked
        stubLockedBucket(ids: ["locked-1"])
        await vm.loadFirstPage()

        await vm.relock()

        XCTAssertEqual(client.lockSessionCallCount, 1)
        XCTAssertEqual(vm.gate, .locked)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertTrue(vm.buckets.isEmpty)
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    func test_AC_137_relockIfUnlocked_locksOnlyAnOpenFolder() async {
        vm.gate = .unlocked
        await vm.relockIfUnlocked()
        XCTAssertEqual(client.lockSessionCallCount, 1)
        XCTAssertEqual(vm.gate, .locked)

        await vm.relockIfUnlocked()
        XCTAssertEqual(client.lockSessionCallCount, 1, "a folder that is already locked costs no request")
        XCTAssertEqual(vm.gate, .locked)

        vm.gate = .needsSetup
        await vm.relockIfUnlocked()
        XCTAssertEqual(client.lockSessionCallCount, 1, "a folder without a PIN keeps its setup door")
        XCTAssertEqual(vm.gate, .needsSetup)
    }

    // MARK: - List states (L-16)

    private let serverError = APIError.serverError(500, "x")

    /// Elevated session: the grid door, ready to read the first page.
    private func elevated() { status(isElevated: true, pinCode: true) }

    func test_AC_142_lockedFolder_loadingUntilFirstAnswer() async {
        elevated()
        stubLockedBucket(ids: ["locked-1"])
        let latch = TestLatch()
        client.authStatusGate = { try await latch.wait() }
        XCTAssertEqual(vm.gridState, .loading)

        let read = Task { @MainActor in await vm.refreshGate() }
        await pollUntil("access check in flight") { self.client.authStatusCallCount == 1 }

        XCTAssertEqual(vm.gridState, .loading)
        XCTAssertFalse(vm.hasCheckedAccess)
        latch.open()
        await read.value
        XCTAssertEqual(vm.gridState, .data(.idle))
    }

    func test_AC_144_lockedFolder_checkingThenLoadingThenEmpty() async {
        elevated()
        let accessLatch = TestLatch()
        let pageLatch = TestLatch()
        client.authStatusGate = { try await accessLatch.wait() }
        client.timelineGate = { _ in try? await pageLatch.wait() }

        let read = Task { @MainActor in await vm.refreshGate() }
        await pollUntil("access check in flight") { self.client.authStatusCallCount == 1 }
        XCTAssertFalse(vm.hasCheckedAccess, "the first check is still running")
        XCTAssertEqual(vm.gridState, .loading)

        accessLatch.open()
        await pollUntil("first page in flight") { self.client.lastTimeBucketsVisibility != nil }
        XCTAssertTrue(vm.hasCheckedAccess)
        XCTAssertEqual(vm.gridState, .loading, "empty only once the first page arrived")

        pageLatch.open()
        await read.value
        XCTAssertEqual(vm.gridState, .empty)
    }

    func test_AC_147_lockedFolder_successfulEmptyReadIsEmptyState() async {
        elevated()

        await vm.refreshGate()

        XCTAssertEqual(vm.gridState, .empty)
        XCTAssertTrue(vm.hasLoaded)
    }

    func test_AC_149_lockedFolder_firstReadFailsShowsErrorNotEmpty() async {
        elevated()
        client.timeBucketsErrorQueue = [serverError]

        await vm.refreshGate()

        XCTAssertEqual(vm.gridState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertEqual(vm.gate, .unlocked, "a failed page read does not close the folder")
    }

    func test_AC_149_lockedFolder_retryShowsLoadingThenData() async {
        elevated()
        client.timeBucketsErrorQueue = [serverError]
        await vm.refreshGate()
        stubLockedBucket(ids: ["locked-1"])
        let latch = TestLatch()
        client.timelineGate = { _ in try? await latch.wait() }
        let before = client.requestCount

        let retry = Task { @MainActor in await vm.refreshGate() }
        await pollUntil("retry in flight") { self.client.requestCount == before + 2 }

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.gridState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.gridState, .data(.idle))
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])
    }

    func test_AC_152_lockedFolder_refreshFailureKeepsDataThenRetryClears() async {
        elevated()
        stubLockedBucket(ids: ["locked-1"])
        await vm.refreshGate()

        client.timeBucketsErrorQueue = [serverError]
        await vm.refresh()

        XCTAssertEqual(vm.gridState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])

        await vm.refreshGate()
        XCTAssertEqual(vm.gridState, .data(.idle))
    }

    func test_AC_152_lockedFolder_accessCheckFailureKeepsTheGrid() async {
        elevated()
        stubLockedBucket(ids: ["locked-1"])
        await vm.refreshGate()

        client.authStatusError = serverError
        await vm.refresh()

        XCTAssertEqual(vm.gate, .unlocked)
        XCTAssertEqual(vm.gridState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])
    }

    func test_AC_154_lockedFolder_refreshFromEmptyAndErrorReads() async {
        elevated()
        await vm.refreshGate()
        XCTAssertEqual(vm.gridState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        client.timelineGate = { _ in try? await emptyLatch.wait() }
        let emptyBefore = client.requestCount
        let emptyPull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull from empty in flight") { self.client.requestCount == emptyBefore + 2 }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.gridState, .empty)
        stubLockedBucket(ids: ["locked-1"])
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.gridState, .data(.idle))

        // From the error state.
        client.timelineGate = nil
        client.bucketsResponse = []
        let failing = LockedFolderViewModel(
            client: client, pins: pins, accountID: Self.account,
            evaluator: { true }, biometricsAvailable: { false }
        )
        client.timeBucketsErrorQueue = [serverError]
        await failing.refreshGate()
        XCTAssertEqual(failing.gridState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        client.timelineGate = { _ in try? await errorLatch.wait() }
        stubLockedBucket(ids: ["locked-2"])
        let errorBefore = client.requestCount
        let errorPull = Task { @MainActor in await failing.refresh() }
        await pollUntil("pull from error in flight") { self.client.requestCount == errorBefore + 2 }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.gridState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.gridState, .data(.idle))
    }

    func test_AC_154_lockedFolder_refreshDuringReadIsNotIgnored() async {
        elevated()
        stubLockedBucket(ids: ["locked-1"])
        let latch = TestLatch()
        let calls = TestBox(0)
        client.timelineGate = { key in
            guard key == "buckets" else { return }
            calls.value += 1
            if calls.value == 1 { try? await latch.wait() }
        }

        let first = Task { @MainActor in await vm.refreshGate() }
        await pollUntil("first read in flight") { self.client.requestCount == 2 }
        await vm.refresh()
        XCTAssertEqual(vm.gridState, .data(.idle))
        XCTAssertEqual(client.authStatusCallCount, 2, "a pull during a read is a read of its own")

        // The superseded read fails late: it must not write.
        client.timeBucketsErrorQueue = [serverError]
        latch.open()
        await first.value

        XCTAssertEqual(vm.gridState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }

    func test_AC_143_lockedFolder_dataKeptDuringRefresh() async {
        elevated()
        stubLockedBucket(ids: ["locked-1"])
        await vm.refreshGate()
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])

        let accessLatch = TestLatch()
        let pageLatch = TestLatch()
        client.authStatusGate = { try await accessLatch.wait() }
        client.timelineGate = { _ in try? await pageLatch.wait() }
        let before = client.requestCount
        let pull = Task { @MainActor in await vm.refresh() }

        await pollUntil("access check in flight") { self.client.requestCount == before + 1 }
        XCTAssertTrue(vm.hasCheckedAccess)
        XCTAssertEqual(vm.gate, .unlocked)
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])
        XCTAssertEqual(vm.gridState, .data(.idle))

        accessLatch.open()
        await pollUntil("first page in flight") { self.client.requestCount == before + 2 }
        XCTAssertEqual(vm.gate, .unlocked)
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])
        XCTAssertEqual(vm.gridState, .data(.idle))

        pageLatch.open()
        await pull.value
        XCTAssertEqual(vm.items.map(\.id), ["locked-1"])
        XCTAssertEqual(vm.gridState, .data(.idle))
    }

    func test_AC_143_lockedFolder_expiredElevationShowsTheDoorNotAnEmptyGrid() async {
        elevated()
        stubLockedBucket(ids: ["locked-1"])
        await vm.refreshGate()

        status(isElevated: false, pinCode: true)
        await vm.refresh()

        XCTAssertEqual(vm.gate, .locked)
        XCTAssertTrue(vm.items.isEmpty, "nothing locked stays in memory behind the door")
    }
}

// MARK: - Doubles

/// In-memory PIN store: the tests must never touch the device Keychain.
private final class StubPINStore: LockedFolderPINStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [String: String] = [:]

    func storedPIN(for account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return pins[account]
    }

    @discardableResult
    func storePIN(_ pin: String, for account: String) -> Bool {
        lock.lock(); pins[account] = pin; lock.unlock()
        return true
    }

    @discardableResult
    func clearPIN(for account: String) -> Bool {
        lock.lock(); pins.removeValue(forKey: account); lock.unlock()
        return true
    }
}

/// Counts the biometric prompts. The evaluator is `@Sendable`, so the counter
/// is lock-guarded rather than test-isolated.
private final class EvaluatorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var answer = true

    func evaluate() -> Bool {
        lock.lock()
        calls += 1
        let value = answer
        lock.unlock()
        return value
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}
