import Foundation
import SocketIO

extension Notification.Name {
    /// Broadcast whenever server events indicate library content changed
    /// (asset create/update/delete/trash/restore/stack, person thumbnail).
    /// VMs observe this to refresh their lists without a manual pull. The
    /// `userInfo` carries the burst's event names (`RealtimeBatch`).
    static let immichAssetsChanged = Notification.Name("immichAssetsChanged")
}

/// The event names of one debounced burst, as carried by `.immichAssetsChanged`.
/// Only the **names** matter (their content is not read).
struct RealtimeBatch: Equatable, Sendable {
    let events: Set<String>

    static let personThumbnailEvent = "on_person_thumbnail"
    /// Events that change what the timeline shows.
    static let assetEvents: Set<String> = [
        "on_upload_success", "on_asset_delete", "on_asset_trash",
        "on_asset_update", "on_asset_hidden", "on_asset_restore",
        "on_asset_stack_update",
    ]
    static let listenedEvents: [String] = assetEvents.union([personThumbnailEvent]).sorted()
    static let eventsKey = "events"

    /// False for a burst made only of `on_person_thumbnail`: the timeline has
    /// nothing to re-read, the other screens still reload.
    var touchesAssets: Bool { !events.isDisjoint(with: Self.assetEvents) }

    init(events: Set<String>) {
        self.events = events
    }

    init(notification: Notification) {
        self.events = notification.userInfo?[Self.eventsKey] as? Set<String> ?? []
    }
}

/// The wire under `RealtimeService`, injectable so tests never open a socket.
@MainActor
protocol RealtimeTransport: AnyObject {
    func connect(baseURL: URL, headers: [String: String], events: [String], onEvent: @escaping @MainActor (String) -> Void)
    func disconnect()
}

/// Socket.IO transport: connects to the Immich server's `/api/socket.io`
/// gateway, authenticating through the websocket handshake headers (the session
/// token and the server's custom headers, see `ServerRequestAuthorization`).
@MainActor
final class SocketIORealtimeTransport: RealtimeTransport {
    private var manager: SocketManager?
    private var socket: SocketIOClient?

    nonisolated init() {}

    func connect(baseURL: URL, headers: [String: String], events: [String], onEvent: @escaping @MainActor (String) -> Void) {
        disconnect()
        let manager = SocketManager(
            socketURL: baseURL,
            config: [
                .path("/api/socket.io"),
                .forceWebsockets(true),
                .extraHeaders(headers),
                .reconnects(true),
                .compress,
            ]
        )
        let socket = manager.defaultSocket

        socket.on(clientEvent: .connect) { _, _ in
            // Connected; nothing to surface to the user.
        }
        socket.on(clientEvent: .error) { _, _ in
            // Errors are non-fatal — the HTTP layer still works without the socket.
        }

        // Handlers run on the manager's `handleQueue` (main by default).
        for name in events {
            socket.on(name) { _, _ in
                onEvent(name)
            }
        }

        socket.connect()
        self.manager = manager
        self.socket = socket
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        manager = nil
    }
}

/// Realtime service (gap #10): coalesces server events into a debounced
/// `.immichAssetsChanged` notification listing every event of the burst.
@MainActor
final class RealtimeService {
    private let transport: any RealtimeTransport
    private let notificationCenter: NotificationCenter
    private let customHeaders: any CustomHeadersProviding
    private var debounceTask: Task<Void, Never>?
    private var pendingEvents: Set<String> = []

    /// Debounce window for coalescing bursts of events (e.g. a bulk trash).
    private let debounceInterval: Duration

    nonisolated init(
        transport: any RealtimeTransport = SocketIORealtimeTransport(),
        debounceInterval: Duration = .milliseconds(600),
        notificationCenter: NotificationCenter = .default,
        customHeaders: any CustomHeadersProviding = NoCustomHeaders()
    ) {
        self.transport = transport
        self.debounceInterval = debounceInterval
        self.notificationCenter = notificationCenter
        self.customHeaders = customHeaders
    }

    func connect(baseURL: URL, token: String) {
        disconnect()
        let headers = ServerRequestAuthorization.dictionary(
            token: token, custom: customHeaders.headers(for: baseURL)
        )
        transport.connect(baseURL: baseURL, headers: headers, events: RealtimeBatch.listenedEvents) { [weak self] name in
            self?.receive(event: name)
        }
    }

    func disconnect() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingEvents.removeAll()
        transport.disconnect()
    }

    func receive(event: String) {
        pendingEvents.insert(event)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounceInterval ?? .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            let batch = self.pendingEvents
            self.pendingEvents.removeAll()
            self.notificationCenter.post(
                name: .immichAssetsChanged, object: nil,
                userInfo: [RealtimeBatch.eventsKey: batch]
            )
        }
    }
}
