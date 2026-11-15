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
        let transport: MockRealtimeTransport
        let book: ServerAddressBook
        let published: PublishedSessionSpy
        let keychain: MockKeychainStore
        let defaults: UserDefaults
        let suite: String
    }

    /// What the sign-out request saw while it was in flight.
    private final class SignOutWindow: @unchecked Sendable {
        private let lock = NSLock()
        private var accountURL: URL?
        private var token: String?
        func set(accountURL: URL?, token: String?) {
            lock.lock(); defer { lock.unlock() }
            self.accountURL = accountURL
            self.token = token
        }
        var seen: (accountURL: URL?, token: String?) {
            lock.lock(); defer { lock.unlock() }
            return (accountURL, token)
        }
    }

    @MainActor
    private final class NoopConnectionReset: ConnectionResetting {
        func resetConnections() async {}
    }

    private var suites: [(UserDefaults, String)] = []

    override func tearDown() {
        for (defaults, suite) in suites { defaults.removePersistentDomain(forName: suite) }
        suites = []
    }

    private var accountID: String { SavedAccount.makeID(url: account.absoluteString, email: email, userId: userId) }

    private func makeFixture(
        settings: ServerAddressSettings? = nil,
        storedSession: Bool = true,
        savedAccounts: [SavedAccount] = [],
        localData: LocalDataPurger? = nil,
        deadline: Duration = .milliseconds(200)
    ) -> Fixture {
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
        if !savedAccounts.isEmpty, let data = try? JSONEncoder.immich.encode(savedAccounts) {
            defaults.set(data, forKey: AuthViewModel.serverListDefaultsKey)
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
        let transport = MockRealtimeTransport()
        let realtime = RealtimeService(transport: transport)
        let book = ServerAddressBook()
        let endpoints = ServerEndpointSwitch(
            client: mock, realtime: realtime, store: store, probe: probe, monitor: nil,
            addressBook: book, customHeaders: NoCustomHeaders(), appLog: NoopAppLogSink(),
            probeDeadline: deadline
        )
        let published = PublishedSessionSpy()
        let auth = AuthViewModel(
            client: mock, keychain: keychain, defaults: defaults, trustStore: TrustedServerStoreImpl(defaults: defaults),
            realtime: realtime, widgetSession: published, reloadWidgets: {}, localData: localData, endpoints: endpoints
        )
        return Fixture(
            auth: auth, mock: mock, store: store, probe: probe, endpoints: endpoints,
            transport: transport, book: book,
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

    func test_AC_49_switchRecordsKnownVersion() async {
        let accountA = SavedAccount(url: account.absoluteString, email: email, name: "T", userId: userId, isAdmin: false)
        let accountB = SavedAccount(url: "https://b.example.org", email: "b@e.com", name: "B", userId: "ub", isAdmin: false)
        let fx = makeFixture(savedAccounts: [accountA, accountB])
        fx.keychain.saveToken("saved-jwt", for: accountA.id)
        fx.keychain.saveToken("tokB", for: accountB.id)
        await fx.auth.restoreSession()
        await waitUntil { fx.store.settings(for: self.accountID).lastKnownVersion == self.version }

        fx.mock.serverVersionResponse = ServerVersionResponseDto(major: 1, minor: 120, patch: 0, prerelease: nil)
        await fx.auth.switchToAccount(accountB)
        await waitUntil { fx.store.settings(for: accountB.id).lastKnownVersion == "1.120.0" }

        XCTAssertEqual(fx.store.settings(for: accountB.id).lastKnownVersion, "1.120.0", "read on the chosen account")
        XCTAssertEqual(fx.store.settings(for: accountID).lastKnownVersion, version, "the first account keeps its own")
    }

    // MARK: - AC-249

    func test_AC_249_publicAddressIsTheExternalOneWhileOnLocal() async {
        let vpn = URL(string: "https://vpn.example.org")!
        let fx = makeFixture(
            settings: ServerAddressSettings(localURL: local.absoluteString, externalURL: vpn.absoluteString, autoSwitch: true)
        )
        fx.probe.answer(vpn, .immich(version: version))
        fx.probe.answer(local, .immich(version: version))
        await fx.auth.restoreSession()

        await fx.endpoints.evaluate(.networkChange)

        XCTAssertEqual(fx.auth.baseURL, local, "the address \"Open in Browser\" opens: the one in use")
        XCTAssertEqual(fx.auth.publicServerURL, vpn, "the base of every link handed out")
        XCTAssertNotEqual(fx.auth.publicServerURL, account)
    }

    // MARK: - AC-239

    func test_AC_239_publishedSessionCarriesBothAddresses() async {
        let fx = makeFixture(settings: switchOn)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.answer(local, .immich(version: version))
        await fx.auth.restoreSession()
        await fx.endpoints.evaluate(.networkChange)
        XCTAssertEqual(fx.auth.baseURL, local)

        fx.auth.publishWidgetSession()

        let published = fx.published.load()
        XCTAssertEqual(published?.baseURL, account.absoluteString, "the session starts from the external address")
        XCTAssertEqual(published?.localURL, local.absoluteString, "widgets and the extension choose the local one themselves")
        XCTAssertEqual(published?.autoSwitch, true)
        XCTAssertEqual(published?.lastKnownVersion, version)
        XCTAssertEqual(published?.accountURL, account.absoluteString)
    }

    func test_AC_239_savedSettingsArePublishedAgain() async {
        let fx = makeFixture()
        await fx.auth.restoreSession()
        XCTAssertNil(fx.published.load()?.localURL)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.answer(local, .unreachable)

        await fx.endpoints.save(switchOn)

        XCTAssertEqual(fx.published.load()?.localURL, local.absoluteString, "an edit in Network reaches the widgets")
        XCTAssertEqual(fx.published.load()?.autoSwitch, true)
        XCTAssertEqual(fx.published.load()?.baseURL, account.absoluteString)
    }

    func test_AC_239_4_recordedVersionIsPublishedAgain() async {
        let fx = makeFixture(settings: switchOn)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.answer(local, .unreachable)
        await fx.auth.restoreSession()
        await waitUntil { fx.store.settings(for: self.accountID).lastKnownVersion == self.version }
        XCTAssertEqual(fx.published.load()?.lastKnownVersion, version, "the version read at launch reaches the widgets")
        let before = fx.published.load()

        fx.mock.serverVersionResponse = ServerVersionResponseDto(major: 1, minor: 120, patch: 0, prerelease: nil)
        await fx.endpoints.refreshKnownVersion()

        let after = fx.published.load()
        XCTAssertEqual(after?.lastKnownVersion, "1.120.0", "a server update read after the publication is published again")
        XCTAssertEqual(after?.localURL, before?.localURL)
        XCTAssertEqual(after?.autoSwitch, before?.autoSwitch)
        XCTAssertEqual(after?.baseURL, before?.baseURL)
    }

    func test_AC_241_publishedSessionTrustsTheApprovedLocalHost() async {
        let fx = makeFixture(settings: switchOn)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.answer(local, .immich(version: version))
        await fx.auth.restoreSession()
        TrustedServerStoreImpl(defaults: fx.defaults).add("192.168.1.10")

        fx.auth.publishWidgetSession()

        XCTAssertEqual(fx.published.load()?.trustedHostSet, ["192.168.1.10"], "an approval given in the app reaches the widgets")
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

        // A relaunch: the modified external address is the address in use, with no probe and no new entry.
        let fx2 = makeFixture(settings: ServerAddressSettings(externalURL: external.absoluteString))
        await fx2.auth.restoreSession()

        XCTAssertEqual(fx2.mock.configuredBaseURL, external)
        XCTAssertEqual(fx2.auth.baseURL, external)
        XCTAssertEqual(fx2.published.load()?.baseURL, external.absoluteString)
        XCTAssertTrue(fx2.probe.calls.isEmpty)
        XCTAssertTrue(fx2.auth.isAuthenticated)
        XCTAssertEqual(fx2.auth.activeAccountID, accountID)
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

    func test_AC_244_forgettingOrSigningOutClearsTheSettings() async {
        let accountA = SavedAccount(url: account.absoluteString, email: email, name: "T", userId: userId, isAdmin: false)
        let accountB = SavedAccount(url: "https://b.example.org", email: "b@e.com", name: "B", userId: "ub", isAdmin: false)
        let fx = makeFixture(settings: switchOn, savedAccounts: [accountA, accountB])
        fx.store.save(ServerAddressSettings(localURL: "http://10.0.0.2:2283", autoSwitch: true), for: accountB.id)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.answer(local, .unreachable)
        await fx.auth.restoreSession()
        await fx.endpoints.evaluate(.foreground)

        fx.auth.removeSavedAccount(accountB)

        XCTAssertEqual(fx.store.settings(for: accountB.id), .empty, "the forgotten account")
        XCTAssertEqual(fx.store.settings(for: accountID).localURL, local.absoluteString, "the other account is untouched")
        XCTAssertTrue(fx.auth.isAuthenticated)

        await fx.auth.logout()

        XCTAssertEqual(fx.store.settings(for: accountID), .empty)
    }

    // MARK: - AC-240 (scope of the local data)

    func test_AC_240_localDataIsScopedByTheConnectionAddress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let offlineSuite = "scope-offline-\(UUID().uuidString)"
        let offlineDefaults = UserDefaults(suiteName: offlineSuite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            offlineDefaults.removePersistentDomain(forName: offlineSuite)
        }
        let offlineStore = OfflineAssetStore(
            rootURL: root.appendingPathComponent("OfflineAssets", isDirectory: true),
            transport: MockFileDownloadTransport(), defaults: offlineDefaults
        )
        let engine = BackupEngine(
            client: MockImmichClient(), source: MockBackupAssetSource(), environment: MockBackupEnvironment(),
            ledger: BackupLedger(fileURL: root.appendingPathComponent("ledger.json"))
        )
        let purger = LocalDataPurger(
            backupEngine: engine, offlineStore: offlineStore, offlineIndex: OfflineAssetIndex(),
            imageCache: ImageCache(),
            imageDiskCache: URLCache(
                memoryCapacity: 1 << 20, diskCapacity: 4 << 20, directory: root.appendingPathComponent("urlcache", isDirectory: true)
            ),
            apiClient: ImmichAPIClient(trustStore: TrustedServerStoreImpl(defaults: offlineDefaults)),
            serverSessions: NoopConnectionReset(),
            mapCacheDirectory: root.appendingPathComponent("caches", isDirectory: true)
        )
        let vpn = URL(string: "https://vpn.example.org")!
        let fx = makeFixture(
            settings: ServerAddressSettings(localURL: local.absoluteString, externalURL: vpn.absoluteString, autoSwitch: true),
            storedSession: false, localData: purger, deadline: .seconds(2)
        )
        fx.probe.answer(vpn, .immich(version: version))
        fx.probe.script(local, .init(result: .immich(version: version), delay: .milliseconds(300)))
        fx.auth.serverURLString = account.absoluteString

        await fx.auth.login(email: email, password: "pw")

        XCTAssertEqual(fx.auth.baseURL, vpn, "the address in use differs from the connection address")
        XCTAssertEqual(offlineStore.activeAccountID, accountID)

        await fx.endpoints.evaluate(.networkChange)

        XCTAssertEqual(fx.auth.baseURL, local)
        XCTAssertEqual(offlineStore.activeAccountID, accountID)
    }

    // MARK: - AC-238 (end of session)

    /// A session ends while the first evaluation waits on a slow local probe.
    private func makeEvaluationInFlight() async -> Fixture {
        let fx = makeFixture(settings: switchOn)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.script(local, .init(result: .immich(version: version), delay: .milliseconds(150)))
        await fx.auth.restoreSession()
        await waitUntil { fx.probe.callCount(for: self.local) >= 1 }
        return fx
    }

    private func assertNothingReopened(_ fx: Fixture, connects: Int, retargets: [URL]) {
        XCTAssertEqual(fx.mock.retargetedURLs, retargets, "no retarget to the local address")
        XCTAssertEqual(fx.transport.connects.count, connects, "no socket reopened")
        XCTAssertNil(fx.endpoints.activeURL)
        XCTAssertNil(fx.endpoints.accountID)
        XCTAssertNil(fx.book.accountURL)
        XCTAssertNil(fx.mock.configuredToken)
        XCTAssertNotEqual(fx.auth.baseURL, local)
    }

    func test_AC_238_signOutDuringAnEvaluationReopensNothing() async {
        let fx = await makeEvaluationInFlight()
        let connects = fx.transport.connects.count
        let retargets = fx.mock.retargetedURLs

        await fx.auth.logout()
        try? await Task.sleep(for: .milliseconds(400))

        assertNothingReopened(fx, connects: connects, retargets: retargets)
    }

    func test_AC_238_expiredSessionDuringAnEvaluationReopensNothing() async {
        let fx = await makeEvaluationInFlight()
        let connects = fx.transport.connects.count
        let retargets = fx.mock.retargetedURLs

        fx.auth.didReceiveUnauthorized()
        await waitUntil { fx.auth.sessionExpired }
        try? await Task.sleep(for: .milliseconds(400))

        assertNothingReopened(fx, connects: connects, retargets: retargets)
        XCTAssertEqual(fx.keychain.getToken(), "saved-jwt", "an expired session keeps the stored token")
    }

    func test_AC_238_signOutWaitingForTheServerReopensNothing() async {
        let fx = await makeEvaluationInFlight()
        let connects = fx.transport.connects.count
        let retargets = fx.mock.retargetedURLs
        let localProbes = fx.probe.callCount(for: local)
        let window = SignOutWindow()
        let endpoints = fx.endpoints
        let book = fx.book
        let mock = fx.mock
        // The sign-out request lasts: the slow probe answers meanwhile, then the network changes.
        mock.logoutGate = {
            try? await Task.sleep(for: .milliseconds(400))
            await endpoints.evaluate(.networkChange)
            let seen = await MainActor.run { (book.accountURL, mock.configuredToken) }
            window.set(accountURL: seen.0, token: seen.1)
        }

        await fx.auth.logout()

        XCTAssertEqual(window.seen.accountURL, account, "the sign-out request still has the account's aliases")
        XCTAssertEqual(window.seen.token, "saved-jwt", "and its token")
        assertNothingReopened(fx, connects: connects, retargets: retargets)
        XCTAssertEqual(fx.probe.callCount(for: local), localProbes, "the network change during the request probes nothing")
    }

    func test_AC_238_headerChangeReconnectsOnTheAddressInUse() async {
        let fx = makeFixture(settings: switchOn)
        fx.probe.answer(account, .immich(version: version))
        fx.probe.answer(local, .immich(version: version))
        await fx.auth.restoreSession()
        await fx.endpoints.evaluate(.networkChange)
        XCTAssertEqual(fx.auth.baseURL, local)
        XCTAssertEqual(fx.transport.connects.last?.baseURL, local)
        let before = fx.transport.connects.count

        fx.auth.customHeadersDidChange(for: ServerKey.of(account.absoluteString))

        XCTAssertEqual(fx.transport.connects.count, before + 1)
        XCTAssertEqual(fx.transport.connects.last?.baseURL, local)
        XCTAssertEqual(fx.transport.connects.last?.token, "saved-jwt")
        XCTAssertTrue(fx.auth.isAuthenticated)
    }
}
