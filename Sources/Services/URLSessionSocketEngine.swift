import Foundation
import SocketIO
import Starscream

/// The wire of `URLSessionSocketEngine`: one WebSocket, injectable so the
/// engine is tested without a network.
protocol RealtimeSocket: AnyObject {
    func resume()
    func send(_ text: String) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}

/// `RealtimeSocket` over `URLSessionWebSocketTask`, on a session of the app
/// (`ServerSessions.realtime`) — so the WebSocket handshake goes through the
/// same trust rule and presents the same client certificate as every other
/// connection to the server.
final class URLSessionRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    static func make(_ session: URLSession, _ request: URLRequest) -> RealtimeSocket {
        URLSessionRealtimeSocket(task: session.webSocketTask(with: request))
    }

    func resume() { task.resume() }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

/// Socket.IO-Client-Swift engine (`SocketEngineSpec`) that speaks Engine.IO v4
/// over `URLSessionWebSocketTask` instead of Starscream's own TCP transport,
/// which can neither present a TLS client certificate nor apply the app's
/// trust rule (L-10). `SocketManager` keeps the Socket.IO protocol on top: it
/// reuses this engine across reconnections, so the URLSession is read again on
/// every `connect()` and never kept.
///
/// WebSocket only (the Immich gateway refuses long-polling) and receive-only in
/// practice: the client sends the namespace connect (`40`), pongs and the close
/// packet. Every piece of state moves on `engineQueue`.
final class URLSessionSocketEngine: NSObject, SocketEngineSpec, @unchecked Sendable {
    // MARK: SocketEngineSpec properties

    weak var client: SocketEngineClient?
    private(set) var closed = false
    let compress = false
    private(set) var connected = false
    var connectParams: [String: Any]?
    let cookies: [HTTPCookie]? = nil
    let engineQueue = DispatchQueue(label: "app.immich.swiftui.realtime-engine")
    var extraHeaders: [String: String]?
    let fastUpgrade = false
    let forcePolling = false
    let forceWebsockets = true
    let polling = false
    let probing = false
    private(set) var sid = ""
    let socketPath = "/api/socket.io/"
    let version = SocketIOVersion.three
    let websocket = true
    /// Starscream's socket type, required by the protocol and unused here.
    let ws: WebSocket? = nil
    let urlPolling: URL
    let urlWebSocket: URL

    // MARK: State

    private let session: @Sendable () -> URLSession
    private let makeSocket: (URLSession, URLRequest) -> RealtimeSocket
    private var socket: RealtimeSocket?
    private var pingInterval: TimeInterval = 25
    private var pingTimeout: TimeInterval = 20
    private var lastCommunication = Date()
    /// Bumped on every connect and close: a ping guard armed for an older
    /// connection sees a different value and stops.
    private var generation = 0

    init(
        client: SocketEngineClient,
        url: URL,
        session: @escaping @Sendable () -> URLSession,
        extraHeaders: [String: String],
        makeSocket: @escaping (URLSession, URLRequest) -> RealtimeSocket = URLSessionRealtimeSocket.make
    ) {
        self.client = client
        self.session = session
        self.extraHeaders = extraHeaders
        self.makeSocket = makeSocket
        let secure = url.scheme == "https" || url.scheme == "wss"
        urlWebSocket = Self.endpoint(url, scheme: secure ? "wss" : "ws", transport: "websocket")
        urlPolling = Self.endpoint(url, scheme: secure ? "https" : "http", transport: "polling")
        super.init()
    }

    /// The initializer `SocketManager` knows: the session and the headers
    /// travel in `options`. A missing session is a programming error.
    convenience init(client: SocketEngineClient, url: URL, options: [String: Any]?) {
        guard let provider = options?["session"] as? (() -> URLSession) else {
            preconditionFailure("URLSessionSocketEngine needs a `session` provider in its options")
        }
        self.init(
            client: client,
            url: url,
            session: { provider() },
            extraHeaders: options?["extraHeaders"] as? [String: String] ?? [:]
        )
    }

    private static func endpoint(_ base: URL, scheme: String, transport: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = scheme
        components.path = "/api/socket.io/"
        components.percentEncodedQuery = "transport=\(transport)&EIO=4"
        return components.url ?? base
    }

    // MARK: Connection

    func connect() {
        engineQueue.async { [self] in
            closed = false
            connected = false
            sid = ""
            generation += 1
            socket?.cancel()

            var request = URLRequest(url: urlWebSocket)
            for (name, value) in extraHeaders ?? [:] {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let fresh = makeSocket(session(), request)
            socket = fresh
            fresh.resume()
            receiveLoop(on: fresh)
        }
    }

    /// Reads the socket until it fails. Every packet goes back to `engineQueue`
    /// in arrival order.
    private func receiveLoop(on socket: RealtimeSocket) {
        Task { [weak self] in
            while true {
                do {
                    let message = try await socket.receive()
                    guard let self else { return }
                    self.engineQueue.async { self.handle(message, from: socket) }
                } catch {
                    guard let self else { return }
                    self.engineQueue.async { self.receiveFailed(error, from: socket) }
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, from source: RealtimeSocket) {
        guard source === socket else { return }
        switch message {
        case .string(let text): parseEngineMessage(text)
        case .data(let data): parseEngineData(data)
        @unknown default: break
        }
    }

    private func receiveFailed(_ error: Error, from source: RealtimeSocket) {
        guard source === socket else { return }
        if closed {
            client?.engineDidClose(reason: "Disconnect")
        } else {
            connected = false
            didError(reason: String(describing: error))
        }
    }

    func disconnect(reason: String) {
        engineQueue.async { [self] in
            let closing = socket
            let wasConnected = connected
            closed = true
            connected = false
            generation += 1
            socket = nil
            if let closing {
                // The close packet goes out best effort; the socket is cancelled
                // right after, without waiting for the peer.
                Task {
                    if wasConnected { try? await closing.send("\(SocketEnginePacketType.close.rawValue)") }
                    closing.cancel()
                }
            }
            client?.engineDidClose(reason: reason)
        }
    }

    func didError(reason: String) {
        engineQueue.async { [self] in
            client?.engineDidError(reason: reason)
            disconnect(reason: reason)
        }
    }

    // MARK: Packets

    func parseEngineMessage(_ message: String) {
        lastCommunication = Date()
        guard let first = message.first,
              let digit = Int(String(first)),
              let type = SocketEnginePacketType(rawValue: digit)
        else {
            client?.engineDidError(reason: "Got unknown packet")
            return
        }
        switch type {
        case .open:
            handleOpen(String(message.dropFirst()))
        case .close:
            disconnect(reason: "Server closed the connection")
        case .ping:
            write("", withType: .pong, withData: [], completion: nil)
            client?.engineDidReceivePing()
        case .pong:
            client?.engineDidReceivePong()
        case .message:
            client?.parseEngineMessage(String(message.dropFirst()))
        case .noop:
            break
        default:
            client?.engineDidError(reason: "Got unknown packet")
        }
    }

    func parseEngineData(_ data: Data) {
        lastCommunication = Date()
        client?.parseEngineBinaryData(data)
    }

    private func handleOpen(_ body: String) {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            sid = object["sid"] as? String ?? ""
            if let interval = (object["pingInterval"] as? NSNumber)?.doubleValue { pingInterval = interval / 1000 }
            if let timeout = (object["pingTimeout"] as? NSNumber)?.doubleValue { pingTimeout = timeout / 1000 }
        }
        connected = true
        armPingGuard(generation: generation)
        client?.engineDidOpen(reason: "Connect")
    }

    /// Sends `type + msg` as one text frame while connected. Binary attachments
    /// are not sent: the client of this engine only receives events.
    func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data], completion: (() -> Void)?) {
        engineQueue.async { [self] in
            guard connected, let socket else {
                completion?()
                return
            }
            let text = "\(type.rawValue)\(msg)"
            Task {
                try? await socket.send(text)
                completion?()
            }
        }
    }

    // MARK: Ping guard

    /// Without any traffic for `pingInterval + pingTimeout` the connection is
    /// considered dead (the server pings every `pingInterval`).
    private func armPingGuard(generation armed: Int) {
        let limit = pingInterval + pingTimeout
        engineQueue.asyncAfter(deadline: .now() + limit) { [weak self] in
            self?.checkPing(generation: armed, limit: limit)
        }
    }

    private func checkPing(generation armed: Int, limit: TimeInterval) {
        guard armed == generation, connected else { return }
        let silence = Date().timeIntervalSince(lastCommunication)
        if silence >= limit {
            didError(reason: "Ping timeout")
        } else {
            engineQueue.asyncAfter(deadline: .now() + (limit - silence)) { [weak self] in
                self?.checkPing(generation: armed, limit: limit)
            }
        }
    }

    // MARK: Unused with a WebSocket-only engine

    /// `SocketManager` never calls this: there is no polling phase to leave.
    func doFastUpgrade() {}

    /// `SocketManager` never calls this: there is no POST queue to flush.
    func flushWaitingForPostToWebSocket() {}
}
