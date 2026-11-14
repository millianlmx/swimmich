import XCTest
@testable import ImmichSwiftUI

/// L-26: a background pass evaluates the address before it uploads.
@MainActor
final class BackgroundBackupPassTests: XCTestCase {
    func test_AC_247_backgroundPassUploadsToExternal() async {
        let account = URL(string: "https://photos.example.org")!
        let local = URL(string: "http://192.168.1.10:2283")!
        let id = "https://photos.example.org|me"
        let mock = MockImmichClient()
        let store = InMemoryServerAddressSettingsStore()
        store.save(ServerAddressSettings(localURL: local.absoluteString, autoSwitch: true), for: id)
        let probe = ScriptedServerAddressProbe()
        probe.answer(account, .immich(version: "1.119.0"))
        probe.answer(local, .immich(version: "1.119.0"))
        let endpoints = ServerEndpointSwitch(
            client: mock, realtime: RealtimeService(transport: MockRealtimeTransport()), store: store, probe: probe,
            monitor: nil, addressBook: ServerAddressBook(), customHeaders: NoCustomHeaders(), appLog: NoopAppLogSink(),
            probeDeadline: .milliseconds(200)
        )
        endpoints.activate(accountID: id, accountURL: account, token: "tok", connectRealtime: false)
        await endpoints.evaluate(.networkChange)
        XCTAssertEqual(endpoints.activeURL, local, "the last evaluation retained the local address")

        // The phone left the home network: the local address is out of reach.
        probe.answer(local, .unreachable)
        let probesBefore = probe.callCount(for: local)
        var uploadedTo: URL?
        let pass = BackgroundBackupPass(
            evaluate: { await endpoints.evaluate(.backgroundPass) },
            runBackup: { uploadedTo = mock.configuredBaseURL }
        )

        await pass.run()

        XCTAssertEqual(uploadedTo, account, "the upload goes to the external address")
        XCTAssertEqual(probe.callCount(for: local) - probesBefore, 1, "the local address only received the probe")
    }

    func test_AC_247_evaluationRunsBeforeTheEngine() async {
        var order: [String] = []
        let pass = BackgroundBackupPass(evaluate: { order.append("evaluate") }, runBackup: { order.append("backup") })
        await pass.run()
        XCTAssertEqual(order, ["evaluate", "backup"])
    }
}
