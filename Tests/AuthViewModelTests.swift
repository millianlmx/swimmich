import XCTest
@testable import ImmichSwiftUI

final class AuthViewModelTests: XCTestCase {

    // AC-003: login sends {email,password} to POST /api/auth/login.
    @MainActor
    func test_AC_003_loginSendsCorrectBody() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://example.com"
        _ = auth.baseURL

        await auth.login(email: "test@example.com", password: "secret123")

        XCTAssertEqual(mock.lastLoginBody?.email, "test@example.com")
        XCTAssertEqual(mock.lastLoginBody?.password, "secret123")
        XCTAssertGreaterThan(mock.requestCount, 0)
    }

    // AC-004: on login success, JWT is persisted to Keychain.
    @MainActor
    func test_AC_004_loginPersistsTokenToKeychain() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = LoginResponseDto(
            accessToken: "fake-jwt", userId: "u", userEmail: "t@e.com", name: "T",
            profileImagePath: "", isAdmin: false, shouldChangePassword: false, isOnboarded: true
        )
        let keychain = MockKeychainStore()
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://example.com"
        _ = auth.baseURL

        await auth.login(email: "t@e.com", password: "secret")
        XCTAssertEqual(keychain.savedToken, "fake-jwt")
        XCTAssertTrue(auth.isAuthenticated)
    }

    // AC-005: logout clears Keychain + isAuthenticated = false.
    @MainActor
    func test_AC_005_logoutClearsKeychainAndIsAuthenticated() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = LoginResponseDto(
            accessToken: "pre-jwt", userId: "u", userEmail: "t@e.com", name: "T",
            profileImagePath: "", isAdmin: false, shouldChangePassword: false, isOnboarded: true
        )
        let keychain = MockKeychainStore()
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://example.com"
        _ = auth.baseURL

        await auth.login(email: "t@e.com", password: "secret")
        XCTAssertEqual(keychain.savedToken, "pre-jwt")

        await auth.logout()
        XCTAssertNil(keychain.savedToken)
        XCTAssertFalse(auth.isAuthenticated)
    }

    // G18: the server's shouldChangePassword flag rides the session — filled at
    // login from `LoginResponseDto`, cleared only when the password changes, and
    // never written to UserDefaults.
    @MainActor
    func test_G18_loginCarriesShouldChangePasswordFlag() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = LoginResponseDto(
            accessToken: "jwt", userId: "u1", userEmail: "alice@example.com", name: "Alice",
            profileImagePath: "", isAdmin: false, shouldChangePassword: true, isOnboarded: true
        )
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://example.com"
        _ = auth.baseURL

        await auth.login(email: "alice@example.com", password: "secret")

        XCTAssertTrue(auth.shouldChangePassword, "an administrator reset this password, and the server says so at sign-in")

        auth.notePasswordChanged()
        XCTAssertFalse(auth.shouldChangePassword)

        // Simulated relaunch: the flag belongs to the server, so a fresh VM must
        // not read it back out of the preferences (unlike `isAdmin`).
        let restored = AuthViewModel(client: MockImmichClient(), keychain: MockKeychainStore(), defaults: defaults)
        XCTAssertFalse(restored.shouldChangePassword)
    }

    // G18: the flag is re-read from the server, so a reset that happens while the
    // session is open does not wait for the next sign-in — and an unreachable
    // server leaves the flag as it was.
    @MainActor
    func test_G18_refreshShouldChangePasswordFollowsTheServer() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://example.com"
        _ = auth.baseURL
        mock.currentUserResponse = UserAdminResponseDto(
            id: "me", name: "Me", email: "me@example.com", profileImagePath: nil,
            avatarColor: nil, profileChangedAt: nil, shouldChangePassword: true
        )

        await auth.refreshShouldChangePassword()
        XCTAssertTrue(auth.shouldChangePassword)

        mock.currentUserError = URLError(.notConnectedToInternet)
        await auth.refreshShouldChangePassword()
        XCTAssertTrue(auth.shouldChangePassword, "a failed re-read cannot answer a question only the server can")

        mock.currentUserError = nil
        mock.currentUserResponse = UserAdminResponseDto(
            id: "me", name: "Me", email: "me@example.com", profileImagePath: nil,
            avatarColor: nil, profileChangedAt: nil, shouldChangePassword: false
        )
        await auth.refreshShouldChangePassword()
        XCTAssertFalse(auth.shouldChangePassword)
    }

    // AC-012: unreachable server → status = .unreachable, isAuthenticated = false.
    @MainActor
    func test_AC_012_connectServerUnreachable() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.pingError = URLError(.cannotConnectToHost)

        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://example.com"
        _ = auth.baseURL

        await auth.connectServer()
        XCTAssertEqual(auth.serverStatus, .unreachable)
        XCTAssertFalse(auth.isAuthenticated)
    }

    // AC-012b: ping response decoded as ServerPingResponse JSON {"res":"pong"} → reachable.
    @MainActor
    func test_AC_012b_pingDecodedAndReachable() async throws {
        let json = #"{"res":"pong"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder.immich.decode(ServerPingResponse.self, from: json)
        XCTAssertEqual(decoded.res, "pong")

        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.pingResponse = ServerPingResponse(res: "pong")
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://example.com"
        _ = auth.baseURL

        await auth.connectServer()
        if case .reachable = auth.serverStatus {
            // ok
        } else {
            XCTFail("expected .reachable, got \(auth.serverStatus)")
        }
    }

    // MARK: - Session restore (auth persistence across relaunch)

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "AuthViewModelTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// Seed a stored session: server URL in defaults + token in keychain.
    private func makeStoredSession(defaults: UserDefaults, keychain: MockKeychainStore, url: String = "https://photos.example.com", token: String = "saved-jwt") {
        defaults.set(url, forKey: AuthViewModel.serverURLDefaultsKey)
        keychain.saveToken(token)
    }

    // AC-720: valid stored session → client reconfigured + stays authenticated.
    @MainActor
    func test_restoreSession_restoresSessionAndConfiguresClient() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        makeStoredSession(defaults: defaults, keychain: keychain)
        let mock = MockImmichClient()
        mock.serverConfigResponse = ServerConfigDto(
            oauthButtonText: "", loginPageMessage: "", trashDays: 30, userDeleteDelay: 7,
            isInitialized: true, isOnboarded: true, externalDomain: "https://photos.public.example",
            publicUsers: false, mapDarkStyleUrl: "", mapLightStyleUrl: "",
            maintenanceMode: false, minFaces: 3
        )
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)

        XCTAssertTrue(auth.isAuthenticated, "token restored from keychain")
        XCTAssertEqual(auth.serverURLString, "https://photos.example.com")

        await auth.restoreSession()

        XCTAssertEqual(mock.configuredToken, "saved-jwt", "client must be reconfigured at startup")
        XCTAssertEqual(mock.configuredBaseURL?.absoluteString, "https://photos.example.com")
        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertFalse(auth.isRestoringSession)
        // validateToken + serverConfig. The config is what carries
        // `externalDomain`, and it used to be fetched only while walking
        // onboarding — so a relaunched session could not build a public shared
        // link URL pointing at the server's public domain.
        XCTAssertEqual(mock.requestCount, 2, "validateToken then serverConfig")
        XCTAssertEqual(auth.serverConfig?.externalDomain, "https://photos.public.example",
                       "a relaunch must learn the public domain, not only the onboarding walk")
    }

    // AC-720: invalid token → session reset + keychain cleared (clean re-login).
    @MainActor
    func test_restoreSession_invalidToken_resetsSession() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        makeStoredSession(defaults: defaults, keychain: keychain)
        let mock = MockImmichClient()
        mock.validateError = APIError.unauthorized
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)

        await auth.restoreSession()

        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertNil(keychain.savedToken, "rejected token must be deleted")
        XCTAssertNil(auth.userEmail)
        XCTAssertEqual(defaults.string(forKey: AuthViewModel.serverURLDefaultsKey), "https://photos.example.com", "server URL survives for next sign-in")
    }

    // AC-720: offline at launch → session kept (never wipe on transient network error).
    @MainActor
    func test_restoreSession_networkError_keepsSession() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        makeStoredSession(defaults: defaults, keychain: keychain)
        let mock = MockImmichClient()
        mock.validateError = URLError(.notConnectedToInternet)
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)

        await auth.restoreSession()

        XCTAssertTrue(auth.isAuthenticated, "offline launch must not wipe the session")
        XCTAssertEqual(keychain.savedToken, "saved-jwt")
    }

    // AC-720: nothing stored → clean reset (no crash, onboarding shows).
    @MainActor
    func test_restoreSession_noStoredSession_resets() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)

        await auth.restoreSession()

        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertFalse(auth.isRestoringSession)
        XCTAssertEqual(mock.requestCount, 0, "no validation without a session")
    }

    // AC-7: a 401 on a signed-in session shows the expiry copy, returns to
    // sign-in and keeps the stored session (token + identity) intact.
    @MainActor
    func test_AC7_unauthorizedShowsSessionExpiredAndKeepsStoredToken() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let mock = MockImmichClient()
        mock.loginResponse = LoginResponseDto(
            accessToken: "jwt", userId: "u1", userEmail: "alice@example.com", name: "Alice",
            profileImagePath: "", isAdmin: false, shouldChangePassword: false, isOnboarded: true
        )
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL
        await auth.login(email: "alice@example.com", password: "secret")
        XCTAssertTrue(auth.isAuthenticated, "precondition: signed in")

        auth.didReceiveUnauthorized()
        // The handler runs in a @MainActor Task: let it settle before asserting.
        for _ in 0..<100 where auth.isAuthenticated { await Task.yield() }

        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertTrue(auth.sessionExpired)
        XCTAssertEqual(auth.errorMessage, localizedString("Your session has expired. Please sign in again."))
        XCTAssertNotNil(keychain.getToken(), "a 401 must not wipe the stored token")
        XCTAssertFalse(auth.savedAccounts.isEmpty, "saved accounts must survive a 401")
        XCTAssertEqual(defaults.string(forKey: AuthViewModel.userEmailDefaultsKey), "alice@example.com")
    }

    // AC-7: after a session expiry the onboarding flow opens directly on LoginScreen
    // (path [.serverURL, .login]), not on WelcomeScreen; a normal launch starts empty.
    @MainActor
    func test_AC7_sessionExpiredOpensOnLoginScreen() {
        XCTAssertEqual(
            OnboardingFlowView.initialPath(startsOnLogin: true),
            [OnboardingFlowView.Step.serverURL, .login]
        )
        XCTAssertEqual(OnboardingFlowView.initialPath(startsOnLogin: false), [])
    }

    // AC-721: login persists server URL + user identity for next relaunch.
    @MainActor
    func test_login_persistsServerURLAndIdentity() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = LoginResponseDto(
            accessToken: "jwt", userId: "u1", userEmail: "alice@example.com", name: "Alice",
            profileImagePath: "", isAdmin: false, shouldChangePassword: false, isOnboarded: true
        )
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "photos.example.com"
        _ = auth.baseURL

        await auth.login(email: "alice@example.com", password: "secret")

        XCTAssertEqual(defaults.string(forKey: AuthViewModel.serverURLDefaultsKey), "https://photos.example.com")
        XCTAssertEqual(defaults.string(forKey: AuthViewModel.userEmailDefaultsKey), "alice@example.com")
        XCTAssertEqual(defaults.string(forKey: AuthViewModel.userNameDefaultsKey), "Alice")
        XCTAssertEqual(defaults.string(forKey: AuthViewModel.userIdDefaultsKey), "u1")
    }

    // Album share: isAdmin is persisted at login and restored on relaunch —
    // the "Shared With" sheet needs it to pick the right empty-state message.
    @MainActor
    func test_login_persistsAndRestoresIsAdmin() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = LoginResponseDto(
            accessToken: "jwt", userId: "u1", userEmail: "admin@example.com", name: "Admin",
            profileImagePath: "", isAdmin: true, shouldChangePassword: false, isOnboarded: true
        )
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "photos.example.com"
        _ = auth.baseURL

        await auth.login(email: "admin@example.com", password: "secret")
        XCTAssertTrue(auth.isAdmin)
        XCTAssertTrue(defaults.bool(forKey: AuthViewModel.isAdminDefaultsKey))

        // Simulated relaunch: a fresh VM reads the stored flag.
        let restored = AuthViewModel(client: MockImmichClient(), keychain: MockKeychainStore(), defaults: defaults)
        XCTAssertTrue(restored.isAdmin, "isAdmin must survive relaunch")
    }

    // MARK: - Self-signed cert trust (P5)

    @MainActor
    func test_connectServer_tlsErrorSetsPendingUntrustedHost() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.pingError = URLError(.serverCertificateUntrusted)
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL

        await auth.connectServer()

        XCTAssertEqual(auth.serverStatus, .unreachable)
        XCTAssertEqual(auth.pendingUntrustedHost, "photos.example.com")
    }

    @MainActor
    func test_connectServer_networkErrorDoesNotSetTrustHost() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.pingError = URLError(.timedOut)
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL

        await auth.connectServer()

        XCTAssertEqual(auth.serverStatus, .unreachable)
        XCTAssertNil(auth.pendingUntrustedHost)
    }

    @MainActor
    func test_trustPendingServer_addsHostAndReconnects() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let trustSuite = "trustVM-\(UUID().uuidString)"
        let trustDefaults = UserDefaults(suiteName: trustSuite)!
        defer { trustDefaults.removePersistentDomain(forName: trustSuite) }
        let trustStore = TrustedServerStoreImpl(defaults: trustDefaults)

        let mock = MockImmichClient()
        // First ping fails TLS, second succeeds (after trust).
        mock.pingResSequences = [.init(res: "pong")]
        mock.pingError = URLError(.serverCertificateUntrusted)
        let auth = AuthViewModel(
            client: mock, keychain: MockKeychainStore(), defaults: defaults, trustStore: trustStore
        )
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL

        await auth.connectServer()
        XCTAssertEqual(auth.pendingUntrustedHost, "photos.example.com")

        // After trust: no TLS error anymore.
        mock.pingError = nil
        await auth.trustPendingServer()

        XCTAssertTrue(trustStore.contains("photos.example.com"))
        XCTAssertNil(auth.pendingUntrustedHost)
        guard case .reachable = auth.serverStatus else {
            return XCTFail("Expected reachable, got \(auth.serverStatus)")
        }
    }

    // MARK: - OAuth (P5)

    private func makeOAuthConfig() -> ServerConfigDto {
        ServerConfigDto(
            oauthButtonText: "Continue with Immich SSO", loginPageMessage: "", trashDays: 30,
            userDeleteDelay: 7, isInitialized: true, isOnboarded: true, externalDomain: "",
            publicUsers: false, mapDarkStyleUrl: "", mapLightStyleUrl: "",
            maintenanceMode: false, minFaces: 0
        )
    }

    private func makeOAuthConfigEmptyText() -> ServerConfigDto {
        ServerConfigDto(
            oauthButtonText: "", loginPageMessage: "", trashDays: 30,
            userDeleteDelay: 7, isInitialized: true, isOnboarded: true, externalDomain: "",
            publicUsers: false, mapDarkStyleUrl: "", mapLightStyleUrl: "",
            maintenanceMode: false, minFaces: 0
        )
    }

    @MainActor
    func test_oauth_canOAuthLogin_requiresButtonText() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthViewModel(client: MockImmichClient(), keychain: MockKeychainStore(), defaults: defaults)
        auth.serverConfig = makeOAuthConfig()

        XCTAssertTrue(auth.canOAuthLogin)
        auth.serverConfig = makeOAuthConfigEmptyText()
        XCTAssertFalse(auth.canOAuthLogin)
        auth.serverConfig = nil
        XCTAssertFalse(auth.canOAuthLogin)
    }

    @MainActor
    func test_oauth_flowExchangesCodeAndAppliesSession() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.oauthCallbackResponse = LoginResponseDto(
            accessToken: "oauth-jwt", userId: "u-oauth", userEmail: "alice@sso.example.com",
            name: "OAuth Alice", profileImagePath: "", isAdmin: true,
            shouldChangePassword: false, isOnboarded: true
        )
        let keychain = MockKeychainStore()
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL
        auth.serverConfig = makeOAuthConfig()
        auth.oauthSessionHandler = { url in
            XCTAssertEqual(url.absoluteString, "https://sso.example.com/authorize")
            return URL(string: "app.immich:///oauth-callback?code=abc")
        }

        await auth.startOAuthFlow()

        XCTAssertEqual(mock.lastOAuthRedirectURI, AuthViewModel.oauthRedirectURI)
        XCTAssertEqual(mock.lastOAuthCallbackURL, "app.immich:///oauth-callback?code=abc")
        // The verifier's challenge is what the provider received; the raw
        // verifier is only replayed on the callback.
        XCTAssertNotNil(mock.lastOAuthCodeChallenge)
        XCTAssertNotEqual(mock.lastOAuthCodeChallenge, mock.lastOAuthCodeVerifier)
        // Same `state` on both legs, or the server rejects the callback.
        XCTAssertEqual(mock.lastOAuthState, mock.lastOAuthCallbackState)
        XCTAssertNotNil(mock.lastOAuthState)
        XCTAssertEqual(keychain.savedToken, "oauth-jwt")
        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertTrue(auth.isAdmin)
        XCTAssertEqual(auth.userName, "OAuth Alice")
        XCTAssertEqual(auth.userId, "u-oauth")
    }

    @MainActor
    func test_oauth_cancelLeavesStateUntouched() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        let keychain = MockKeychainStore()
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL
        auth.serverConfig = makeOAuthConfig()
        auth.oauthSessionHandler = { _ in nil }

        await auth.startOAuthFlow()

        XCTAssertNil(auth.accessToken)
        XCTAssertNil(keychain.savedToken)
        XCTAssertNil(auth.errorMessage)
        XCTAssertEqual(mock.requestCount, 1, "Only the mobile-URL call; no callback exchange")
        XCTAssertFalse(auth.isLoading, "Cancelling must clear the in-flight flag — the login CTA stays disabled otherwise")
    }

    @MainActor
    func test_oauth_malformedProviderURLResetsLoading() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.oauthAuthorizeResponse = OAuthAuthorizeResponseDto(url: "")
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL
        auth.serverConfig = makeOAuthConfig()
        auth.oauthSessionHandler = { _ in
            XCTFail("No browser session should open for a malformed provider URL")
            return nil
        }

        await auth.startOAuthFlow()

        XCTAssertEqual(auth.errorMessage, localizedString("The server returned an invalid OAuth URL."))
        XCTAssertNil(auth.accessToken)
        XCTAssertFalse(auth.isLoading)
    }

    @MainActor
    func test_oauth_failureSetsError() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.oauthError = APIError.serverError(500, "boom")
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL
        auth.serverConfig = makeOAuthConfig()
        auth.oauthSessionHandler = { _ in URL(string: "app.immich:///oauth-callback?code=abc") }

        await auth.startOAuthFlow()

        XCTAssertNil(auth.accessToken)
        XCTAssertEqual(auth.errorMessage, localizedString("The server ran into a problem. Please try again."))
    }

    @MainActor
    func test_oauth_disabledOnServerIsNoOp() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL
        auth.oauthSessionHandler = { _ in URL(string: "app.immich:///oauth-callback?code=abc") }

        await auth.startOAuthFlow()

        XCTAssertNil(auth.accessToken)
        XCTAssertEqual(auth.errorMessage, localizedString("OAuth is not enabled on this server."))
        XCTAssertEqual(mock.requestCount, 0)
    }

    // MARK: - Multi-server / multi-account (P5)

    private func makeLoginAccount(url: String = "https://photos.example.com", email: String = "alice@example.com", name: String = "Alice", userId: String = "u1") -> SavedAccount {
        SavedAccount(url: url, email: email, name: name, userId: userId, isAdmin: false)
    }

    private func seedSavedAccounts(_ accounts: [SavedAccount], defaults: UserDefaults) {
        defaults.set(try! JSONEncoder.immich.encode(accounts), forKey: AuthViewModel.serverListDefaultsKey)
    }

    @MainActor
    func test_login_addsAccountToSavedWithPerAccountToken() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = LoginResponseDto(
            accessToken: "jwt", userId: "u1", userEmail: "alice@example.com", name: "Alice",
            profileImagePath: "", isAdmin: false, shouldChangePassword: false, isOnboarded: true
        )
        let keychain = MockKeychainStore()
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL

        await auth.login(email: "alice@example.com", password: "secret")

        XCTAssertEqual(auth.savedAccounts.count, 1)
        XCTAssertEqual(auth.savedAccounts.first?.email, "alice@example.com")
        let accountID = SavedAccount.makeID(url: "https://photos.example.com", email: "alice@example.com", userId: "u1")
        XCTAssertEqual(keychain.getToken(for: accountID), "jwt", "token must be stored per-account")
    }

    @MainActor
    func test_login_sameAccountDedupsRegistry() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = LoginResponseDto(
            accessToken: "jwt2", userId: "u1", userEmail: "alice@example.com", name: "Alice",
            profileImagePath: "", isAdmin: false, shouldChangePassword: false, isOnboarded: true
        )
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL

        await auth.login(email: "alice@example.com", password: "s1")
        await auth.login(email: "alice@example.com", password: "s2")

        XCTAssertEqual(auth.savedAccounts.count, 1, "same account must be upserted, not duplicated")
    }

    @MainActor
    func test_multipleAccountsSameServer_coexist() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let auth = AuthViewModel(client: MockImmichClient(), keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL

        let alice = makeLoginAccount(email: "alice@example.com", userId: "u1")
        let bob = makeLoginAccount(email: "bob@example.com", userId: "u2")
        keychain.saveToken("alice-jwt", for: alice.id)
        keychain.saveToken("bob-jwt", for: bob.id)
        seedSavedAccounts([alice, bob], defaults: defaults)

        let restored = AuthViewModel(client: MockImmichClient(), keychain: keychain, defaults: defaults)
        XCTAssertEqual(restored.savedAccounts.count, 2)
        XCTAssertNotEqual(alice.id, bob.id, "two accounts on the same URL must have distinct ids")
    }

    @MainActor
    func test_switchToAccount_restoresTokenAndIdentity() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let alice = makeLoginAccount(email: "alice@example.com", userId: "u1")
        let bob = SavedAccount(url: "https://photos.example.com", email: "bob@example.com", name: "Bob", userId: "u2", isAdmin: true)
        keychain.saveToken("alice-jwt", for: alice.id)
        keychain.saveToken("bob-jwt", for: bob.id)
        seedSavedAccounts([alice, bob], defaults: defaults)

        let mock = MockImmichClient()
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        // Act as Alice first.
        auth.serverURLString = "https://photos.example.com"
        auth.userEmail = "alice@example.com"
        auth.userName = "Alice"
        auth.userId = "u1"
        auth.accessToken = "alice-jwt"

        await auth.switchToAccount(bob)

        XCTAssertEqual(auth.accessToken, "bob-jwt")
        XCTAssertEqual(auth.userEmail, "bob@example.com")
        XCTAssertEqual(auth.userName, "Bob")
        XCTAssertEqual(auth.userId, "u2")
        XCTAssertTrue(auth.isAdmin)
        XCTAssertEqual(mock.configuredToken, "bob-jwt")
        XCTAssertEqual(mock.configuredBaseURL?.absoluteString, "https://photos.example.com")
        XCTAssertTrue(auth.isAuthenticated)
    }

    @MainActor
    func test_switchToAccount_missingToken_resetsSessionWithURLPrefilled() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let ghost = makeLoginAccount(email: "ghost@example.com", userId: "u9")
        seedSavedAccounts([ghost], defaults: defaults)

        let auth = AuthViewModel(client: MockImmichClient(), keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        auth.accessToken = "current-jwt"

        await auth.switchToAccount(ghost)

        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(auth.serverURLString, "https://photos.example.com", "URL pre-filled for re-login")
    }

    @MainActor
    func test_switchToAccount_invalidToken_resetsSession() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let bob = makeLoginAccount(email: "bob@example.com", userId: "u2")
        keychain.saveToken("stale-jwt", for: bob.id)
        seedSavedAccounts([bob], defaults: defaults)

        let mock = MockImmichClient()
        mock.validateError = APIError.unauthorized
        let auth = AuthViewModel(client: mock, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        auth.accessToken = "current-jwt"

        await auth.switchToAccount(bob)

        XCTAssertFalse(auth.isAuthenticated, "rejected token must reset the session")
        XCTAssertEqual(auth.serverURLString, "https://photos.example.com")
    }

    @MainActor
    func test_removeSavedAccount_deletesTokenAndRegistry() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let alice = makeLoginAccount(email: "alice@example.com", userId: "u1")
        let bob = makeLoginAccount(email: "bob@example.com", userId: "u2")
        keychain.saveToken("alice-jwt", for: alice.id)
        keychain.saveToken("bob-jwt", for: bob.id)
        seedSavedAccounts([alice, bob], defaults: defaults)

        let auth = AuthViewModel(client: MockImmichClient(), keychain: keychain, defaults: defaults)

        auth.removeSavedAccount(bob)

        XCTAssertEqual(auth.savedAccounts.count, 1)
        XCTAssertEqual(auth.savedAccounts.first?.id, alice.id)
        XCTAssertNil(keychain.getToken(for: bob.id))
        XCTAssertEqual(keychain.getToken(for: alice.id), "alice-jwt", "other account's token untouched")
    }

    @MainActor
    func test_removeActiveAccount_resetsSession() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let alice = makeLoginAccount(email: "alice@example.com", userId: "u1")
        keychain.saveToken("alice-jwt", for: alice.id)
        seedSavedAccounts([alice], defaults: defaults)

        let auth = AuthViewModel(client: MockImmichClient(), keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        auth.userEmail = "alice@example.com"
        auth.userId = "u1"
        auth.accessToken = "alice-jwt"

        auth.removeSavedAccount(alice)

        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(auth.savedAccounts.count, 0)
    }

    @MainActor
    func test_addNewServer_resetsAndClearsURL() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthViewModel(client: MockImmichClient(), keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://photos.example.com"
        auth.accessToken = "jwt"

        auth.addNewServer()

        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(auth.serverURLString, "")
    }
}
