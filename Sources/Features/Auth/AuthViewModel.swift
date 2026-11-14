import Foundation
import ImmichSharedKit
import SwiftUI
import WidgetKit

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
        /// The server asked for a TLS client certificate and none is installed
        /// for it (L-10).
        case clientCertificateRequired
    }

    // UserDefaults keys (internal so tests can seed/assert).
    static let serverURLDefaultsKey = "authServerURL"
    static let serverListDefaultsKey = "authServerList"
    static let userEmailDefaultsKey = "authUserEmail"
    static let userNameDefaultsKey = "authUserName"
    static let userIdDefaultsKey = "authUserId"
    static let isAdminDefaultsKey = "authIsAdmin"

    /// Test only (`-uiTestSessionToken <token>`, with the other `auth*` keys on the
    /// launch arguments): a UI scenario starts signed in, as a sign-in would have
    /// left the device, without walking the onboarding it does not test. Never
    /// written outside tests.
    static let uiTestSessionTokenKey = "uiTestSessionToken"

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
        didSet {
            _cachedBaseURL = nil
            refreshClientCertificateState()
        }
    }
    /// Whether a client certificate is installed for the server typed above
    /// (host + effective port). Recomputed on every change of the address, at
    /// the end of `connectServer()` and by `clientCertificateDidChange()`.
    private(set) var serverHasClientCertificate = false
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
        SavedAccount.makeID(url: accountURL?.absoluteString ?? serverURLString, email: userEmail, userId: userId)
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
    /// Refreshes the home screen after every write/clear of the widget session,
    /// so widgets stop showing the previous account's photos. Tests inject a spy.
    private let reloadWidgets: () -> Void
    private var _cachedBaseURL: URL?
    /// The local stores bound to the active account at each session change
    /// (`scopeLocalData`) and wiped by a voluntary logout. `nil` = none attached.
    private let localData: LocalDataPurger?
    /// The server's custom HTTP headers (L-09): copied into the widget session.
    private let customHeaders: any CustomHeadersProviding
    /// What the TLS delegates saw: tells a missing client certificate and a
    /// refused server trust from a plain network failure (L-10).
    private let challengeLog: TLSChallengeLog
    private let identities: any ClientIdentityStoring
    /// Which address of the active account the app talks to (L-26). The account
    /// keeps one identity (`accountURL`); the address in use is `baseURL`.
    private let endpoints: ServerEndpointSwitch

    init(
        client: any ImmichClient,
        keychain: KeychainStore,
        defaults: UserDefaults = .standard,
        trustStore: TrustedServerStore = TrustedServerStoreImpl(),
        realtime: RealtimeService = RealtimeService(),
        widgetSession: any WidgetSessionStoring = WidgetSessionStore(),
        reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        localData: LocalDataPurger? = nil,
        customHeaders: any CustomHeadersProviding = NoCustomHeaders(),
        challengeLog: TLSChallengeLog = .shared,
        identities: any ClientIdentityStoring = KeychainClientIdentityStore(),
        endpoints: ServerEndpointSwitch? = nil
    ) {
        self.client = client
        self.keychain = keychain
        self.defaults = defaults
        self.trustStore = trustStore
        self.realtime = realtime
        self.widgetSession = widgetSession
        self.reloadWidgets = reloadWidgets
        self.localData = localData
        self.customHeaders = customHeaders
        self.challengeLog = challengeLog
        self.identities = identities
        self.endpoints = endpoints ?? ServerEndpointSwitch(
            client: client, realtime: realtime,
            store: UserDefaultsServerAddressSettingsStore(defaults: defaults),
            probe: URLSessionServerAddressProbe(session: { URLSession(configuration: ServerSessions.probeConfiguration()) }),
            monitor: nil, addressBook: ServerAddressBook(), customHeaders: customHeaders, appLog: NoopAppLogSink()
        )
        self.serverURLString = defaults.string(forKey: Self.serverURLDefaultsKey) ?? ""
        self.userEmail = defaults.string(forKey: Self.userEmailDefaultsKey)
        self.userName = defaults.string(forKey: Self.userNameDefaultsKey)
        self.userId = defaults.string(forKey: Self.userIdDefaultsKey)
        self.isAdmin = defaults.bool(forKey: Self.isAdminDefaultsKey)
        if let token = defaults.string(forKey: Self.uiTestSessionTokenKey) { keychain.saveToken(token) }
        self.accessToken = keychain.getToken()
        self.savedAccounts = Self.loadSavedAccounts(from: defaults)
        self.client.authDelegate = self
        refreshClientCertificateState()
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

        guard let token = accessToken, let url = accountURL else {
            resetSession()
            return
        }
        scopeLocalData()
        endpoints.activate(accountID: activeID(for: url), accountURL: url, token: token, connectRealtime: false)
        do {
            _ = try await client.validateToken()
            // The session is valid: the version the server answers with is the reference
            // the local address is compared to. Never awaited.
            if accessToken == token, accountURL == url { Task { await endpoints.refreshKnownVersion() } }
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
            // The token/URL pair that was just validated; a switch of account
            // during the await must not reconnect with the old token.
            if accessToken == token, accountURL == url {
                endpoints.connectRealtime()
            }
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
        guard let token = accessToken, let accountURL else { return }
        // Widgets and the share extension employ the external address (L-26): the
        // local one is chosen from the app's own evaluation, which they cannot read.
        let published = endpoints.externalURL ?? accountURL
        // The widget cannot read this process' trust store (a different
        // container), so a host whose certificate the user accepted travels
        // with the session — without it a self-signed server is unreachable
        // from the widget even though the app opens it fine.
        let host = published.host
        let trustedHosts = (host.flatMap { trustStore.contains($0) ? $0 : nil }).map { [$0] } ?? []
        widgetSession.save(WidgetSession(
            baseURL: published.absoluteString,
            token: token,
            userName: userName,
            userId: userId,
            trustedHosts: trustedHosts,
            // The share extension uploads from its own process and reads this
            // snapshot; without the id its assets would show up as a second
            // device in the web UI's per-device filter.
            deviceId: DeviceIdentity.current,
            // The widget and the extension cannot read the in-memory registry:
            // the active server's headers travel with the session. `nil` (not
            // `[]`) when there are none, so the stored JSON is the one of a
            // build without custom headers.
            customHeaders: Self.nonEmpty(customHeaders.headers(for: accountURL))
        ))
        reloadWidgets()
    }

    private static func nonEmpty(_ headers: [CustomHTTPHeader]) -> [CustomHTTPHeader]? {
        headers.isEmpty ? nil : headers
    }

    /// The headers of `key`'s server were saved. Requests read the registry per
    /// call, so the next one already carries the new list; what needs a nudge is
    /// what holds a copy — the realtime socket (its handshake headers are fixed
    /// at connect) and the widgets' session. The session itself is never reset.
    /// Without a session, or for another server, there is nothing to do.
    func customHeadersDidChange(for key: ServerKey) {
        guard isAuthenticated, accessToken != nil, let url = accountURL,
              ServerKey(url: url) == key
        else { return }
        endpoints.reconnectRealtime()
        publishWidgetSession()
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

    /// The identity of the active account: the address it was connected with.
    /// It keys the token, the offline copies and the caches, and never changes
    /// when the app switches between the local and the external address.
    var accountURL: URL? {
        if let cached = _cachedBaseURL { return cached }
        let url = normalizedBaseURL(from: serverURLString)
        _cachedBaseURL = url
        return url
    }

    /// The address the app talks to: the one in use while signed in (the local
    /// or the external address of the server), the typed one before.
    var baseURL: URL? {
        isAuthenticated ? (endpoints.activeURL ?? accountURL) : accountURL
    }

    /// The address links shared with other people are built on (the external one).
    var publicServerURL: URL? { endpoints.publicURL ?? accountURL }

    /// The service behind the "Network" setting.
    var serverAddresses: ServerEndpointSwitch { endpoints }

    private func activeID(for url: URL) -> String {
        SavedAccount.makeID(url: url.absoluteString, email: userEmail, userId: userId)
    }

    // MARK: - Server discovery

    @MainActor
    func connectServer() async {
        guard let url = accountURL else {
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
        } catch {
            // The client wraps URLSession failures in `APIError.network`, so the
            // `URLError` is read out of either shape.
            let urlError = Self.urlError(in: error)
            if let urlError, ServerTrustFailure.isTLSError(urlError)
                || (urlError.code == .cancelled && challengeLog.trustWasRefused(host: url.host ?? "")) {
                // P5 selfsigned-cert: surface the host so the UI can offer to
                // trust it explicitly. A refused trust wins over any other
                // reading: the client certificate is only asked for once the
                // server is trusted, and a challenge the delegate cancelled
                // surfaces as `.cancelled`, not as a TLS error code.
                serverStatus = .unreachable
                errorMessage = String(localized: "This server’s certificate can’t be verified.")
                pendingUntrustedHost = url.host
            } else if (error as? APIError) == .clientCertificateRequired
                        || urlError.map({ MissingClientCertificate.matches($0, url: url, log: challengeLog) }) == true {
                serverStatus = .clientCertificateRequired
                errorMessage = UserFacingError.clientCertificateRequiredMessage
            } else {
                serverStatus = .unreachable
            }
        }
        refreshClientCertificateState()
    }

    private static func urlError(in error: Error) -> URLError? {
        if let urlError = error as? URLError { return urlError }
        if case .network(let urlError)? = error as? APIError { return urlError }
        return nil
    }

    /// Re-reads whether the typed server has a client certificate.
    func refreshClientCertificateState() {
        guard let url = accountURL, let key = ServerKey(url: url) else {
            serverHasClientCertificate = false
            return
        }
        serverHasClientCertificate = identities.hasIdentity(for: key)
    }

    /// A certificate was imported or removed for the typed server: re-read the
    /// state and check the server again, so the status follows without a tap.
    func clientCertificateDidChange() async {
        refreshClientCertificateState()
        if accountURL != nil { await connectServer() }
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

    // MARK: - Auth

    @MainActor
    func login(email: String, password: String) async {
        guard accountURL != nil else {
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
        guard accountURL != nil, canOAuthLogin else {
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
        defaults.set(accountURL?.absoluteString ?? serverURLString, forKey: Self.serverURLDefaultsKey)
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
        if let accountURL {
            endpoints.activate(accountID: activeID(for: accountURL), accountURL: accountURL, token: token, connectRealtime: true)
            if case .reachable(let version?) = serverStatus {
                endpoints.recordVersion("\(version.major).\(version.minor).\(version.patch)")
            }
        } else {
            client.configure(baseURL: nil, token: token)
        }
        publishWidgetSession()
        addCurrentAccountToSaved()
        scopeLocalData()
    }

    /// Voluntary, confirmed sign-out. Beyond `resetSession()` it wipes everything
    /// the device kept about the account: the local stores (`localData`), the
    /// trusted-servers list, every registered account's keychain token, the
    /// registered-accounts list and the server address. Never reached by the
    /// 401 / switch-account / add-server / remove-account paths, which share
    /// `resetSession()` but must keep all of that.
    @MainActor
    func logout() async {
        isLoading = true
        _ = try? await client.logout()
        // The trusted-servers list is emptied first, so a connection opened
        // while the purge runs, and the final connection reset, leave no
        // trusted connection behind.
        trustStore.removeAll()
        // Transfers stop and the stores empty next, so nothing can write into
        // a store after it was purged.
        await localData?.purgeAll()
        for account in savedAccounts { keychain.deleteToken(for: account.id) }
        savedAccounts = []
        defaults.removeObject(forKey: Self.serverListDefaultsKey)
        endpoints.forgetAll()
        defaults.removeObject(forKey: Self.serverURLDefaultsKey)
        serverURLString = ""
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
        reloadWidgets()
        defaults.removeObject(forKey: Self.userEmailDefaultsKey)
        defaults.removeObject(forKey: Self.userNameDefaultsKey)
        defaults.removeObject(forKey: Self.userIdDefaultsKey)
        defaults.removeObject(forKey: Self.isAdminDefaultsKey)
        endpoints.deactivate()
        client.configure(baseURL: accountURL, token: nil)
        realtime.disconnect()
        scopeLocalData()
    }

    /// Binds the per-account local stores (offline copies) to the account the
    /// session now belongs to, or to none when there is no session. Synchronous
    /// and called before any `await` that follows an identity change, so no
    /// later read serves the previous account's copies. "Other accounts
    /// registered" decides where content left by the single-folder layout goes.
    private func scopeLocalData() {
        let active = isAuthenticated ? activeAccountID : nil
        localData?.activateAccount(active, otherAccountsRegistered: savedAccounts.contains { $0.id != active })
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
        guard let url = accountURL?.absoluteString else { return nil }
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
        endpoints.forget(accountID: account.id)
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
        scopeLocalData()
        keychain.saveToken(token)
        defaults.set(url.absoluteString, forKey: Self.serverURLDefaultsKey)
        defaults.set(account.email, forKey: Self.userEmailDefaultsKey)
        defaults.set(account.name, forKey: Self.userNameDefaultsKey)
        defaults.set(account.userId, forKey: Self.userIdDefaultsKey)
        defaults.set(account.isAdmin, forKey: Self.isAdminDefaultsKey)
        endpoints.activate(accountID: activeID(for: url), accountURL: url, token: token, connectRealtime: true)
        publishWidgetSession()
        do {
            _ = try await client.validateToken()
            if accessToken == token, accountURL == url { Task { await endpoints.refreshKnownVersion() } }
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
        endpoints.deactivate()
        client.configure(baseURL: accountURL, token: nil)
        realtime.disconnect()
        scopeLocalData()
    }
}
