import XCTest
@testable import ImmichSwiftUI

/// Behaviour of the "API Keys" screen (gap G20): which route each action takes,
/// what the list shows after a mutation, and the one invariant the client cannot
/// enforce for the server — a secret is readable exactly once.
///
/// Nothing here pins an English label: the strings the screen shows come from
/// the catalog, so the expectations resolve them through `localizedString`
/// instead of freezing the language of the machine running the suite.
final class UserApiKeysViewModelTests: XCTestCase {

    private struct BoomError: Error {}

    private func key(
        _ id: String,
        name: String = "ci",
        createdAt: String? = "2024-07-29T14:30:00.000Z",
        permissions: [String]? = ["asset.read"]
    ) -> ApiKeyResponseDto {
        ApiKeyResponseDto(id: id, name: name, createdAt: createdAt, updatedAt: nil, permissions: permissions)
    }

    // MARK: - Loading

    @MainActor
    func test_load_populatesKeysFromTheListEndpoint() async {
        let mock = MockImmichClient()
        mock.apiKeysResponse = [key("k1"), key("k2", name: "laptop")]
        let vm = UserApiKeysViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.keys.map(\.id), ["k1", "k2"])
        XCTAssertEqual(vm.keys.map(\.name), ["ci", "laptop"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func test_loadMyKey_failure_leavesTheRowAbsent() async {
        let mock = MockImmichClient()
        mock.myAPIKeyResponse = key("k1", name: "session key")
        let vm = UserApiKeysViewModel(client: mock)

        await vm.loadMyKey()
        XCTAssertEqual(vm.myKey?.id, "k1")

        // A session-authenticated caller has no key carrying the request, so
        // this route can legitimately refuse: the row disappears, the screen
        // does not.
        mock.adminError = BoomError()
        await vm.loadMyKey()

        XCTAssertNil(vm.myKey)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Creation

    @MainActor
    func test_create_sendsNameAndPermissions_andExposesSecretOnce() async {
        let mock = MockImmichClient()
        mock.apiKeyCreateResponse = ApiKeyCreateResponseDto(secret: "s3cret", apiKey: key("k9"))
        mock.apiKeysResponse = [key("k9")]
        let vm = UserApiKeysViewModel(client: mock)

        let created = await vm.create(name: "  phone  ", permissions: ["asset.read", "asset.upload"])

        XCTAssertTrue(created)
        XCTAssertEqual(mock.lastCreateApiKeyName, "phone")
        XCTAssertEqual(mock.lastCreateApiKeyPermissions, ["asset.read", "asset.upload"])
        XCTAssertEqual(vm.pendingSecret, "s3cret")
        XCTAssertEqual(vm.keys.map(\.id), ["k9"], "the new key joins the list right away")

        vm.dismissSecret()
        XCTAssertNil(vm.pendingSecret, "the server answers a secret once; nothing keeps a second copy")
    }

    @MainActor
    func test_create_rejectsEmptyName_withoutCallingTheClient() async {
        let mock = MockImmichClient()
        let vm = UserApiKeysViewModel(client: mock)

        let created = await vm.create(name: "   ", permissions: ["all"])

        XCTAssertFalse(created, "the sheet must stay open on a refused name")
        XCTAssertEqual(mock.requestCount, 0)
        XCTAssertNil(vm.pendingSecret)
        XCTAssertNotNil(vm.errorMessage)
    }

    @MainActor
    func test_create_failure_keepsTheSheetOpen_andShowsNoSecret() async {
        let mock = MockImmichClient()
        mock.adminError = BoomError()
        let vm = UserApiKeysViewModel(client: mock)

        let created = await vm.create(name: "ci", permissions: ["all"])

        XCTAssertFalse(created)
        XCTAssertNil(vm.pendingSecret)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Rotation and revocation

    @MainActor
    func test_rotate_storesTheNewSecretAndInvalidatesNothingLocal() async {
        let mock = MockImmichClient()
        mock.apiKeysResponse = [key("k1")]
        mock.apiKeyRotateResponse = ApiKeyCreateResponseDto(secret: "fresh", apiKey: key("k1"))
        let vm = UserApiKeysViewModel(client: mock)
        await vm.load()

        vm.rotationTarget = vm.keys[0]
        await vm.rotate(vm.keys[0])

        XCTAssertEqual(mock.lastRotateApiKeyId, "k1")
        XCTAssertEqual(vm.pendingSecret, "fresh")
        XCTAssertNil(vm.rotationTarget, "the dialog closes on the key it confirmed")
        XCTAssertEqual(vm.keys.map(\.id), ["k1"], "rotation replaces the secret, not the key")
    }

    @MainActor
    func test_delete_dropsTheKeyFromTheList() async {
        let mock = MockImmichClient()
        mock.apiKeysResponse = [key("k1"), key("k2")]
        let vm = UserApiKeysViewModel(client: mock)
        await vm.load()

        mock.apiKeysResponse = [key("k2")]
        vm.deletionTarget = vm.keys[0]
        await vm.delete(vm.keys[0])

        XCTAssertEqual(mock.lastDeleteApiKeyId, "k1")
        XCTAssertNil(vm.deletionTarget)
        XCTAssertEqual(vm.keys.map(\.id), ["k2"])
    }

    // MARK: - Projections

    @MainActor
    func test_permissionsSummary_saysFullAccessForTheAllPermission() {
        let vm = UserApiKeysViewModel(client: MockImmichClient())

        XCTAssertEqual(vm.permissionsSummary(key("k1", permissions: ["all"])), localizedString("Full access"))
        XCTAssertEqual(
            vm.permissionsSummary(key("k2", permissions: ["asset.read", "asset.upload"])),
            localizedString("%lld permissions", 2)
        )
        XCTAssertEqual(vm.permissionsSummary(key("k3", permissions: nil)), localizedString("%lld permissions", 0))
    }

    @MainActor
    func test_createdAt_undecodable_returnsUnknownLabel() {
        let vm = UserApiKeysViewModel(client: MockImmichClient())

        XCTAssertEqual(vm.formattedCreatedAt(key("k1", createdAt: "not-a-date")), localizedString("Unknown"))
        XCTAssertEqual(vm.formattedCreatedAt(key("k2", createdAt: nil)), localizedString("Unknown"))
    }

    // MARK: - List states (L-16)

    private let serverError = APIError.serverError(500, "x")

    /// A gate whose first call waits for `latch`; the following ones pass.
    private func holdingFirstCall(_ latch: TestLatch) -> (() async throws -> Void) {
        let calls = TestBox(0)
        return {
            calls.value += 1
            if calls.value == 1 { try await latch.wait() }
        }
    }

    @MainActor
    func test_AC_142_apiKeys_loadingUntilFirstAnswer() async {
        let mock = MockImmichClient()
        mock.apiKeysResponse = [key("k1")]
        let latch = TestLatch()
        mock.apiKeysGate = { try await latch.wait() }
        let vm = UserApiKeysViewModel(client: mock)
        XCTAssertEqual(vm.renderState, .loading)

        let read = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_147_apiKeys_successfulEmptyReadIsEmptyState() async {
        let vm = UserApiKeysViewModel(client: MockImmichClient())

        await vm.load()

        XCTAssertEqual(vm.renderState, .empty)
        XCTAssertTrue(vm.hasLoaded)
    }

    @MainActor
    func test_AC_149_apiKeys_firstReadFailsShowsErrorNotEmpty() async {
        let mock = MockImmichClient()
        mock.adminError = serverError
        let vm = UserApiKeysViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.keys.isEmpty)
        XCTAssertNil(vm.errorMessage, "the read never writes the action error")
    }

    @MainActor
    func test_AC_149_apiKeys_retryShowsLoadingThenData() async {
        let mock = MockImmichClient()
        mock.adminError = serverError
        let vm = UserApiKeysViewModel(client: mock)
        await vm.load()
        mock.adminError = nil
        mock.apiKeysResponse = [key("k1")]
        let latch = TestLatch()
        mock.apiKeysGate = { try await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.load() }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(vm.keys.map(\.id), ["k1"])
    }

    @MainActor
    func test_AC_152_apiKeys_refreshFailureKeepsDataThenRetryClears() async {
        let mock = MockImmichClient()
        mock.apiKeysResponse = [key("k1")]
        let vm = UserApiKeysViewModel(client: mock)
        await vm.load()

        mock.adminError = serverError
        await vm.refresh()

        XCTAssertEqual(vm.renderState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.keys.map(\.id), ["k1"])

        mock.adminError = nil
        await vm.load()
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_apiKeys_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        let vm = UserApiKeysViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.renderState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        mock.apiKeysGate = { try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 1 }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .empty)
        mock.apiKeysResponse = [key("k1")]
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .data(.idle))

        // From the error state.
        mock.apiKeysGate = nil
        mock.apiKeysResponse = nil
        let failing = UserApiKeysViewModel(client: mock)
        mock.adminError = serverError
        await failing.load()
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        mock.apiKeysGate = { try await errorLatch.wait() }
        mock.apiKeysResponse = [key("k1")]
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refresh() }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 1 }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        mock.adminError = nil
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_apiKeys_refreshDuringReadIsNotIgnored() async {
        let mock = MockImmichClient()
        mock.apiKeysResponse = [key("k1")]
        let latch = TestLatch()
        mock.apiKeysGate = holdingFirstCall(latch)
        let vm = UserApiKeysViewModel(client: mock)

        let first = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }
        await vm.refresh()
        XCTAssertEqual(mock.requestCount, 2, "a pull during a read is a request of its own")
        XCTAssertEqual(vm.renderState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.adminError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func test_AC_31_apiKeys_errorThenEmptyThenData() async {
        let mock = MockImmichClient()
        let vm = UserApiKeysViewModel(client: mock)
        mock.adminError = serverError
        await vm.refresh()
        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage))

        mock.adminError = nil
        await vm.refresh()
        XCTAssertEqual(vm.renderState, .empty)

        mock.apiKeysResponse = [key("k1")]
        await vm.refresh()
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_149_apiKeys_actionErrorDoesNotSetTheReadError() async {
        let mock = MockImmichClient()
        mock.apiKeysResponse = [key("k1")]
        let vm = UserApiKeysViewModel(client: mock)
        await vm.load()

        mock.adminError = serverError
        await vm.delete(key("k1"))

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.loadErrorMessage)
        XCTAssertEqual(vm.renderState, .data(.idle))
    }
}
