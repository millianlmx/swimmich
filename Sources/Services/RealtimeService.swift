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
    /// The server regenerated the thumbnails of an edited photo (`PUT`/`DELETE /assets/{id}/edits`
    /// queue a job; v3.4.0 emits `AssetEditReadyV2`, earlier v2.5+ servers `AssetEditReadyV1`). Until
    /// then `edited=true` serves the old image under the old thumbhash.
    static let editReadyEvents: Set<String> = ["AssetEditReadyV1", "AssetEditReadyV2"]
    /// Events that change what the timeline shows.
    static let assetEvents: Set<String> = Set([
        "on_upload_success", "on_asset_delete", "on_asset_trash",
        "on_asset_update", "on_asset_hidden", "on_asset_restore",
        "on_asset_stack_update",
    ]).union(editReadyEvents)
    static let listenedEvents: [String] = assetEvents.union([personThumbnailEvent]).sorted()
    static let eventsKey = "events"

    /// False for a burst made only of `on_person_thumbnail`: the timeline has
    /// nothing to re-read, the other screens still reload.
    var touchesAssets: Bool { !events.isDisjoint(with: Self.assetEvents) }

    /// The burst carries a thumbnail regeneration: the open viewer re-reads its photo.
    var touchesEditedAssets: Bool { !events.isDisjoint(with: Self.editReadyEvents) }

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
///
/// The WebSocket rides on `URLSessionSocketEngine`, on the session `session()`
/// returns — in production `ServerSessions.realtime`, which applies the app's
/// server-trust rule and presents the server's client certificate (L-10). The
/// default `.shared` (system trust only, no certificate) is for tests.
@MainActor
final class SocketIORealtimeTransport: RealtimeTransport {
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private let session: @Sendable () -> URLSession

    nonisolated init(session: @escaping @Sendable () -> URLSession = { .shared }) {
        self.session = session
    }

    func connect(baseURL: URL, headers: [String: String], events: [String], onEvent: @escaping @MainActor (String) -> Void) {
        disconnect()
        let manager = SocketManager(
            socketURL: baseURL,
            config: [
                .path("/api/socket.io"),
                .forceWebsockets(true),
                .reconnects(true),
            ]
        )
        // Set BEFORE `connect()`: `SocketManager` only builds its own engine
        // when it has none, and reuses this one on every reconnection.
        manager.engine = URLSessionSocketEngine(client: manager, url: baseURL, session: session, extraHeaders: headers)
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

    /// What `connect` was last given, kept until `disconnect`, so a certificate
    /// change can reconnect the socket (`reconnectIfConnected`).
    private var lastConnection: (baseURL: URL, token: String)?

    func connect(baseURL: URL, token: String) {
        disconnect()
        lastConnection = (baseURL, token)
        let headers = ServerRequestAuthorization.dictionary(
            token: token, custom: customHeaders.headers(for: baseURL)
        )
        transport.connect(baseURL: baseURL, headers: headers, events: RealtimeBatch.listenedEvents) { [weak self] name in
            self?.receive(event: name)
        }
    }

    /// New socket on the current session (and so the current client
    /// certificate), if the service is connected; nothing otherwise.
    func reconnectIfConnected() {
        guard let last = lastConnection else { return }
        connect(baseURL: last.baseURL, token: last.token)
    }

    func disconnect() {
        debounceTask?.cancel()
        debounceTask = nil
        lastConnection = nil
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
