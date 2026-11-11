import XCTest
@testable import ImmichSwiftUI

final class RealtimeServiceTests: XCTestCase {

    /// Connects a service on its own `NotificationCenter` and returns what the
    /// first notification of `names` carried.
    @MainActor
    private func firstBurst(emitting names: [String]) async -> Notification {
        let center = NotificationCenter()
        let transport = MockRealtimeTransport()
        let service = RealtimeService(transport: transport, debounceInterval: .zero, notificationCenter: center)
        service.connect(baseURL: URL(string: "https://photos.example.com")!, token: "t")
        let captured = TestBox<Notification?>(nil)
        let burst = expectation(forNotification: .immichAssetsChanged, object: nil, notificationCenter: center) { note in
            captured.value = note
            return true
        }
        names.forEach(transport.emit)
        await fulfillment(of: [burst], timeout: 2)
        return captured.value ?? Notification(name: .immichAssetsChanged)
    }

    // AC-14: a mixed burst is ONE notification carrying every event name.
    @MainActor
    func test_realtime_AC14_burstCoalescedIntoOneNotification() async {
        let center = NotificationCenter()
        let transport = MockRealtimeTransport()
        let service = RealtimeService(transport: transport, debounceInterval: .milliseconds(50), notificationCenter: center)
        service.connect(baseURL: URL(string: "https://photos.example.com")!, token: "t")
        let received = TestBox<[Notification]>([])
        let token = center.addObserver(forName: .immichAssetsChanged, object: nil, queue: nil) { received.value.append($0) }
        defer { center.removeObserver(token) }

        transport.emit("on_person_thumbnail")
        transport.emit("on_asset_trash")
        transport.emit("on_asset_trash")
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(received.value.count, 1)
        let batch = received.value.first.map(RealtimeBatch.init(notification:))
        XCTAssertEqual(batch?.events, ["on_person_thumbnail", "on_asset_trash"])
        XCTAssertEqual(batch?.touchesAssets, true)
        XCTAssertEqual(transport.events, RealtimeBatch.listenedEvents, "the service asks the transport for every listened event")
    }

    // AC-15: a lone on_person_thumbnail still broadcasts (people/albums/... reload), without touching assets.
    @MainActor
    func test_realtime_AC15_personThumbnailStillBroadcast() async {
        let note = await firstBurst(emitting: ["on_person_thumbnail"])

        XCTAssertEqual(note.name, .immichAssetsChanged)
        XCTAssertFalse(RealtimeBatch(notification: note).touchesAssets)
    }

    // AC-13/AC-14: which bursts touch the timeline.
    func test_realtime_AC13_batchClassification() {
        XCTAssertFalse(RealtimeBatch(events: ["on_person_thumbnail"]).touchesAssets)
        XCTAssertTrue(RealtimeBatch(events: ["on_person_thumbnail", "on_asset_trash"]).touchesAssets)
        XCTAssertTrue(RealtimeBatch(events: ["on_asset_update"]).touchesAssets)
        XCTAssertFalse(RealtimeBatch(notification: Notification(name: .immichAssetsChanged)).touchesAssets,
                       "a notification without payload is not an asset burst")
    }

    // Events reaching a disconnected service are dropped; a pending burst dies with the connection.
    @MainActor
    func test_realtime_disconnectDropsPendingBurst() async {
        let center = NotificationCenter()
        let transport = MockRealtimeTransport()
        let service = RealtimeService(transport: transport, debounceInterval: .milliseconds(50), notificationCenter: center)
        service.connect(baseURL: URL(string: "https://photos.example.com")!, token: "t")
        let count = TestBox(0)
        let token = center.addObserver(forName: .immichAssetsChanged, object: nil, queue: nil) { _ in count.value += 1 }
        defer { center.removeObserver(token) }

        transport.emit("on_asset_trash")
        service.disconnect()
        transport.emit("on_asset_trash")
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(count.value, 0)
        XCTAssertFalse(transport.isConnected)
    }

    // MARK: - Custom HTTP headers (L-09)

    // AC-118: the handshake carries the server's list, with the usual Bearer.
    @MainActor
    func test_AC_118_handshakeHeadersCarryCustomList() {
        let transport = MockRealtimeTransport()
        let headers = StaticCustomHeaders([StaticCustomHeaders.xAccess], for: "https://photos.example.com")
        let service = RealtimeService(transport: transport, customHeaders: headers)

        service.connect(baseURL: URL(string: "https://photos.example.com")!, token: "t")
        XCTAssertEqual(transport.connects.last?.headers, ["X-Access": "secret", "Authorization": "Bearer t"])

        // Another server's socket never gets this list.
        service.connect(baseURL: URL(string: "https://other.example.org")!, token: "t")
        XCTAssertEqual(transport.connects.last?.headers, ["Authorization": "Bearer t"])
    }

    // Without a list, exactly the handshake of before this feature.
    @MainActor
    func test_AC_124_handshakeUnchangedWithoutHeaders() {
        let transport = MockRealtimeTransport()
        RealtimeService(transport: transport).connect(baseURL: URL(string: "https://photos.example.com")!, token: "t")
        XCTAssertEqual(transport.connects.last?.headers, ["Authorization": "Bearer t"])
    }

    @MainActor
    func test_AC_125_handshakeUsesUserTokenHeader() {
        let transport = MockRealtimeTransport()
        let headers = StaticCustomHeaders([StaticCustomHeaders.basic], for: "https://photos.example.com")
        RealtimeService(transport: transport, customHeaders: headers)
            .connect(baseURL: URL(string: "https://photos.example.com")!, token: "t")
        XCTAssertEqual(
            transport.connects.last?.headers,
            ["Authorization": "Basic dXNlcjpwYXNz", "x-immich-user-token": "t"]
        )
    }
}
