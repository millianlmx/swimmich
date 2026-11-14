import XCTest
@testable import ImmichSwiftUI

/// L-26 at the account level: the address in use moves, the identity does not.
@MainActor
final class AuthViewModelServerAddressTests: XCTestCase {
    private let account = URL(string: "https://photos.example.org")!
    private let local = URL(string: "http://192.168.1.10:2283")!
    private let version = "1.119.0"
    private let email = "t@e.com"
    private let userId = "u"

    private final class PublishedSessionSpy: WidgetSessionStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: WidgetSession?
        func save(_ session: WidgetSession) { lock.lock(); stored = session; lock.unlock() }
        func load() -> WidgetSession? { lock.lock(); defer { lock.unlock() }; return stored }
        func clear() { lock.lock(); stored = nil; lock.unlock() }
        func noteReload() {}
    }

    private struct Fixture {
        let auth: AuthViewModel
        let mock: MockImmichClient
        let store: InMemoryServerAddressSettingsStore
        let probe: ScriptedServerAddressProbe
        let endpoints: ServerEndpointSwitch
        let published: PublishedSessionSpy
        let keychain: MockKeychainStore
        let defaults: UserDefaults
        let suite: String
    }

    private var suites: [(UserDefaults, String)] = []

    override func tearDown() {
        for (defaults, suite) in suites { defaults.removePersistentDomain(forName: suite) }
        suites = []
    }

    private var accountID: String { SavedAccount.makeID(url: account.absoluteString, email: email, userId: userId) }

    private func makeFixture(settings: ServerAddressSettings? = nil, storedSession: Bool = true) -> Fixture {
        let suite = "AuthViewModelServerAddressTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        suites.append((defaults, suite))
        let keychain = MockKeychainStore()
        if storedSession {
            defaults.set(account.absoluteString, forKey: AuthViewModel.serverURLDefaultsKey)
            defaults.set(email, forKey: AuthViewModel.userEmailDefaultsKey)
            defaults.set(userId, forKey: AuthViewModel.userIdDefaultsKey)
            keychain.saveToken("saved-jwt")
        }
        let mock = MockImmichClient()
        mock.serverVersionResponse = ServerVersionResponseDto(major: 1, minor: 119, patch: 0, prerelease: nil)
        mock.loginResponse = LoginResponseDto(
            accessToken: "jwt", userId: userId, userEmail: email, name: "T",
            profileImagePath: "", isAdmin: false, shouldChangePassword: false, isOnboarded: true
        )
        let store = InMemoryServerAddressSettingsStore()
        if let settings { store.save(settings, for: accountID) }
        let probe = ScriptedServerAddressProbe()
        let realtime = RealtimeService(transport: MockRealtimeTransport())
        let endpoints = ServerEndpointSwitch(
            client: mock, realtime: realtime, store: store, probe: probe, monitor: nil,
            addressBook: ServerAddressBook(), customHeaders: NoCustomHeaders(), appLog: NoopAppLogSink(),
            probeDeadline: .milliseconds(200)
        )
        let published = PublishedSessionSpy()
        let auth = AuthViewModel(
            client: mock, keychain: keychain, defaults: defaults, realtime: realtime,
            widgetSession: published, reloadWidgets: {}, endpoints: endpoints
        )
        return Fixture(
            auth: auth, mock: mock, store: store, probe: probe, endpoints: endpoints,
            published: published, keychain: keychain, defaults: defaults, suite: suite
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private var switchOn: ServerAddressSettings {
        ServerAddressSettings(localURL: local.absoluteString, autoSwitch: true)
    }

    // MARK: - AC-49

    func test_AC_49_baseURLFollowsTheLocalAddressWhileTheIdentityStays() async {
        let fx = makeFixture(settings: switchOn)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.answer(local, .immich(version: version))
        await fx.auth.restoreSession()

        await fx.endpoints.evaluate(.networkChange)

        XCTAssertEqual(fx.auth.baseURL, local)
        XCTAssertEqual(fx.mock.configuredBaseURL, local)
        XCTAssertEqual(fx.auth.accountURL, account)
        XCTAssertEqual(fx.auth.activeAccountID, accountID)
        XCTAssertEqual(fx.auth.publicServerURL, account)
    }

    func test_AC_49_loginVersionLetsLocalWinWhenExternalMute() async {
        let external = URL(string: "https://vpn.example.org")!
        let fx = makeFixture(
            settings: ServerAddressSettings(localURL: local.absoluteString, externalURL: external.absoluteString, autoSwitch: true),
            storedSession: false
        )
        fx.probe.answer(external, .unreachable)
        fx.probe.answer(local, .immich(version: version))
        fx.auth.serverURLString = account.absoluteString
        await fx.auth.connectServer()

        await fx.auth.login(email: email, password: "pw")
        await fx.endpoints.evaluate(.networkChange)

        XCTAssertEqual(fx.store.settings(for: accountID).lastKnownVersion, version, "the login recorded the version it read")
        XCTAssertEqual(fx.auth.baseURL, local, "the external address is mute: the known version vouches for the local one")
    }

    func test_AC_49_restoreRecordsKnownVersion() async {
        let fx = makeFixture()
        await fx.auth.restoreSession()

        await waitUntil { fx.store.settings(for: self.accountID).lastKnownVersion == self.version }

        XCTAssertEqual(fx.store.settings(for: accountID).lastKnownVersion, version)
    }

    // MARK: - AC-239

    func test_AC_239_publishedSessionUsesExternal() async {
        let fx = makeFixture(settings: switchOn)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.answer(local, .immich(version: version))
        await fx.auth.restoreSession()
        await fx.endpoints.evaluate(.networkChange)
        XCTAssertEqual(fx.auth.baseURL, local)

        fx.auth.publishWidgetSession()

        XCTAssertEqual(fx.published.load()?.baseURL, account.absoluteString, "widgets and the extension never get the local address")
    }

    // MARK: - AC-240

    func test_AC_240_identityStable() async {
        let fx = makeFixture(settings: switchOn, storedSession: false)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.answer(local, .immich(version: version))
        fx.auth.serverURLString = account.absoluteString
        await fx.auth.login(email: email, password: "pw")
        let before = fx.auth.activeAccountID

        await fx.endpoints.evaluate(.networkChange)
        XCTAssertEqual(fx.auth.baseURL, local)
        XCTAssertEqual(fx.auth.activeAccountID, before)
        XCTAssertEqual(fx.auth.savedAccounts.count, 1)
        XCTAssertEqual(fx.auth.savedAccounts.first?.url, account.absoluteString)

        fx.probe.answer(local, .unreachable)
        await fx.endpoints.evaluate(.networkChange)
        XCTAssertEqual(fx.auth.baseURL, account)
        XCTAssertEqual(fx.auth.activeAccountID, before)
        XCTAssertEqual(fx.auth.savedAccounts.count, 1)
        XCTAssertNotNil(fx.keychain.getToken(for: accountID), "the token key is the identity, not the address")
    }

    // MARK: - AC-243

    func test_AC_243_accountWithoutSettingsNeverProbes() async {
        let fx = makeFixture()
        await fx.auth.restoreSession()

        await fx.endpoints.evaluate(.networkChange)
        await fx.endpoints.evaluate(.foreground)

        XCTAssertTrue(fx.probe.calls.isEmpty)
        XCTAssertEqual(fx.mock.configuredBaseURL, account)
        XCTAssertEqual(fx.auth.baseURL, account)
    }

    func test_AC_243_modifiedExternalAddressWithTheSwitchOff() async {
        let external = URL(string: "https://vpn.example.org")!
        let fx = makeFixture(settings: ServerAddressSettings(externalURL: external.absoluteString), storedSession: false)
        fx.auth.serverURLString = account.absoluteString
        await fx.auth.login(email: email, password: "pw")

        XCTAssertEqual(fx.mock.configuredBaseURL, external)
        XCTAssertEqual(fx.auth.baseURL, external)
        XCTAssertEqual(fx.published.load()?.baseURL, external.absoluteString)
        XCTAssertTrue(fx.probe.calls.isEmpty)
        XCTAssertTrue(fx.auth.isAuthenticated)
        XCTAssertEqual(fx.auth.savedAccounts.count, 1)
        XCTAssertEqual(fx.auth.savedAccounts.first?.url, account.absoluteString)
        XCTAssertEqual(fx.keychain.getToken(for: accountID), "jwt")
    }

    // MARK: - AC-244

    func test_AC_244_settingsFollowTheAccountOnSwitch() async throws {
        let other = URL(string: "https://b.example.org")!
        let accountB = SavedAccount(url: other.absoluteString, email: "b@e.com", name: "B", userId: "ub", isAdmin: false)
        let accountA = SavedAccount(url: account.absoluteString, email: email, name: "T", userId: userId, isAdmin: false)
        let fx = makeFixture(settings: switchOn)
        fx.defaults.set(try JSONEncoder.immich.encode([accountA, accountB]), forKey: AuthViewModel.serverListDefaultsKey)
        fx.keychain.saveToken("tokB", for: accountB.id)
        fx.keychain.saveToken("saved-jwt", for: accountA.id)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.answer(local, .immich(version: version))
        let auth = AuthViewModel(
            client: fx.mock, keychain: fx.keychain, defaults: fx.defaults,
            realtime: RealtimeService(transport: MockRealtimeTransport()),
            widgetSession: fx.published, reloadWidgets: {}, endpoints: fx.endpoints
        )
        await auth.restoreSession()
        await fx.endpoints.evaluate(.networkChange)
        XCTAssertEqual(auth.baseURL, local)
        let probes = fx.probe.calls.count

        await auth.switchToAccount(accountB)
        await fx.endpoints.evaluate(.foreground)
        XCTAssertEqual(auth.baseURL, other)
        XCTAssertEqual(fx.mock.configuredBaseURL, other)
        XCTAssertEqual(fx.probe.calls.count, probes, "the second account has no local address: no probe")

        await auth.switchToAccount(accountA)
        await fx.endpoints.evaluate(.foreground)
        XCTAssertEqual(auth.baseURL, local, "the first account follows its own local address again")
    }
}
