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
