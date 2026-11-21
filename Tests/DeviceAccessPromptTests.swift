import XCTest
import Photos
@testable import ImmichSwiftUI

/// The timeline asks for Photos access on its first appearance, only when it was
/// never answered. Pure decision, no view, no PhotoKit.
final class DeviceAccessPromptTests: XCTestCase {

    private let remote = URL(string: "https://photos.example.com")

    private func ask(
        _ status: PHAuthorizationStatus = .notDetermined,
        shows: Bool = true,
        url: URL?
    ) -> Bool {
        DeviceAccessPrompt.shouldAsk(status: status, showsDeviceAssets: shows, serverURL: url)
    }

    /// AC-1, AC-3: a fresh install and an installed app that never answered both ask.
    func test_AC1_AC3_asksWhenAccessWasNeverAnswered() {
        XCTAssertTrue(ask(url: remote))
    }

    /// AC-2: an unknown server address does not stop the prompt, so the granted
    /// access reloads the device photos into the timeline.
    func test_AC2_asksWithoutServerURL() {
        XCTAssertTrue(ask(url: nil))
    }

    /// AC-4: once answered, never asked again (the banner leads to Settings).
    func test_AC4_neverAsksAgainOnceAnswered() {
        for status: PHAuthorizationStatus in [.authorized, .limited, .denied, .restricted] {
            XCTAssertFalse(ask(status, url: remote), "status \(status.rawValue)")
            XCTAssertFalse(ask(status, url: nil), "status \(status.rawValue), no URL")
        }
    }

    /// AC-5: "Show Photos from This Device" off, no automatic request.
    func test_AC5_doesNotAskWhenSettingIsOff() {
        XCTAssertFalse(ask(shows: false, url: remote))
        XCTAssertFalse(ask(shows: false, url: nil))
    }

    #if DEBUG
    /// AC-6: a Debug build against a local stub never asks.
    func test_AC6_debugDoesNotAskAgainstLocalServer() {
        for address in ["http://127.0.0.1:8421", "http://localhost:8422", "http://[::1]:8421", "http://LocalHost:8422"] {
            XCTAssertFalse(ask(url: URL(string: address)), address)
        }
    }

    /// AC-6: the exception is the loopback only, not a LAN or lookalike host.
    func test_AC6_debugStillAsksAgainstOtherHosts() {
        for address in ["http://192.168.1.20:2283", "https://localhost.example.com", "https://photos.example.com:8421"] {
            XCTAssertTrue(ask(url: URL(string: address)), address)
        }
    }
    #else
    /// AC-6: a Release build asks whatever the host.
    func test_AC6_releaseAsksAgainstLocalServer() {
        for address in ["http://127.0.0.1:8421", "http://localhost:8422", "http://[::1]:8421"] {
            XCTAssertTrue(ask(url: URL(string: address)), address)
        }
    }
    #endif
}
