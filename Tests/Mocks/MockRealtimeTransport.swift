import Foundation
@testable import ImmichSwiftUI

/// `RealtimeTransport` without a socket: records `connect`/`disconnect` and
/// lets a test inject event names with `emit`.
@MainActor
final class MockRealtimeTransport: RealtimeTransport {
    /// `token` is read back from the handshake headers the way the server reads
    /// them: `x-immich-user-token`, else the `Bearer` of `Authorization`.
    private(set) var connects: [(baseURL: URL, headers: [String: String], token: String?)] = []
    private(set) var disconnectCount = 0
    private(set) var isConnected = false
    /// Event names asked at the last `connect`.
    private(set) var events: [String] = []
    private var onEvent: (@MainActor (String) -> Void)?

    nonisolated init() {}

    func connect(baseURL: URL, headers: [String: String], events: [String], onEvent: @escaping @MainActor (String) -> Void) {
        let bearer = headers["Authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        connects.append((baseURL: baseURL, headers: headers, token: headers["x-immich-user-token"] ?? bearer))
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
