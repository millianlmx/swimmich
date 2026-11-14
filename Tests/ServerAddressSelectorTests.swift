import XCTest
@testable import ImmichSwiftUI

/// The rule that picks the address in use: pure, no network.
final class ServerAddressSelectorTests: XCTestCase {
    private let account = URL(string: "https://photos.example.org")!
    private let local = URL(string: "http://192.168.1.10:2283")!

    private func settings(autoSwitch: Bool = true, local: String? = "http://192.168.1.10:2283",
                          external: String? = nil, lastKnown: String? = nil) -> ServerAddressSettings {
        ServerAddressSettings(localURL: local, externalURL: external, autoSwitch: autoSwitch, lastKnownVersion: lastKnown)
    }

    private func choose(_ settings: ServerAddressSettings, _ probe: ServerAddressProbeResult?, external: String?) -> (url: URL, usesLocal: Bool) {
        ServerAddressSelector.choose(settings: settings, accountURL: account, local: probe, externalVersion: external)
    }

    func test_AC_246_localWinsOnlyAsThisServer() {
        XCTAssertEqual(choose(settings(), .immich(version: "1.119.0"), external: "1.119.0").url, local)
        XCTAssertTrue(choose(settings(), .immich(version: "1.119.0"), external: "1.119.0").usesLocal)
        let others: [ServerAddressProbeResult?] = [
            .immich(version: "1.118.0"), .notImmich, .unreachable, .localNetworkDenied,
            .untrustedCertificate(host: "h"), nil,
        ]
        for result in others {
            let chosen = choose(settings(), result, external: "1.119.0")
            XCTAssertEqual(chosen.url, account, "\(String(describing: result))")
            XCTAssertFalse(chosen.usesLocal)
        }
    }

    func test_AC_49_switchOffOrNoLocalAddressStaysExternal() {
        XCTAssertEqual(choose(settings(autoSwitch: false), .immich(version: "1.119.0"), external: "1.119.0").url, account)
        XCTAssertEqual(choose(settings(local: nil), .immich(version: "1.119.0"), external: "1.119.0").url, account)
        XCTAssertEqual(choose(settings(local: "http://a b"), .immich(version: "1.119.0"), external: "1.119.0").url, account)
    }

    func test_AC_49_muteExternalFallsBackOnLastKnownVersion() {
        let known = settings(lastKnown: "1.119.0")
        XCTAssertTrue(choose(known, .immich(version: "1.119.0"), external: nil).usesLocal)
        XCTAssertFalse(choose(known, .immich(version: "1.120.0"), external: nil).usesLocal)
        XCTAssertFalse(choose(settings(), .immich(version: "1.119.0"), external: nil).usesLocal)
    }

    func test_AC_243_modifiedExternalAddressIsTheChoice() {
        let modified = settings(external: "https://other.example.org/")
        let expected = URL(string: "https://other.example.org")!
        XCTAssertEqual(choose(modified, .unreachable, external: nil).url, expected)
        XCTAssertEqual(ServerAddressSelector.externalURL(settings: modified, accountURL: account), expected)
        XCTAssertEqual(ServerAddressSelector.externalURL(settings: settings(external: "http://a b"), accountURL: account), account)
        XCTAssertEqual(ServerAddressSelector.externalURL(settings: .empty, accountURL: account), account)
    }

    func test_AC_246_statusOfLocalAddress() {
        let status = { (result: ServerAddressProbeResult, reference: String?) in
            ServerAddressSelector.status(local: result, reference: reference)
        }
        XCTAssertEqual(status(.immich(version: "1.119.0"), "1.119.0"), .reachable)
        XCTAssertEqual(status(.immich(version: "1.120.0"), "1.119.0"), .notThisServer)
        XCTAssertEqual(status(.immich(version: "1.119.0"), nil), .notThisServer)
        XCTAssertEqual(status(.notImmich, "1.119.0"), .notThisServer)
        XCTAssertEqual(status(.unreachable, nil), .unreachable)
        XCTAssertEqual(status(.localNetworkDenied, nil), .localNetworkDenied)
        XCTAssertEqual(status(.untrustedCertificate(host: "h"), nil), .untrusted(host: "h"))
    }

    func test_AC_235_externalIsTheReferenceItsVersionIsNotCompared() {
        XCTAssertEqual(ServerAddressSelector.status(external: .immich(version: "9.9.9")), .reachable)
        XCTAssertEqual(ServerAddressSelector.status(external: .notImmich), .notThisServer)
        XCTAssertEqual(ServerAddressSelector.status(external: .unreachable), .unreachable)
    }
}
