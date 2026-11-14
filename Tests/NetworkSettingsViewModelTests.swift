import XCTest
@testable import ImmichSwiftUI

/// L-26: the "Network" setting, driven through the real service and a scripted probe.
@MainActor
final class NetworkSettingsViewModelTests: XCTestCase {
    private final class FakeTrustStore: TrustedServerStore {
        var hosts: Set<String> = []
        func contains(_ host: String) -> Bool { hosts.contains(host) }
        func add(_ host: String) { hosts.insert(host) }
        func removeAll() { hosts = [] }
    }

    private let account = URL(string: "https://photos.example.org")!
    private let local = URL(string: "http://192.168.1.10:2283")!
    private let accountID = "https://photos.example.org|me"
    private let version = "1.119.0"

    private struct Rig {
        let vm: NetworkSettingsViewModel
        let endpoints: ServerEndpointSwitch
        let client: MockImmichClient
        let probe: ScriptedServerAddressProbe
        let store: InMemoryServerAddressSettingsStore
        let trust: FakeTrustStore
        let externalChanged: TestBox<Int>
    }

    private func makeRig(settings: ServerAddressSettings = .empty, testControls: Bool = false, denied: Bool = false) -> Rig {
        let client = MockImmichClient()
        let store = InMemoryServerAddressSettingsStore()
        store.save(settings, for: accountID)
        let probe = ScriptedServerAddressProbe()
        let endpoints = ServerEndpointSwitch(
            client: client, realtime: RealtimeService(transport: MockRealtimeTransport()), store: store, probe: probe,
            monitor: nil, addressBook: ServerAddressBook(), customHeaders: NoCustomHeaders(), appLog: NoopAppLogSink(),
            probeDeadline: .milliseconds(200), localNetworkDeniedOverride: denied
        )
        endpoints.activate(accountID: accountID, accountURL: account, token: "tok", connectRealtime: false)
        let trust = FakeTrustStore()
        let changed = TestBox(0)
        let vm = NetworkSettingsViewModel(
            endpoints: endpoints, trustStore: trust, accountURL: account, showsTestControls: testControls,
            onExternalChanged: { changed.value += 1 }
        )
        return Rig(vm: vm, endpoints: endpoints, client: client, probe: probe, store: store, trust: trust, externalChanged: changed)
    }

    // MARK: - AC-235

    func test_AC_235_initialState() {
        let rig = makeRig()
        XCTAssertFalse(rig.vm.autoSwitch)
        XCTAssertEqual(rig.vm.externalText, account.absoluteString, "the external address is the connection address")
        XCTAssertEqual(rig.vm.localText, "")
        XCTAssertEqual(rig.vm.localStatus, .notConfigured)
        XCTAssertNil(rig.vm.externalStatus)
        XCTAssertEqual(rig.vm.activeAddressText, account.absoluteString)
        XCTAssertFalse(rig.vm.usesLocal)
    }

    func test_AC_235_malformedLocalAddressIsRefusedAndNothingSaved() async {
        let rig = makeRig()
        rig.vm.localText = "http://a b"

        await rig.vm.saveLocal()

        XCTAssertNotNil(rig.vm.localValidationMessage)
        XCTAssertEqual(rig.store.settings(for: accountID), .empty)
        XCTAssertTrue(rig.probe.calls.isEmpty)
    }

    func test_AC_235_unreachableLocalAddressIsSavedWithItsState() async {
        let rig = makeRig()
        rig.probe.answer(account, .immich(version: version))
        rig.probe.answer(local, .unreachable)
        rig.vm.localText = local.absoluteString

        await rig.vm.saveLocal()

        XCTAssertNil(rig.vm.localValidationMessage)
        XCTAssertEqual(rig.store.settings(for: accountID).localURL, local.absoluteString)
        XCTAssertEqual(rig.vm.localStatus, .unreachable)
    }

    func test_AC_235_localAnsweringAsThisServerIsReachable() async {
        let rig = makeRig()
        rig.probe.answer(account, .immich(version: version))
        rig.probe.answer(local, .immich(version: version))
        rig.vm.localText = local.absoluteString

        await rig.vm.saveLocal()

        XCTAssertEqual(rig.vm.localStatus, .reachable)
        XCTAssertEqual(rig.vm.activeAddressText, account.absoluteString, "the switch is off: nothing moves")
    }

    func test_AC_235_unreachableExternalSavedWithState() async {
        let rig = makeRig()
        let vpn = URL(string: "https://vpn.example.net")!
        rig.probe.answer(vpn, .unreachable)
        rig.vm.externalText = "vpn.example.net"

        await rig.vm.saveExternal()

        XCTAssertEqual(rig.store.settings(for: accountID).externalURL, vpn.absoluteString)
        XCTAssertEqual(rig.client.configuredBaseURL, vpn)
        XCTAssertEqual(rig.vm.externalStatus, .unreachable)
        XCTAssertEqual(rig.externalChanged.value, 1, "the session of the widgets is told")
    }

    func test_AC_235_emptyExternalAddressGoesBackToTheConnectionAddress() async {
        let rig = makeRig(settings: ServerAddressSettings(externalURL: "https://vpn.example.net"))
        rig.vm.externalText = "  "

        await rig.vm.saveExternal()

        XCTAssertNil(rig.store.settings(for: accountID).externalURL)
        XCTAssertEqual(rig.vm.externalText, account.absoluteString)
        XCTAssertEqual(rig.client.configuredBaseURL, account)
    }

    // MARK: - AC-241

    func test_AC_241_untrustedLocalAsksTrust() async {
        let rig = makeRig()
        rig.probe.answer(account, .immich(version: version))
        rig.probe.answer(local, .untrustedCertificate(host: "192.168.1.10"))
        rig.vm.localText = local.absoluteString

        await rig.vm.saveLocal()

        XCTAssertEqual(rig.vm.localStatus, .untrusted(host: "192.168.1.10"))
        XCTAssertEqual(rig.vm.pendingUntrustedHost, "192.168.1.10")

        rig.probe.answer(local, .immich(version: version))
        let probes = rig.probe.callCount(for: local)
        await rig.vm.trustPendingHost()

        XCTAssertTrue(rig.trust.contains("192.168.1.10"))
        XCTAssertNil(rig.vm.pendingUntrustedHost)
        XCTAssertGreaterThan(rig.probe.callCount(for: local), probes, "the probe runs again once trusted")
        XCTAssertEqual(rig.vm.localStatus, .reachable)
    }

    func test_AC_241_untrustedExternalAsksTrust() async {
        let rig = makeRig()
        let vpn = URL(string: "https://vpn.example.net")!
        rig.probe.answer(vpn, .untrustedCertificate(host: "vpn.example.net"))
        rig.vm.externalText = vpn.absoluteString

        await rig.vm.saveExternal()

        XCTAssertEqual(rig.vm.externalStatus, .untrusted(host: "vpn.example.net"))
        XCTAssertEqual(rig.vm.pendingUntrustedHost, "vpn.example.net")

        rig.probe.answer(vpn, .immich(version: version))
        await rig.vm.trustPendingHost()

        XCTAssertTrue(rig.trust.contains("vpn.example.net"))
        XCTAssertEqual(rig.vm.externalStatus, .reachable, "the probe of the external address runs again")
    }

    // MARK: - AC-242

    func test_AC_242_activeAddressFollowsTheService() async {
        let rig = makeRig(settings: ServerAddressSettings(localURL: local.absoluteString, autoSwitch: true), testControls: true)
        rig.probe.answer(account, .immich(version: version))
        rig.probe.answer(local, .immich(version: version))
        await rig.vm.simulateNetworkChange()
        XCTAssertTrue(rig.vm.usesLocal)
        XCTAssertEqual(rig.vm.activeAddressText, local.absoluteString)

        rig.probe.answer(local, .unreachable)
        await rig.vm.simulateNetworkChange()

        XCTAssertFalse(rig.vm.usesLocal)
        XCTAssertEqual(rig.vm.activeAddressText, account.absoluteString)
    }

    func test_AC_242_simulatedChangeNeedsTheTestControls() async {
        let rig = makeRig(settings: ServerAddressSettings(localURL: local.absoluteString, autoSwitch: true), testControls: false)
        rig.probe.answer(account, .immich(version: version))
        rig.probe.answer(local, .immich(version: version))
        // `activate` already started a launch evaluation; let it settle first.
        await rig.endpoints.evaluate(.launch)
        let probes = rig.probe.calls.count

        await rig.vm.simulateNetworkChange()

        XCTAssertEqual(rig.probe.calls.count, probes, "without the test switch the control does nothing")
    }

    func test_AC_242_switchingOnAndOffFollowsTheService() async {
        let rig = makeRig(settings: ServerAddressSettings(localURL: local.absoluteString))
        rig.probe.answer(account, .immich(version: version))
        rig.probe.answer(local, .immich(version: version))

        await rig.vm.setAutoSwitch(true)
        XCTAssertTrue(rig.vm.autoSwitch)
        XCTAssertTrue(rig.vm.usesLocal)
        XCTAssertTrue(rig.store.settings(for: accountID).autoSwitch)

        await rig.vm.setAutoSwitch(false)
        XCTAssertFalse(rig.vm.usesLocal)
        XCTAssertEqual(rig.client.configuredBaseURL, account)
    }

    // MARK: - AC-250

    func test_AC_250_deniedLocalNetworkShowsTheStateAndStaysExternal() async {
        let rig = makeRig(settings: ServerAddressSettings(localURL: local.absoluteString, autoSwitch: true), denied: true)
        rig.probe.answer(account, .immich(version: version))

        await rig.vm.refreshStatus()

        XCTAssertEqual(rig.vm.localStatus, .localNetworkDenied)
        XCTAssertEqual(rig.vm.activeAddressText, account.absoluteString)
        XCTAssertNil(rig.vm.localValidationMessage, "no error message: a refusal is a state, not a failure")
        XCTAssertNil(rig.vm.externalValidationMessage)
    }
}
