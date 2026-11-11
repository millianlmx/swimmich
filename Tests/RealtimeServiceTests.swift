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
        var captured: Notification?
        let burst = expectation(forNotification: .immichAssetsChanged, object: nil, notificationCenter: center) { note in
            captured = note
            return true
        }
        names.forEach(transport.emit)
        await fulfillment(of: [burst], timeout: 2)
        return captured ?? Notification(name: .immichAssetsChanged)
    }

    // AC-14: a mixed burst is ONE notification carrying every event name.
    @MainActor
    func test_realtime_AC14_burstCoalescedIntoOneNotification() async {
        let center = NotificationCenter()
        let transport = MockRealtimeTransport()
        let service = RealtimeService(transport: transport, debounceInterval: .milliseconds(50), notificationCenter: center)
        service.connect(baseURL: URL(string: "https://photos.example.com")!, token: "t")
        var received: [Notification] = []
        let token = center.addObserver(forName: .immichAssetsChanged, object: nil, queue: nil) { received.append($0) }
        defer { center.removeObserver(token) }

        transport.emit("on_person_thumbnail")
        transport.emit("on_asset_trash")
        transport.emit("on_asset_trash")
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(received.count, 1)
        let batch = received.first.map(RealtimeBatch.init(notification:))
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
        var count = 0
        let token = center.addObserver(forName: .immichAssetsChanged, object: nil, queue: nil) { _ in count += 1 }
        defer { center.removeObserver(token) }

        transport.emit("on_asset_trash")
        service.disconnect()
        transport.emit("on_asset_trash")
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(count, 0)
        XCTAssertFalse(transport.isConnected)
    }
}
