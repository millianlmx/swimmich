import SwiftUI
import UIKit
import XCTest
@testable import ImmichSwiftUI

/// L-13 (AC-26.3, AC-26.8) on whole screens: each screen is hosted at AX5, in
/// English and in German, with a long and a short label side by side, and read
/// through its accessibility tree (`HostedScreen`). Same measurements as the
/// walks of `DynamicTypeUITests`, without a launched app.
@MainActor
final class DynamicTypeScreenTests: XCTestCase {

    private static let longPartnerName = "Maximiliana Wilhelmina Konstantinopoulou-Featherstonehaugh"

    private final class NoWidgetSession: WidgetSessionStoring, @unchecked Sendable {
        func save(_ session: WidgetSession) {}
        func load() -> WidgetSession? { nil }
        func clear() {}
    }

    private func makeAuth(_ mock: MockImmichClient) -> AuthViewModel {
        let defaults = UserDefaults(suiteName: "DynamicTypeScreenTests-\(UUID().uuidString)")!
        return AuthViewModel(
            client: mock, keychain: MockKeychainStore(), defaults: defaults,
            widgetSession: NoWidgetSession(), reloadWidgets: {}
        )
    }

    private func partner(_ id: String, _ name: String, inTimeline: Bool = false) -> PartnerResponseDto {
        PartnerResponseDto(
            id: id, name: name, email: "\(id)@example.org",
            profileImagePath: "", avatarColor: "#3366FF",
            profileChangedAt: "2024-01-01T00:00:00.000Z", inTimeline: inTimeline
        )
    }

    /// PROBE (temporary): prints the tree of the hosted Partners screen.
    func test_probe_partnersTree() async {
        let mock = MockImmichClient()
        mock.partnersSharedWithResponse = [
            partner("dt-partner-long", Self.longPartnerName, inTimeline: true),
            partner("dt-partner-short", "Bo"),
        ]
        mock.partnersSharedByResponse = [partner("dt-partner-long", Self.longPartnerName)]
        let screen = HostedScreen(
            NavigationStack { PartnersView(vm: PartnersViewModel(client: mock)) }.environment(makeAuth(mock)),
            size: .accessibility5, language: "de"
        )
        defer { screen.close() }
        _ = await screen.waitFor("partnerRowName-dt-partner-short")
        screen.assertNoOverlap()
        screen.assertFullyShown(long: "partnerRowName-dt-partner-long", short: "partnerRowName-dt-partner-short")
        XCTFail("PROBE \(screen.dump())")
    }
}
