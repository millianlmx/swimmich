import XCTest
@testable import ImmichSwiftUI

/// The sign-in step shows what the server accepts (L-28, B-32.1 / B-32.2).
final class LoginOptionsTests: XCTestCase {

    private func makeAuth(
        mock: MockImmichClient,
        url: String = "https://photos.example.com"
    ) -> (AuthViewModel, UserDefaults, String) {
        let suite = "LoginOptionsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = url
        _ = auth.baseURL
        return (auth, defaults, suite)
    }

    private func config(buttonText: String) -> ServerConfigDto {
        ServerConfigDto(
            oauthButtonText: buttonText, loginPageMessage: "", trashDays: 30, userDeleteDelay: 7,
            isInitialized: true, isOnboarded: true, externalDomain: "", publicUsers: false,
            mapDarkStyleUrl: "", mapLightStyleUrl: "", maintenanceMode: false, minFaces: 3
        )
    }

    private func options(password: Bool, oauth: Bool, text: String? = nil) -> ServerLoginOptions {
        ServerLoginOptions(passwordLogin: password, oauth: oauth, oauthButtonText: text)
    }

    // AC-53: the modes the server accepts decide the form; unreadable modes fall back.
    @MainActor
    func test_AC_53_modesDecideTheForm() async {
        // Both accepted: both shown.
        do {
            let mock = MockImmichClient()
            mock.loginOptionsResponse = options(password: true, oauth: true, text: "Company SSO")
            let (auth, defaults, suite) = makeAuth(mock: mock)
            defer { defaults.removePersistentDomain(forName: suite) }
            await auth.connectServer()
            XCTAssertEqual(auth.loginPresentation.showsPassword, true)
            XCTAssertEqual(auth.loginPresentation.showsSSO, true)
            XCTAssertEqual(auth.loginPresentation.ssoLabel, "Company SSO")
            XCTAssertFalse(auth.loginPresentation.isLoginDisabled)
        }
        // Route missing, then an undecodable answer: the pre-L-28 behavior —
        // the password form, and SSO only when the configuration has a label.
        for failure in [APIError.serverError(404, nil), APIError.decoding("not the features object")] {
            let mock = MockImmichClient()
            mock.serverConfigResponse = config(buttonText: "Config SSO")
            mock.loginOptionsError = failure
            let (auth, defaults, suite) = makeAuth(mock: mock)
            defer { defaults.removePersistentDomain(forName: suite) }
            await auth.connectServer()
            XCTAssertEqual(auth.loginOptionsState, .unreadable)
            XCTAssertFalse(auth.loginOptionsPending, "the fallback is a settled state")
            XCTAssertTrue(auth.loginPresentation.showsPassword)
            XCTAssertTrue(auth.loginPresentation.showsSSO)
            XCTAssertEqual(auth.loginPresentation.ssoLabel, "Config SSO")
            XCTAssertFalse(auth.loginPresentation.isLoginDisabled)
        }
        // Unreadable and no label in the configuration: password only, as today.
        do {
            let mock = MockImmichClient()
            mock.loginOptionsError = APIError.serverError(500, nil)
            let (auth, defaults, suite) = makeAuth(mock: mock)
            defer { defaults.removePersistentDomain(forName: suite) }
            await auth.connectServer()
            XCTAssertTrue(auth.loginPresentation.showsPassword)
            XCTAssertFalse(auth.loginPresentation.showsSSO)
        }
    }

    // AC-330: password refused, OAuth accepted → SSO alone.
    @MainActor
    func test_AC_330_passwordOffShowsSSOOnly() async {
        let mock = MockImmichClient()
        mock.serverVersionResponse = ServerVersionResponseDto(major: 3, minor: 4, patch: 0, prerelease: nil)
        mock.loginOptionsResponse = options(password: false, oauth: true, text: "Sign in with Authentik")
        let (auth, defaults, suite) = makeAuth(mock: mock)
        defer { defaults.removePersistentDomain(forName: suite) }

        await auth.connectServer()

        let presentation = auth.loginPresentation
        XCTAssertFalse(presentation.showsPassword)
        XCTAssertTrue(presentation.showsSSO)
        XCTAssertEqual(presentation.ssoLabel, "Sign in with Authentik")
        XCTAssertFalse(presentation.isLoginDisabled)
        XCTAssertEqual(mock.loginOptionsCalls.count, 1)
        XCTAssertEqual(mock.loginOptionsCalls.first??.major, 3, "read with the version the server announced")
    }

    // AC-331: the features answer wins over a configuration button text.
    @MainActor
    func test_AC_331_featuresOverrideButtonText() async {
        let mock = MockImmichClient()
        mock.serverConfigResponse = config(buttonText: "Company SSO")
        mock.loginOptionsResponse = options(password: true, oauth: false)
        let (auth, defaults, suite) = makeAuth(mock: mock)
        defer { defaults.removePersistentDomain(forName: suite) }

        await auth.connectServer()

        XCTAssertTrue(auth.loginPresentation.showsPassword)
        XCTAssertFalse(auth.loginPresentation.showsSSO)
        XCTAssertFalse(auth.canOAuthLogin)
    }

    // AC-332: OAuth on with no label anywhere → the localized default, and the flow starts.
    @MainActor
    func test_AC_332_emptyLabelFallsBackToLocalizedDefault() async {
        let mock = MockImmichClient()
        mock.serverConfigResponse = config(buttonText: "")
        mock.loginOptionsResponse = options(password: false, oauth: true, text: "   ")
        let (auth, defaults, suite) = makeAuth(mock: mock)
        defer { defaults.removePersistentDomain(forName: suite) }
        await auth.connectServer()

        XCTAssertTrue(auth.loginPresentation.showsSSO)
        XCTAssertEqual(auth.loginPresentation.ssoLabel, String(localized: "Sign in with SSO"))

        auth.oauthSessionHandler = { _ in nil } // the user closes the browser
        await auth.startOAuthFlow()
        XCTAssertNotNil(mock.lastOAuthCodeChallenge, "the SSO path must reach authorize")
    }

    // AC-333: an expired session opens on the sign-in step: it reads the modes itself.
    @MainActor
    func test_AC_333_expiredLoginLoadsOptionsItself() async {
        let suite = "LoginOptionsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        defaults.set("https://photos.example.com", forKey: AuthViewModel.serverURLDefaultsKey)
        keychain.saveToken("revoked-jwt")
        let mock = MockImmichClient()
        mock.validateError = APIError.unauthorized
        mock.serverVersionResponse = ServerVersionResponseDto(major: 3, minor: 4, patch: 0, prerelease: nil)
        mock.loginOptionsResponse = options(password: false, oauth: true, text: "SSO")
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        await auth.restoreSession()
        XCTAssertTrue(auth.sessionExpired)
        XCTAssertTrue(auth.loginOptionsPending, "nothing read yet: the form must not show")

        await auth.loadLoginOptionsIfNeeded()

        XCTAssertFalse(auth.loginOptionsPending)
        XCTAssertFalse(auth.loginPresentation.showsPassword)
        XCTAssertTrue(auth.loginPresentation.showsSSO)
        XCTAssertEqual(mock.loginOptionsCalls.count, 1)
        XCTAssertEqual(mock.loginOptionsCalls.first??.major, 3, "the version was read before the modes")

        await auth.loadLoginOptionsIfNeeded()
        XCTAssertEqual(mock.loginOptionsCalls.count, 1, "a settled state is not read again")
    }

    // AC-334: a changed address drops everything read for the previous server.
    @MainActor
    func test_AC_334_changingServerDropsPreviousOptions() async {
        let mock = MockImmichClient()
        mock.loginOptionsResponse = options(password: true, oauth: false)
        let (auth, defaults, suite) = makeAuth(mock: mock)
        defer { defaults.removePersistentDomain(forName: suite) }
        await auth.connectServer()
        XCTAssertTrue(auth.loginPresentation.showsPassword)

        auth.serverURLString = "https://other.example.com"

        XCTAssertEqual(auth.loginOptionsState, .unknown)
        XCTAssertTrue(auth.loginOptionsPending)

        mock.loginOptionsResponse = options(password: false, oauth: true, text: "SSO")
        await auth.connectServer()
        XCTAssertFalse(auth.loginPresentation.showsPassword)
        XCTAssertTrue(auth.loginPresentation.showsSSO)
    }

    // AC-334: an answer that arrives after the address changed describes nobody.
    @MainActor
    func test_AC_334_lateAnswerForAnotherServerIsIgnored() async {
        let mock = MockImmichClient()
        mock.loginOptionsResponse = options(password: false, oauth: true, text: "SSO")
        let (auth, defaults, suite) = makeAuth(mock: mock)
        defer { defaults.removePersistentDomain(forName: suite) }
        mock.loginOptionsGate = { await MainActor.run { auth.serverURLString = "https://b.example.com" } }

        await auth.connectServer()

        XCTAssertEqual(auth.loginOptionsState, .unknown)
        XCTAssertTrue(auth.loginOptionsPending)
    }

    // A cancelled read says nothing: the next appearance asks again.
    @MainActor
    func test_cancelledReadLeavesTheStateUnknown() async {
        let mock = MockImmichClient()
        mock.loginOptionsError = CancellationError()
        let (auth, defaults, suite) = makeAuth(mock: mock)
        defer { defaults.removePersistentDomain(forName: suite) }

        await auth.connectServer()

        XCTAssertEqual(auth.loginOptionsState, .unknown)
        XCTAssertTrue(auth.loginOptionsPending)

        mock.loginOptionsError = nil
        mock.loginOptionsResponse = options(password: true, oauth: false)
        await auth.loadLoginOptionsIfNeeded()
        XCTAssertEqual(auth.loginOptionsState, .loaded(options(password: true, oauth: false)))
    }

    // A server that cannot be reached reads no modes at all.
    @MainActor
    func test_unreachableServerReadsNoModes() async {
        let mock = MockImmichClient()
        mock.pingError = URLError(.cannotConnectToHost)
        let (auth, defaults, suite) = makeAuth(mock: mock)
        defer { defaults.removePersistentDomain(forName: suite) }

        await auth.connectServer()

        XCTAssertTrue(mock.loginOptionsCalls.isEmpty)
        XCTAssertEqual(auth.loginOptionsState, .unknown)
    }

    // AC-335: neither mode accepted → disabled, and no sign-in request can leave.
    @MainActor
    func test_AC_335_bothOffDisablesLogin() async {
        let mock = MockImmichClient()
        mock.loginOptionsResponse = options(password: false, oauth: false)
        let (auth, defaults, suite) = makeAuth(mock: mock)
        defer { defaults.removePersistentDomain(forName: suite) }
        await auth.connectServer()

        let presentation = auth.loginPresentation
        XCTAssertTrue(presentation.isLoginDisabled)
        XCTAssertFalse(presentation.showsPassword)
        XCTAssertFalse(presentation.showsSSO)

        await auth.login(email: "alice@example.com", password: "secret")

        XCTAssertNil(mock.lastLoginBody, "a server that refuses the password never receives one")
        XCTAssertNil(auth.accessToken)
        XCTAssertFalse(auth.isLoading)
    }
}
