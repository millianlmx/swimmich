import XCTest
@testable import ImmichSwiftUI

/// The realtime socket follows a certificate change, and the cast sheet says
/// what AirPlay cannot do behind a client certificate.
@MainActor
final class ClientCertificateRealtimeAndCastTests: XCTestCase {
    private let server = URL(string: "https://photos.example.com")!

    // MARK: Realtime

    func test_AC_22_6_reconnectIfConnected() {
        let transport = MockRealtimeTransport()
        let service = RealtimeService(transport: transport, notificationCenter: NotificationCenter())

        service.reconnectIfConnected()
        XCTAssertEqual(transport.connects.count, 0, "a service that never connected has nothing to reconnect")

        service.connect(baseURL: server, token: "tok")
        XCTAssertEqual(transport.connects.count, 1)

        service.reconnectIfConnected()
        XCTAssertEqual(transport.connects.count, 2, "a new socket, so a new handshake")
        XCTAssertEqual(transport.connects.last?.baseURL, server)
        XCTAssertEqual(transport.connects.last?.token, "tok")
        XCTAssertTrue(transport.isConnected)
    }

    func test_AC_22_6_reconnectIsForgottenAfterDisconnect() {
        let transport = MockRealtimeTransport()
        let service = RealtimeService(transport: transport, notificationCenter: NotificationCenter())
        service.connect(baseURL: server, token: "tok")
        service.disconnect()

        service.reconnectIfConnected()

        XCTAssertEqual(transport.connects.count, 1, "a signed-out user's socket must not come back")
        XCTAssertFalse(transport.isConnected)
    }

    // MARK: Cast

    private func makeAsset(isVideo: Bool) -> AssetReactItem {
        AssetReactItem(
            id: "asset-1", ownerId: "owner", ratio: 0.75, isFavorite: false,
            visibility: "timeline", isTrashed: false, isImage: !isVideo, thumbhash: nil,
            createdAt: "2024-07-01T10:00:00.000Z", fileCreatedAt: "2024-07-01T10:00:00.000Z",
            localOffsetHours: 0, duration: isVideo ? 12 : nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    func test_AC_21_5_hintOnlyForVideoWithCertificate() {
        let vm = CastViewModel(service: MockCastService())

        XCTAssertTrue(vm.showsClientCertificateHint(for: makeAsset(isVideo: true), clientCertificateActive: true))
        XCTAssertFalse(vm.showsClientCertificateHint(for: makeAsset(isVideo: true), clientCertificateActive: false),
                       "without a certificate the sheet is unchanged")
        XCTAssertFalse(vm.showsClientCertificateHint(for: makeAsset(isVideo: false), clientCertificateActive: true),
                       "a still photo has its own hint")
    }
}
