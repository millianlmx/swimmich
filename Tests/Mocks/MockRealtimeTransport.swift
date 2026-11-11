import Foundation
@testable import ImmichSwiftUI

/// `RealtimeTransport` without a socket: records `connect`/`disconnect` and
/// lets a test inject event names with `emit`.
@MainActor
final class MockRealtimeTransport: RealtimeTransport {
    private(set) var connects: [(baseURL: URL, token: String)] = []
    private(set) var disconnectCount = 0
    private(set) var isConnected = false
    /// Event names asked at the last `connect`.
    private(set) var events: [String] = []
    private var onEvent: (@MainActor (String) -> Void)?

    nonisolated init() {}

    func connect(baseURL: URL, token: String, events: [String], onEvent: @escaping @MainActor (String) -> Void) {
        connects.append((baseURL: baseURL, token: token))
        self.events = events
        self.onEvent = onEvent
        isConnected = true
    }

    func disconnect() {
        disconnectCount += 1
        isConnected = false
    }

    /// Delivers `name` as the socket would, only while connected.
    func emit(_ name: String) {
        guard isConnected else { return }
        onEvent?(name)
    }
}
