import Foundation
import ImmichSharedKit
import SwiftUI

/// Authoritative app-wide auth state. Drives RootView routing.
///
/// FM-4: implements AuthSessionDelegate so any 401 anywhere resets state.
///
/// Session persistence: the bearer token lives in the Keychain; the server URL
/// + user identity live in UserDefaults. `restoreSession()` reconfigures the
/// shared `ImmichClient` on launch (it is otherwise only configured during
/// login/server discovery), so the app stays authenticated across relaunches.
@MainActor
@Observable
final class AuthViewModel: AuthSessionDelegate {
    enum ServerStatus: Equatable {
        case idle
        case checking
        case reachable(version: ServerVersionResponseDto?)
        case unreachable
    }

    // UserDefaults keys (internal so tests can seed/assert).
    static let serverURLDefaultsKey = "authServerURL"
    static let serverListDefaultsKey = "authServerList"
    static let userEmailDefaultsKey = "authUserEmail"
    static let userNameDefaultsKey = "authUserName"
    static let userIdDefaultsKey = "authUserId"
    static let isAdminDefaultsKey = "authIsAdmin"

    /// Must match the `CFBundleURLTypes` scheme *and* the value whitelisted at
    /// the OIDC provider — this is the exact URI the Immich docs publish.
    static let oauthRedirectURI = "app.immich:///oauth-callback"

    /// Injectable browser-session hook. Production default runs an
    /// `ASWebAuthenticationSession`; tests inject a mock closure.
    var oauthSessionHandler: (URL) async -> URL? = { url in
        await OAuthSessionPresenter.present(url)
    }

    // Server connection
    var serverURLString: String = "" {
        didSet { _cachedBaseURL = nil }
    }
    var serverStatus: ServerStatus = .idle
    var serverConfig: ServerConfigDto?

    // Session
    var accessToken: String?
    var userEmail: String?
    var userName: String?
    var userId: String?
    var isAdmin: Bool = false
    /// Server-side flag: an administrator reset this account's password, so the
    /// server asks for a new one at the next sign-in (gap G18).
    ///
    /// Session state, never a preference: it is filled from the `LoginResponseDto`
    /// of both login paths, re-read from `GET /api/users/me`, and dropped when
    /// the password actually changes. Unlike `isAdmin` it is **not** written to
    /// `UserDefaults` — the server owns it, so a stale copy must not outlive the
    /// session.
    var shouldChangePassword: Bool = false
    var isAuthenticated: Bool { accessToken != nil }

    /// Saved accounts (server URL + identity) for the multi-server /
    /// multi-account switcher (P5 multi-server). Persisted as JSON under
    /// `serverListDefaultsKey`.
    private(set) var savedAccounts: [SavedAccount] = []

    /// Stable identity of the active account. Drives the switcher checkmark
    /// and the RootView `.id(...)` that rebuilds the tab subtree on switch.
    var activeAccountID: String? {
        SavedAccount.makeID(url: baseURL?.absoluteString ?? serverURLString, email: userEmail, userId: userId)
    }

    /// True while `restoreSession()` reconfigures the client + validates the
    /// stored token. RootView gates on this to avoid a TabView→onboarding
    /// flash before validation settles.
    var isRestoringSession: Bool = false

    // UI
    var isLoading: Bool = false
    var errorMessage: String?
    /// True after a 401 on an authenticated session; cleared by a new sign-in.
    private(set) var sessionExpired = false

    private let client: any ImmichClient
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let trustStore: TrustedServerStore
    private let realtime: RealtimeService
    /// Publishes the credentials widgets need (issue #19): a widget runs in its
    /// own process and cannot read this object, so every sign-in, restore and
    /// account switch mirrors the session into the shared keychain.
    private let widgetSession: any WidgetSessionStoring
    private var _cachedBaseURL: URL?

    init(
        client: any ImmichClient,
        keychain: KeychainStore,
        defaults: UserDefaults = .standard,
        trustStore: TrustedServerStore = TrustedServerStoreImpl(),
        realtime: RealtimeService = RealtimeService(),
        widgetSession: any WidgetSessionStoring = WidgetSessionStore()
    ) {
        self.client = client
        self.keychain = keychain
        self.defaults = defaults
        self.trustStore = trustStore
        self.realtime = realtime
        self.widgetSession = widgetSession
        self.serverURLString = defaults.string(forKey: Self.serverURLDefaultsKey) ?? ""
        self.userEmail = defaults.string(forKey: Self.userEmailDefaultsKey)
        self.userName = defaults.string(forKey: Self.userNameDefaultsKey)
        self.userId = defaults.string(forKey: Self.userIdDefaultsKey)
        self.isAdmin = defaults.bool(forKey: Self.isAdminDefaultsKey)
        self.accessToken = keychain.getToken()
        self.savedAccounts = Self.loadSavedAccounts(from: defaults)
        self.client.authDelegate = self
    }

    // MARK: - Session restore (relaunch)

    /// Reconfigures the shared client from the stored session and validates
    /// the token. Called by RootView via `.task` on launch.
    ///
    /// - Valid token → stays authenticated (no-op beyond configuring the client).
    /// - `.unauthorized` → `resetSession()` (clean sign-in again, URL pre-filled).
    /// - Network failure → keeps the session (offline-safe; a real 401 later
    ///   still resets via FM-4).
    func restoreSession() async {
        guard !isRestoringSession else { return }
        isRestoringSession = true
        defer { isRestoringSession = false }

        guard let token = accessToken, let url = baseURL else {
            resetSession()
            return
        }
        client.configure(baseURL: url, token: token)
        do {
            _ = try await client.validateToken()
        } catch APIError.unauthorized {
            resetSession()
        } catch {
            // Network / decode: keep the session; don't wipe on transient offline.
        }
        // `serverConfig` is otherwise only fetched by `connectServer()`, i.e.
        // while walking onboarding. A relaunch with a stored session would
        // therefore leave `externalDomain` unknown — and the public URL of a
        // shared link would fall back to the server's internal address.
        if isAuthenticated {
            serverConfig = try? await client.serverConfig()
            publishWidgetSession()
        }
    }

    /// Mirrors the active session into the shared keychain group the widget
    /// extension reads. Called on every path that establishes a session
    /// (password login, OAuth, stored-session restore, account switch) — a
    /// widget cannot see any of this state otherwise, and a stale mirror shows
    /// the previous account's photos.
    func publishWidgetSession() {
        guard let token = accessToken, let baseURL else { return }
        // The widget cannot read this process' trust store (a different
        // container), so a host whose certificate the user accepted travels
        // with the session — without it a self-signed server is unreachable
        // from the widget even though the app opens it fine.
        let host = baseURL.host
        let trustedHosts = (host.flatMap { trustStore.contains($0) ? $0 : nil }).map { [$0] } ?? []
        widgetSession.save(WidgetSession(
            baseURL: baseURL.absoluteString,
            token: token,
            userName: userName,
            userId: userId,
            trustedHosts: trustedHosts,
            // The share extension uploads from its own process and reads this
            // snapshot; without the id its assets would show up as a second
            // device in the web UI's per-device filter.
            deviceId: DeviceIdentity.current
        ))
    }

    // MARK: - URL helpers

    /// Normalizes a raw user-entered URL string into a base URL.
    /// Trims trailing slash, defaults scheme to https.
    func normalizedBaseURL(from raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }

    var baseURL: URL? {
        if let cached = _cachedBaseURL { return cached }
        let url = normalizedBaseURL(from: serverURLString)
        _cachedBaseURL = url
        return url
    }

    // MARK: - Server discovery

    @MainActor
    func connectServer() async {
        guard let url = baseURL else {
            serverStatus = .unreachable
            errorMessage = String(localized: "Enter a valid server URL.")
            return
        }
        serverStatus = .checking
        errorMessage = nil
        pendingUntrustedHost = nil
        client.configure(baseURL: url, token: keychain.getToken())
        do {
            let ping = try await client.ping()
            if ping.res == "pong" {
                let version = try? await client.serverVersion()
                serverStatus = .reachable(version: version)
                serverConfig = try? await client.serverConfig()
                defaults.set(url.absoluteString, forKey: Self.serverURLDefaultsKey)
            } else {
                serverStatus = .unreachable
            }
        } catch let e as URLError where Self.isTLSError(e) {
            // P5 selfsigned-cert: surface the host so the UI can offer to
            // trust it explicitly.
            serverStatus = .unreachable
            errorMessage = String(localized: "This server’s certificate can’t be verified.")
            pendingUntrustedHost = url.host
        } catch {
            serverStatus = .unreachable
        }
    }

    /// Host whose TLS certificate failed validation (P5 selfsigned-cert).
    var pendingUntrustedHost: String?

    /// Persists the pending host as trusted and re-runs connectivity.
    @MainActor
    func trustPendingServer() async {
        guard let host = pendingUntrustedHost else { return }
        trustStore.add(host)
        pendingUntrustedHost = nil
        await connectServer()
    }

    /// TLS certificate failures that warrant the explicit trust flow.
    static func isTLSError(_ error: URLError) -> Bool {
        switch error.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    // MARK: - Auth

    @MainActor
    func login(email: String, password: String) async {
        guard baseURL != nil else {
            errorMessage = String(localized: "Connect to a server first.")
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let response = try await client.login(email: email, password: password)
            applySession(
                token: response.accessToken,
                email: response.userEmail,
                name: response.name,
                userId: response.userId,
                isAdmin: response.isAdmin,
                shouldChangePassword: response.shouldChangePassword
            )
        } catch let e {
            errorMessage = e.userFacingMessage
        }
        isLoading = false
    }

    // MARK: - OAuth (P5)

    /// True when the server exposes OAuth (non-empty `oauthButtonText`).
    var canOAuthLogin: Bool {
        guard let text = serverConfig?.oauthButtonText else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Mobile OAuth flow (P5): POST /oauth/authorize for the provider URL →
    /// browser session → POST /oauth/callback with the PKCE verifier → apply
    /// the session like a normal login. Cancelling the browser leaves the
    /// current state untouched.
    @MainActor
    func startOAuthFlow() async {
        guard baseURL != nil, canOAuthLogin else {
            errorMessage = String(localized: "OAuth is not enabled on this server.")
            return
        }
        isLoading = true
        // Every exit below — cancel, malformed provider URL, network failure,
        // success — must clear the flag; the login CTA stays disabled otherwise.
        defer { isLoading = false }
        errorMessage = nil
        do {
            let pkce = OAuthPKCE()
            let authorize = try await client.authorizeOAuth(
                redirectURI: Self.oauthRedirectURI,
                state: pkce.state,
                codeChallenge: pkce.codeChallenge
            )
            guard let providerURL = URL(string: authorize.url) else {
                errorMessage = String(localized: "The server returned an invalid OAuth URL.")
                return
            }
            guard let callbackURL = await oauthSessionHandler(providerURL) else {
                return // User cancelled — keep the current state.
            }
            let response = try await client.exchangeOAuthCode(
                url: callbackURL.absoluteString,
                state: pkce.state,
                codeVerifier: pkce.codeVerifier
            )
            applySession(
                token: response.accessToken,
                email: response.userEmail,
                name: response.name,
                userId: response.userId,
                isAdmin: response.isAdmin,
                shouldChangePassword: response.shouldChangePassword
            )
        } catch let e {
            errorMessage = e.userFacingMessage
        }
    }

    /// Applies a successful auth response: state + Keychain + UserDefaults +
    /// client reconfiguration. Shared by password login and OAuth.
    private func applySession(token: String, email: String?, name: String?, userId: String?, isAdmin: Bool, shouldChangePassword: Bool) {
        accessToken = token
        userEmail = email
        userName = name
        self.userId = userId
        self.isAdmin = isAdmin
        self.shouldChangePassword = shouldChangePassword
        sessionExpired = false
        keychain.saveToken(token)
        defaults.set(baseURL?.absoluteString ?? serverURLString, forKey: Self.serverURLDefaultsKey)
        if let email { defaults.set(email, forKey: Self.userEmailDefaultsKey) }
        if let name { defaults.set(name, forKey: Self.userNameDefaultsKey) }
        if let userId { defaults.set(userId, forKey: Self.userIdDefaultsKey) }
        defaults.set(isAdmin, forKey: Self.isAdminDefaultsKey)
        // Adding an account counts as having seen the current "What's New" batch
        // (G23), mirroring upstream's markSeen at login: a batch authored before
        // this account existed must not be announced to it. Deliberately NOT in
        // `restoreSession()` — a relaunch that restores a session after an update
        // is exactly the case the sheet exists for.
        defaults.set(FeatureHighlightCatalog.release, forKey: WhatsNewStore.seenReleaseKey)
        client.configure(baseURL: baseURL, token: token)
        if let baseURL { realtime.connect(baseURL: baseURL, token: token) }
        publishWidgetSession()
        addCurrentAccountToSaved()
    }

    @MainActor
    func logout() async {
        isLoading = true
        _ = try? await client.logout()
        resetSession()
        isLoading = false
    }

    /// Clears auth state + stored credentials. Keeps the server URL so the
    /// next sign-in skips re-entering the address.
    func resetSession() {
        accessToken = nil
        userEmail = nil
        userName = nil
        userId = nil
        isAdmin = false
        shouldChangePassword = false
        keychain.deleteToken()
        widgetSession.clear()
        defaults.removeObject(forKey: Self.userEmailDefaultsKey)
        defaults.removeObject(forKey: Self.userNameDefaultsKey)
        defaults.removeObject(forKey: Self.userIdDefaultsKey)
        defaults.removeObject(forKey: Self.isAdminDefaultsKey)
        client.configure(baseURL: baseURL, token: nil)
        realtime.disconnect()
    }

    /// The password was changed: the server cleared its own `shouldChangePassword`
    /// flag, and this is the only place the local copy falls back (gap G18).
    ///
    /// Deliberately no re-login: `invalidateSessions` signs out the *other*
    /// devices and keeps this session (`auth.service.ts:143-147`), so the app
    /// stays signed in and the invitation simply stops being shown.
    func notePasswordChanged() {
        shouldChangePassword = false
    }

    /// Re-reads the flag from the server (`GET /api/users/me`) so an
    /// administrator who resets the password mid-session is noticed without a
    /// new sign-in. Fills the flag only — the rest of the session is untouched —
    /// and keeps the current value when the server cannot be reached: a failed
    /// read must not erase an invitation the user has not answered.
    func refreshShouldChangePassword() async {
        if let user = try? await client.currentUser() {
            shouldChangePassword = user.shouldChangePassword ?? false
        }
    }

    // MARK: - Multi-server / multi-account (P5)

    /// Returns the active session as a `SavedAccount` (nil if no URL yet).
    private func currentAccount() -> SavedAccount? {
        guard let url = baseURL?.absoluteString else { return nil }
        return SavedAccount(url: url, email: userEmail, name: userName, userId: userId, isAdmin: isAdmin)
    }

    /// Upserts the active session into the account registry (dedup by id) and
    /// stores its token under the per-account Keychain key.
    func addCurrentAccountToSaved() {
        guard let account = currentAccount() else { return }
        if let token = accessToken {
            keychain.saveToken(token, for: account.id)
        }
        savedAccounts.removeAll { $0.id == account.id }
        savedAccounts.insert(account, at: 0)
        persistSavedAccounts()
    }

    /// Removes a saved account: drops its per-account token and registry entry.
    /// If it is the active account, the session is reset (onboarding, URL kept).
    func removeSavedAccount(_ account: SavedAccount) {
        keychain.deleteToken(for: account.id)
        savedAccounts.removeAll { $0.id == account.id }
        persistSavedAccounts()
        if account.id == activeAccountID {
            resetSession()
        }
    }

    /// Starts fresh: clears the current session + server URL so onboarding
    /// shows an empty address for a brand-new account/server.
    func addNewServer() {
        serverURLString = ""
        resetSession()
    }

    /// Switches the active session to a saved account. The token is restored
    /// from the per-account Keychain slot and re-validated; a missing or
    /// rejected token falls back to onboarding with the URL pre-filled.
    @MainActor
    func switchToAccount(_ account: SavedAccount) async {
        guard account.id != activeAccountID else { return }
        guard let url = normalizedBaseURL(from: account.url) else {
            errorMessage = String(localized: "Invalid server URL.")
            return
        }

        // Re-assert the current account's token before leaving it.
        if let current = currentAccount(), let token = accessToken {
            keychain.saveToken(token, for: current.id)
        }

        guard let token = keychain.getToken(for: account.id) else {
            serverURLString = account.url
            resetSession()
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        accessToken = token
        userEmail = account.email
        userName = account.name
        userId = account.userId
        isAdmin = account.isAdmin
        serverURLString = account.url
        keychain.saveToken(token)
        defaults.set(url.absoluteString, forKey: Self.serverURLDefaultsKey)
        defaults.set(account.email, forKey: Self.userEmailDefaultsKey)
        defaults.set(account.name, forKey: Self.userNameDefaultsKey)
        defaults.set(account.userId, forKey: Self.userIdDefaultsKey)
        defaults.set(account.isAdmin, forKey: Self.isAdminDefaultsKey)
        client.configure(baseURL: url, token: token)
        realtime.connect(baseURL: url, token: token)
        publishWidgetSession()
        do {
            _ = try await client.validateToken()
        } catch APIError.unauthorized {
            resetSession()
        } catch {
            // Network / decode: keep the session (offline-safe).
        }
        isLoading = false
    }

    private func persistSavedAccounts() {
        if let data = try? JSONEncoder.immich.encode(savedAccounts) {
            defaults.set(data, forKey: Self.serverListDefaultsKey)
        }
    }

    private static func loadSavedAccounts(from defaults: UserDefaults) -> [SavedAccount] {
        guard let data = defaults.data(forKey: serverListDefaultsKey) else { return [] }
        return (try? JSONDecoder.immich.decode([SavedAccount].self, from: data)) ?? []
    }

    // MARK: - AuthSessionDelegate (FM-4)

    func didReceiveUnauthorized() {
        Task { @MainActor in
            self.handleSessionExpired()
        }
    }

    /// SP-4: a 401 on an authenticated session drops the user back to sign-in.
    /// The stored token and identity are kept on purpose: only an explicit
    /// logout (`resetSession()`) wipes them. A 401 while not authenticated
    /// (e.g. a failed sign-in) must not override the message being shown.
    private func handleSessionExpired() {
        guard isAuthenticated else { return }
        isLoading = false
        accessToken = nil
        errorMessage = UserFacingError.sessionExpiredMessage
        sessionExpired = true
        client.configure(baseURL: baseURL, token: nil)
        realtime.disconnect()
    }
}
