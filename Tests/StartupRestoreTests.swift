import XCTest
@testable import ImmichSwiftUI

/// The launch reaches the home screen without waiting for the server (L-28, B-32.7).
final class StartupRestoreTests: XCTestCase {

    private struct Rig {
        let auth: AuthViewModel
        let mock: MockImmichClient
        let keychain: MockKeychainStore
        let defaults: UserDefaults
        let suite: String
    }

    @MainActor
    private func makeRig(stored: Bool = true, configure: (MockImmichClient) -> Void = { _ in }) -> Rig {
        let suite = "StartupRestoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let keychain = MockKeychainStore()
        if stored {
            defaults.set("https://photos.example.com", forKey: AuthViewModel.serverURLDefaultsKey)
            keychain.saveToken("saved-jwt")
        }
        let mock = MockImmichClient()
        configure(mock)
        let auth = AuthViewModel(
            client: mock, keychain: keychain, defaults: defaults,
            realtime: RealtimeService(transport: MockRealtimeTransport())
        )
        return Rig(auth: auth, mock: mock, keychain: keychain, defaults: defaults, suite: suite)
    }

    @MainActor
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    // AC-56: the splash lifts before any request, and the token is validated behind the home screen.
    @MainActor
    func test_AC_56_restoreDoesNotAwaitValidation() async {
        let release = TestBox<CheckedContinuation<Void, Never>?>(nil)
        let rig = makeRig { mock in
            // A server that never answers until the test lets it.
            mock.validateTokenGate = { await withCheckedContinuation { release.value = $0 } }
        }
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        XCTAssertTrue(rig.auth.isRestoringSession, "the splash covers only the frames before the restore starts")
        XCTAssertTrue(rig.auth.isAuthenticated)

        let restore = Task { @MainActor in await rig.auth.restoreSession() }
        await waitUntil("the validation request") { rig.mock.validateTokenCallCount == 1 }

        XCTAssertFalse(rig.auth.isRestoringSession, "no splash while the server is being asked")
        XCTAssertTrue(rig.auth.isAuthenticated)
        XCTAssertEqual(rig.mock.configuredToken, "saved-jwt", "the client is configured before the home screen")

        release.value?.resume()
        await restore.value
        XCTAssertTrue(rig.auth.isAuthenticated, "a validated token keeps the session")
    }

    // AC-56: with nothing stored there is no splash at all.
    @MainActor
    func test_AC_56_noStoredSessionShowsNoSplash() async {
        let rig = makeRig(stored: false)
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        XCTAssertFalse(rig.auth.isRestoringSession)

        await rig.auth.restoreSession()

        XCTAssertFalse(rig.auth.isRestoringSession)
        XCTAssertFalse(rig.auth.isAuthenticated)
        XCTAssertFalse(rig.auth.sessionExpired, "nothing expired: it is a first launch")
    }

    // The restore is the launch's: a second call does not validate again.
    @MainActor
    func test_restoreRunsOncePerInstance() async {
        let rig = makeRig()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }

        await rig.auth.restoreSession()
        await rig.auth.restoreSession()

        XCTAssertEqual(rig.mock.validateTokenCallCount, 1)
    }

    // AC-342: a revoked token ends on the sign-in step in its "expired" state.
    @MainActor
    func test_AC_342_revokedTokenEndsOnExpiredLogin() async {
        let rig = makeRig { $0.validateError = APIError.unauthorized }
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }

        await rig.auth.restoreSession()

        XCTAssertFalse(rig.auth.isAuthenticated)
        XCTAssertTrue(rig.auth.sessionExpired)
        XCTAssertEqual(rig.auth.errorMessage, UserFacingError.sessionExpiredMessage)
        XCTAssertNil(rig.keychain.savedToken, "the refused token is gone")
        XCTAssertEqual(rig.auth.serverURLString, "https://photos.example.com", "the address is pre-filled")
        XCTAssertEqual(OnboardingFlowView.initialPath(startsOnLogin: rig.auth.sessionExpired), [.serverURL, .login])
    }

    // AC-342: the 401 delegate can arrive before the validation's own catch; the result is the same.
    @MainActor
    func test_AC_342_delegateFirstGivesTheSameResult() async {
        let target = TestBox<AuthViewModel?>(nil)
        let rig = makeRig { mock in
            mock.validateTokenGate = {
                await MainActor.run { target.value?.didReceiveUnauthorized() }
                try await Task.sleep(for: .milliseconds(50)) // the delegate's task runs first
            }
            mock.validateError = APIError.unauthorized
        }
        target.value = rig.auth
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }

        await rig.auth.restoreSession()

        XCTAssertFalse(rig.auth.isAuthenticated)
        XCTAssertTrue(rig.auth.sessionExpired)
        XCTAssertEqual(rig.auth.errorMessage, UserFacingError.sessionExpiredMessage)
        XCTAssertNil(rig.keychain.savedToken)
    }

    // A refusal that comes back after another session took over is not that session's.
    @MainActor
    func test_refusalForAReplacedSessionIsIgnored() async {
        let target = TestBox<AuthViewModel?>(nil)
        let rig = makeRig { mock in
            mock.validateTokenGate = { await MainActor.run { target.value?.serverURLString = "https://other.example.com" } }
            mock.validateError = APIError.unauthorized
        }
        target.value = rig.auth
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }

        await rig.auth.restoreSession()

        XCTAssertTrue(rig.auth.isAuthenticated, "the token that was refused is not the current session's")
        XCTAssertFalse(rig.auth.sessionExpired)
        XCTAssertEqual(rig.keychain.savedToken, "saved-jwt")
    }

    // Offline at launch: the session stays, and nothing says it expired.
    @MainActor
    func test_offlineLaunchKeepsTheSession() async {
        let rig = makeRig { $0.validateError = URLError(.notConnectedToInternet) }
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }

        await rig.auth.restoreSession()

        XCTAssertTrue(rig.auth.isAuthenticated)
        XCTAssertFalse(rig.auth.sessionExpired)
        XCTAssertNil(rig.auth.errorMessage)
        XCTAssertEqual(rig.keychain.savedToken, "saved-jwt")
    }
}
