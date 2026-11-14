import XCTest
@testable import ImmichSwiftUI

/// L-26: the address in use follows the probe, never the identity of the account.
@MainActor
final class ServerEndpointSwitchTests: XCTestCase {
    private let account = URL(string: "https://photos.example.org")!
    private let local = URL(string: "http://192.168.1.10:2283")!
    private let accountID = "https://photos.example.org|me"
    private let version = "1.119.0"

    private struct Rig {
        let sut: ServerEndpointSwitch
        let client: MockImmichClient
        let transport: MockRealtimeTransport
        let store: InMemoryServerAddressSettingsStore
        let probe: ScriptedServerAddressProbe
        let book: ServerAddressBook
    }

    private func makeRig(
        settings: ServerAddressSettings? = nil,
        headers: any CustomHeadersProviding = NoCustomHeaders(),
        log: any AppLogSink = NoopAppLogSink(),
        deadline: Duration = .milliseconds(200),
        denied: Bool = false,
        monitor: (any NetworkPathMonitoring)? = nil
    ) -> Rig {
        let client = MockImmichClient()
        let transport = MockRealtimeTransport()
        let store = InMemoryServerAddressSettingsStore()
        store.save(settings ?? ServerAddressSettings(localURL: local.absoluteString, autoSwitch: true), for: accountID)
        let probe = ScriptedServerAddressProbe()
        let book = ServerAddressBook()
        let sut = ServerEndpointSwitch(
            client: client, realtime: RealtimeService(transport: transport), store: store, probe: probe,
            monitor: monitor, addressBook: book, customHeaders: headers, appLog: log,
            probeDeadline: deadline, localNetworkDeniedOverride: denied
        )
        return Rig(sut: sut, client: client, transport: transport, store: store, probe: probe, book: book)
    }

    private func activate(_ rig: Rig, realtime: Bool = true) {
        rig.sut.activate(accountID: accountID, accountURL: account, token: "tok", connectRealtime: realtime)
    }

    /// Both addresses answer as the same server.
    private func bothAnswer(_ rig: Rig, localVersion: String? = nil) {
        rig.probe.answer(account, .immich(version: version))
        rig.probe.answer(local, .immich(version: localVersion ?? version))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: - AC-49

    func test_AC_49_localWinsWhenItAnswersAsThisServer() async {
        let rig = makeRig()
        bothAnswer(rig)
        activate(rig)
        XCTAssertEqual(rig.client.configuredBaseURL, account, "starts on the external address")

        await rig.sut.evaluate(.networkChange)

        XCTAssertEqual(rig.sut.activeURL, local)
        XCTAssertTrue(rig.sut.usesLocal)
        XCTAssertEqual(rig.client.configuredBaseURL, local)
        XCTAssertEqual(rig.sut.localStatus, .reachable)
        XCTAssertEqual(rig.sut.lastOutcome?.changedAddress, true)
        XCTAssertEqual(rig.book.activeURL, local)
        XCTAssertEqual(rig.sut.accountID, accountID, "the identity of the account does not move")
    }

    func test_AC_49_externalMuteUsesKnownVersion() async {
        let rig = makeRig(settings: ServerAddressSettings(localURL: local.absoluteString, autoSwitch: true, lastKnownVersion: version))
        rig.probe.answer(account, .unreachable)
        rig.probe.answer(local, .immich(version: version))
        activate(rig)

        await rig.sut.evaluate(.networkChange)

        XCTAssertEqual(rig.sut.activeURL, local)
        XCTAssertEqual(rig.sut.localStatus, .reachable)
        XCTAssertEqual(rig.sut.externalStatus, .unreachable)
    }

    func test_AC_49_evaluationOnlyRetargets() async {
        let rig = makeRig()
        bothAnswer(rig)
        activate(rig)
        let configures = rig.client.configureCount

        await rig.sut.evaluate(.foreground)

        XCTAssertEqual(rig.client.configureCount, configures, "only `activate` configures the client")
        XCTAssertEqual(rig.client.retargetedURLs, [account, local])
        XCTAssertEqual(rig.client.configuredToken, "tok")
    }

    func test_AC_49_refreshKnownVersion() async {
        let rig = makeRig(settings: ServerAddressSettings())
        rig.client.serverVersionResponse = ServerVersionResponseDto(major: 1, minor: 119, patch: 0, prerelease: nil)
        activate(rig)

        await rig.sut.refreshKnownVersion()

        XCTAssertEqual(rig.store.settings(for: accountID).lastKnownVersion, "1.119.0")
        XCTAssertEqual(rig.sut.settings.lastKnownVersion, "1.119.0")
    }

    func test_AC_49_aFailedVersionReadWritesNothing() async {
        let rig = makeRig(settings: ServerAddressSettings())
        rig.client.serverVersionError = URLError(.notConnectedToInternet)
        activate(rig)

        await rig.sut.refreshKnownVersion()

        XCTAssertNil(rig.store.settings(for: accountID).lastKnownVersion)
    }

    func test_AC_49_aNetworkChangeFromTheMonitorEvaluates() async {
        let monitor = FakeNetworkPathMonitor()
        let rig = makeRig(monitor: monitor)
        bothAnswer(rig)
        XCTAssertEqual(monitor.startCount, 1)
        activate(rig)
        await waitUntil { rig.sut.usesLocal }

        rig.probe.answer(local, .unreachable)
        monitor.fireChange()
        await waitUntil { !rig.sut.usesLocal }

        XCTAssertFalse(rig.sut.usesLocal)
        XCTAssertEqual(rig.sut.activeURL, account)
    }

    // MARK: - AC-236

    func test_AC_236_foregroundRetargets() async {
        let rig = makeRig()
        bothAnswer(rig)
        activate(rig)
        await rig.sut.evaluate(.networkChange)
        XCTAssertTrue(rig.sut.usesLocal)

        rig.probe.script(local, .init(result: .immich(version: version), delay: .seconds(5)))
        let started = Date()
        await rig.sut.evaluate(.foreground)

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "an evaluation never waits for a slow address")
        XCTAssertEqual(rig.sut.activeURL, account)
        XCTAssertEqual(rig.client.configuredBaseURL, account)
        XCTAssertEqual(rig.sut.localStatus, .unreachable)
    }

    func test_AC_236_localComesBackOnTheNextNetworkChange() async {
        let rig = makeRig()
        rig.probe.answer(account, .immich(version: version))
        rig.probe.answer(local, .unreachable)
        activate(rig)
        await rig.sut.evaluate(.foreground)
        XCTAssertEqual(rig.sut.activeURL, account)

        rig.probe.answer(local, .immich(version: version))
        await rig.sut.evaluate(.networkChange)

        XCTAssertEqual(rig.sut.activeURL, local)
        XCTAssertEqual(rig.sut.accountID, accountID, "no return to the connection screen")
    }

    func test_AC_236_evaluationIsBoundedByItsDeadline() async {
        let rig = makeRig()
        rig.probe.answer(account, .immich(version: version))
        rig.probe.script(local, .init(result: .immich(version: version), delay: .seconds(60)))
        activate(rig)

        let started = Date()
        await rig.sut.evaluate(.networkChange)

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2 + 0.5, "deadline + 0.5 s at most")
        XCTAssertEqual(rig.sut.activeURL, account)
        XCTAssertFalse(rig.sut.isEvaluating)
    }

    func test_AC_236_resultOfAnOlderEvaluationIsIgnored() async {
        let rig = makeRig(deadline: .seconds(2))
        rig.probe.answer(account, .immich(version: version))
        rig.probe.script(
            local,
            .init(result: .immich(version: version), delay: .milliseconds(500)),
            .init(result: .unreachable)
        )
        activate(rig)

        let first = Task { await rig.sut.evaluate(.networkChange) }
        await waitUntil { rig.probe.callCount(for: self.local) == 1 }
        await rig.sut.evaluate(.networkChange)
        await first.value
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(rig.sut.activeURL, account, "the late answer of the first evaluation must not win")
        XCTAssertEqual(rig.sut.localStatus, .unreachable)
    }

    /// The Network screen starts an evaluation when it opens. Clearing the local
    /// address while that probe is still out must not let its answer write the
    /// state of an address that no longer exists.
    /// `activate` already starts the `.launch` evaluation (switch on, local address
    /// declared): that is the one left suspended on its 500 ms probe. No second
    /// evaluation is started, so the probe count and `isEvaluating` are deterministic.
    func test_AC_235_clearingLocalDuringAProbeLeavesNoStaleState() async {
        let rig = makeRig(deadline: .seconds(2))
        rig.probe.answer(account, .immich(version: version))
        rig.probe.script(local, .init(result: .immich(version: version), delay: .milliseconds(500)))
        activate(rig)

        await waitUntil { rig.probe.callCount(for: self.local) >= 1 }
        XCTAssertEqual(rig.probe.callCount(for: local), 1)
        XCTAssertTrue(rig.sut.isEvaluating)

        await rig.sut.save(ServerAddressSettings(localURL: nil, autoSwitch: true))
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(rig.sut.localStatus, .notConfigured, "no state row under an empty local field")
        XCTAssertNil(rig.sut.localURL)
        XCTAssertNil(rig.sut.externalStatus, "the stale evaluation must not write the external state either")
        XCTAssertFalse(rig.sut.isEvaluating)
        XCTAssertEqual(rig.sut.activeURL, account)
        XCTAssertFalse(rig.sut.usesLocal)
    }

    // MARK: - AC-237

    func test_AC_237_bothUnreachableKeepsTheSession() async {
        let rig = makeRig()
        rig.probe.answer(account, .unreachable)
        rig.probe.answer(local, .unreachable)
        activate(rig)

        await rig.sut.evaluate(.networkChange)

        XCTAssertEqual(rig.sut.accountID, accountID)
        XCTAssertEqual(rig.client.configuredToken, "tok", "never signed out")
        XCTAssertEqual(rig.sut.activeURL, account)
        XCTAssertEqual(rig.sut.externalStatus, .unreachable)
        XCTAssertEqual(rig.sut.lastOutcome?.changedAddress, false)

        bothAnswer(rig)
        await rig.sut.evaluate(.networkChange)
        XCTAssertEqual(rig.sut.activeURL, local)
        XCTAssertEqual(rig.sut.lastOutcome?.changedAddress, true)
    }

    // MARK: - AC-238

    func test_AC_238_requestsAndSocketFollowSwitch() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let api = ImmichAPIClient(session: URLSession(configuration: config))
        let transport = MockRealtimeTransport()
        let probe = ScriptedServerAddressProbe()
        let store = InMemoryServerAddressSettingsStore()
        store.save(ServerAddressSettings(localURL: local.absoluteString, autoSwitch: true), for: accountID)
        let sut = ServerEndpointSwitch(
            client: api, realtime: RealtimeService(transport: transport), store: store, probe: probe,
            monitor: nil, addressBook: ServerAddressBook(), customHeaders: NoCustomHeaders(), appLog: NoopAppLogSink(),
            probeDeadline: .milliseconds(200)
        )
        probe.answer(account, .immich(version: version))
        probe.answer(local, .immich(version: version))
        sut.activate(accountID: accountID, accountURL: account, token: "tok", connectRealtime: true)
        XCTAssertEqual(transport.connects.last?.baseURL, account)

        await sut.evaluate(.networkChange)
        CapturingURLProtocol.reset()
        _ = try? await api.validateToken()
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.url?.host, "192.168.1.10")
        XCTAssertEqual(transport.connects.last?.baseURL, local, "the socket follows the address")

        probe.answer(local, .unreachable)
        await sut.evaluate(.networkChange)
        CapturingURLProtocol.reset()
        _ = try? await api.validateToken()
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.url?.host, "photos.example.org")
        XCTAssertEqual(transport.connects.last?.baseURL, account)
        XCTAssertEqual(transport.connects.last?.token, "tok")
    }

    // MARK: - AC-243

    func test_AC_243_noProbeWithoutALocalAddress() async {
        let rig = makeRig(settings: ServerAddressSettings())
        activate(rig)

        await rig.sut.evaluate(.networkChange)
        await rig.sut.evaluate(.foreground)

        XCTAssertTrue(rig.probe.calls.isEmpty)
        XCTAssertEqual(rig.client.configuredBaseURL, account)
        XCTAssertEqual(rig.sut.localStatus, .notConfigured)
    }

    func test_AC_243_switchOffNeverProbes() async {
        let rig = makeRig(settings: ServerAddressSettings(localURL: local.absoluteString, autoSwitch: false))
        activate(rig)

        for reason in [EvaluationReason.launch, .foreground, .networkChange, .backgroundPass] {
            await rig.sut.evaluate(reason)
        }

        XCTAssertTrue(rig.probe.calls.isEmpty)
        XCTAssertEqual(rig.sut.activeURL, account)
    }

    func test_AC_243_turningTheSwitchOffReturnsToExternalWithoutSigningOut() async {
        let rig = makeRig()
        bothAnswer(rig)
        activate(rig)
        await rig.sut.evaluate(.networkChange)
        XCTAssertEqual(rig.transport.connects.last?.baseURL, local)

        var settings = rig.sut.settings
        settings.autoSwitch = false
        await rig.sut.save(settings)

        XCTAssertEqual(rig.client.configuredBaseURL, account)
        XCTAssertEqual(rig.sut.activeURL, account)
        XCTAssertFalse(rig.sut.usesLocal)
        XCTAssertEqual(rig.transport.connects.last?.baseURL, account, "the socket leaves the local address too")
        XCTAssertEqual(rig.client.configuredToken, "tok")
    }

    func test_AC_243_modifiedExternalAddressIsTheAddressInUse() async {
        let rig = makeRig(settings: ServerAddressSettings(externalURL: "vpn.example.net"))
        activate(rig)

        XCTAssertEqual(rig.client.configuredBaseURL, URL(string: "https://vpn.example.net"))
        XCTAssertEqual(rig.sut.externalURL, URL(string: "https://vpn.example.net"))
        XCTAssertEqual(rig.sut.publicURL, URL(string: "https://vpn.example.net"))
        XCTAssertEqual(rig.book.accountURL, account, "the identity keeps the connection address")
        XCTAssertTrue(rig.probe.calls.isEmpty)
    }

    // MARK: - AC-244

    func test_AC_244_settingsFollowTheAccount() async {
        let rig = makeRig()
        bothAnswer(rig)
        activate(rig)
        await rig.sut.evaluate(.networkChange)
        XCTAssertEqual(rig.sut.activeURL, local)
        let probesBefore = rig.probe.calls.count

        let other = URL(string: "https://other.example.org")!
        rig.sut.activate(accountID: "https://other.example.org|me", accountURL: other, token: "tok2", connectRealtime: true)
        await rig.sut.evaluate(.foreground)

        XCTAssertEqual(rig.sut.activeURL, other)
        XCTAssertEqual(rig.client.configuredBaseURL, other)
        XCTAssertEqual(rig.probe.calls.count, probesBefore, "the second account has no local address: no probe")
        XCTAssertEqual(rig.sut.knownURLs, [other])
    }

    func test_AC_244_forgetRemovesTheSettingsOfAnAccount() {
        let rig = makeRig()
        rig.sut.forget(accountID: accountID)
        XCTAssertEqual(rig.store.settings(for: accountID), .empty)
        rig.store.save(ServerAddressSettings(autoSwitch: true), for: "x")
        rig.sut.forgetAll()
        XCTAssertEqual(rig.store.settings(for: "x"), .empty)
    }

    // MARK: - AC-245

    func test_AC_245_bothAddressesRedacted() {
        let store = AppLogStore()
        let rig = makeRig(
            settings: ServerAddressSettings(localURL: local.absoluteString, externalURL: "https://vpn.example.net:8443", autoSwitch: true),
            log: store
        )
        activate(rig)

        store.record(AppLogEntry(
            level: .warning, method: "GET", path: "/api/server/ping", category: "HTTP",
            message: "GET http://192.168.1.10:2283/api/server/ping failed",
            details: "could not connect to vpn.example.net:8443 or photos.example.org"
        ))

        let text = store.snapshot().map { [$0.message, $0.details ?? ""].joined(separator: " ") }.joined(separator: "\n")
        for secret in ["192.168.1.10", "2283", "vpn.example.net", "8443"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked into the log")
        }
    }

    // MARK: - AC-246

    func test_AC_246_aServerThatIsNotImmichIsNotRetained() async {
        let rig = makeRig()
        rig.probe.answer(account, .immich(version: version))
        rig.probe.answer(local, .notImmich)
        activate(rig)

        await rig.sut.evaluate(.networkChange)

        XCTAssertEqual(rig.sut.activeURL, account)
        XCTAssertEqual(rig.sut.localStatus, .notThisServer)
    }

    func test_AC_246_anotherVersionIsNotRetained() async {
        let rig = makeRig()
        bothAnswer(rig, localVersion: "1.118.0")
        activate(rig)

        await rig.sut.evaluate(.networkChange)

        XCTAssertEqual(rig.sut.activeURL, account)
        XCTAssertEqual(rig.sut.localStatus, .notThisServer)
    }

    func test_AC_246_newerLocalVersionRejected() async {
        let rig = makeRig(settings: ServerAddressSettings(localURL: local.absoluteString, autoSwitch: true, lastKnownVersion: version))
        rig.probe.answer(account, .unreachable)
        rig.probe.answer(local, .immich(version: "1.120.0"))
        activate(rig)

        await rig.sut.evaluate(.networkChange)

        XCTAssertEqual(rig.sut.activeURL, account)
        XCTAssertEqual(rig.sut.localStatus, .notThisServer)
    }

    func test_AC_246_theProbeCarriesTheAccountHeaders() async {
        let rig = makeRig(headers: StaticCustomHeaders([StaticCustomHeaders.xAccess], for: account.absoluteString))
        bothAnswer(rig)
        activate(rig)

        await rig.sut.evaluate(.networkChange)

        XCTAssertFalse(rig.probe.calls.isEmpty)
        for call in rig.probe.calls {
            XCTAssertEqual(call.headers, [StaticCustomHeaders.xAccess], "\(call.url) must carry the header")
        }
    }

    // MARK: - AC-248

    func test_AC_248_launchStartsOnExternal() async {
        let rig = makeRig()
        rig.probe.answer(account, .immich(version: version))
        rig.probe.script(local, .init(result: .immich(version: version), delay: .seconds(3)))
        activate(rig)

        XCTAssertEqual(rig.client.configuredBaseURL, account, "the first request already goes external")
        XCTAssertEqual(rig.sut.activeURL, account)
        XCTAssertEqual(rig.client.configureCount, 1)
        await rig.sut.evaluate(.launch)
        XCTAssertEqual(rig.sut.activeURL, account, "a silent local address never takes over")
    }

    // MARK: - AC-250

    func test_AC_250_deniedLocalNetworkGivesTheDeniedStateAndExternal() async {
        let rig = makeRig(denied: true)
        rig.probe.answer(account, .immich(version: version))
        activate(rig)

        await rig.sut.evaluate(.networkChange)

        XCTAssertEqual(rig.sut.localStatus, .localNetworkDenied)
        XCTAssertEqual(rig.sut.activeURL, account)
        XCTAssertEqual(rig.probe.callCount(for: local), 0, "the denial is a test switch: nothing is sent")
    }

    // MARK: - AC-235

    func test_AC_235_externalSaveProbesOnce() async {
        let rig = makeRig(settings: ServerAddressSettings())
        let vpn = URL(string: "https://vpn.example.net")!
        rig.probe.answer(vpn, .immich(version: version))
        activate(rig)

        var settings = rig.sut.settings
        settings.externalURL = "vpn.example.net"
        await rig.sut.save(settings)

        XCTAssertEqual(rig.probe.calls.map(\.url), [vpn])
        XCTAssertEqual(rig.client.configuredBaseURL, vpn)
        XCTAssertEqual(rig.sut.externalStatus, .reachable)
        XCTAssertEqual(rig.store.settings(for: accountID).lastKnownVersion, version)
        XCTAssertFalse(rig.sut.isEvaluating)
    }

    func test_AC_235_unreachableExternalSavedWithState() async {
        let rig = makeRig(settings: ServerAddressSettings())
        let vpn = URL(string: "https://vpn.example.net")!
        rig.probe.answer(vpn, .unreachable)
        activate(rig)

        var settings = rig.sut.settings
        settings.externalURL = vpn.absoluteString
        await rig.sut.save(settings)

        XCTAssertEqual(rig.store.settings(for: accountID).externalURL, vpn.absoluteString, "saved")
        XCTAssertEqual(rig.client.configuredBaseURL, vpn, "and applied")
        XCTAssertEqual(rig.sut.externalStatus, .unreachable)
    }

    func test_AC_235_unreachableLocalIsSavedWithItsState() async {
        let rig = makeRig(settings: ServerAddressSettings())
        rig.probe.answer(account, .immich(version: version))
        rig.probe.answer(local, .unreachable)
        activate(rig)
        XCTAssertEqual(rig.sut.localStatus, .notConfigured)

        var settings = rig.sut.settings
        settings.localURL = local.absoluteString
        await rig.sut.save(settings)

        XCTAssertEqual(rig.store.settings(for: accountID).localURL, local.absoluteString)
        XCTAssertEqual(rig.sut.localStatus, .unreachable)
        XCTAssertEqual(rig.sut.activeURL, account, "the switch is off: the address in use does not move")
    }

    func test_AC_235_localAnsweringAsThisServerIsReachable() async {
        let rig = makeRig(settings: ServerAddressSettings())
        bothAnswer(rig)
        activate(rig)

        var settings = rig.sut.settings
        settings.localURL = local.absoluteString
        await rig.sut.save(settings)

        XCTAssertEqual(rig.sut.localStatus, .reachable)
        XCTAssertEqual(rig.sut.activeURL, account)
    }
}
