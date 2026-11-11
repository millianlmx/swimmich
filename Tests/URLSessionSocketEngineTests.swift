#if canImport(SocketIO)
import XCTest
import SocketIO
@testable import ImmichSwiftUI

/// A scriptable `RealtimeSocket`: tests push the packets the server would send,
/// and read what the engine wrote.
private final class FakeRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var writes: [String] = []
    private var resumed = false
    private var cancelled = false
    let request: URLRequest
    let session: URLSession

    init(session: URLSession, request: URLRequest) {
        self.session = session
        self.request = request
    }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return writes }
    var wasResumed: Bool { lock.lock(); defer { lock.unlock() }; return resumed }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func resume() { lock.lock(); resumed = true; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func send(_ text: String) async throws {
        lock.lock(); writes.append(text); lock.unlock()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if queued.isEmpty {
                waiter = continuation
                lock.unlock()
            } else {
                let next = queued.removeFirst()
                lock.unlock()
                continuation.resume(with: next)
            }
        }
    }

    func push(_ text: String) { deliver(.success(.string(text))) }
    func fail(_ error: Error) { deliver(.failure(error)) }

    private func deliver(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.resume(with: result)
        } else {
            queued.append(result)
            lock.unlock()
        }
    }
}

/// Records what the engine tells `SocketManager`.
private final class EngineClientSpy: NSObject, SocketEngineClient {
    private let lock = NSLock()
    private var log: [String] = []

    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    func count(_ prefix: String) -> Int { events.filter { $0.hasPrefix(prefix) }.count }
    private func record(_ line: String) { lock.lock(); log.append(line); lock.unlock() }

    func engineDidError(reason: String) { record("error:\(reason)") }
    func engineDidClose(reason: String) { record("close:\(reason)") }
    func engineDidOpen(reason: String) { record("open:\(reason)") }
    func engineDidReceivePong() { record("pong") }
    func engineDidReceivePing() { record("ping") }
    func engineDidSendPong() { record("sentPong") }
    func engineDidSendPing() { record("sentPing") }
    func parseEngineMessage(_ msg: String) { record("message:\(msg)") }
    func parseEngineBinaryData(_ data: Data) { record("binary:\(data.count)") }
    func engineDidWebsocketUpgrade(headers: [String: String]) { record("upgrade") }
}

/// `URLSessionSocketEngine` against a fake socket: Engine.IO v4 packets in, the
/// calls `SocketManager` expects out.
final class URLSessionSocketEngineTests: XCTestCase {
    private let open = #"0{"sid":"abc","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#

    private struct Rig {
        let engine: URLSessionSocketEngine
        let client: EngineClientSpy
        let sockets: SocketList
    }

    private final class SocketList: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [FakeRealtimeSocket] = []
        var all: [FakeRealtimeSocket] { lock.lock(); defer { lock.unlock() }; return list }
        func add(_ socket: FakeRealtimeSocket) { lock.lock(); list.append(socket); lock.unlock() }
    }

    private final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: URLSession
        init(_ session: URLSession) { current = session }
        var session: URLSession {
            get { lock.lock(); defer { lock.unlock() }; return current }
            set { lock.lock(); current = newValue; lock.unlock() }
        }
    }

    private func makeRig(base: String = "https://photos.example.com", sessions: SessionBox) -> Rig {
        let client = EngineClientSpy()
        let list = SocketList()
        let engine = URLSessionSocketEngine(
            client: client,
            url: URL(string: base)!,
            session: { sessions.session },
            extraHeaders: ["Authorization": "Bearer tok", "X-Access": "secret"],
            makeSocket: { session, request in
                let socket = FakeRealtimeSocket(session: session, request: request)
                list.add(socket)
                return socket
            }
        )
        return Rig(engine: engine, client: client, sockets: list)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    func test_AC_21_3_openingTheEngineThenTheNamespace() async throws {
        let sessions = SessionBox(URLSession(configuration: .ephemeral))
        let rig = makeRig(sessions: sessions)

        rig.engine.connect()
        await waitUntil("socket created") { !rig.sockets.all.isEmpty }
        let socket = try XCTUnwrap(rig.sockets.all.first)

        XCTAssertTrue(socket.wasResumed)
        XCTAssertEqual(socket.request.url?.scheme, "wss")
        XCTAssertEqual(socket.request.url?.path(percentEncoded: true), "/api/socket.io/")
        XCTAssertEqual(socket.request.url?.query, "transport=websocket&EIO=4")
        XCTAssertEqual(socket.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(socket.request.value(forHTTPHeaderField: "X-Access"), "secret")

        socket.push(open)
        await waitUntil("engine open") { rig.client.count("open:") == 1 }
        XCTAssertTrue(rig.engine.connected)
        XCTAssertEqual(rig.engine.sid, "abc")

        // What `SocketManager` does on `engineDidOpen`: connect the namespace.
        rig.engine.write("0", withType: .message, withData: [], completion: nil)
        await waitUntil("namespace connect written") { socket.sent == ["40"] }
    }

    func test_AC_21_3_plainHTTPBaseUsesAPlainWebSocket() async throws {
        let sessions = SessionBox(URLSession(configuration: .ephemeral))
        let rig = makeRig(base: "http://nas.local:2283", sessions: sessions)

        rig.engine.connect()
        await waitUntil("socket created") { !rig.sockets.all.isEmpty }

        XCTAssertEqual(rig.sockets.all.first?.request.url?.scheme, "ws")
        XCTAssertEqual(rig.sockets.all.first?.request.url?.port, 2283)
        XCTAssertEqual(rig.engine.urlPolling.scheme, "http")
    }

    func test_AC_21_3_serverEventIsRelayedToTheClient() async throws {
        let sessions = SessionBox(URLSession(configuration: .ephemeral))
        let rig = makeRig(sessions: sessions)
        rig.engine.connect()
        await waitUntil("socket created") { !rig.sockets.all.isEmpty }
        let socket = try XCTUnwrap(rig.sockets.all.first)
        socket.push(open)

        socket.push(#"42["on_asset_trash",["a1"]]"#)

        await waitUntil("event relayed") { rig.client.events.contains(#"message:2["on_asset_trash",["a1"]]"#) }
    }

    func test_AC_21_3_serverPingIsAnsweredWithAPong() async throws {
        let sessions = SessionBox(URLSession(configuration: .ephemeral))
        let rig = makeRig(sessions: sessions)
        rig.engine.connect()
        await waitUntil("socket created") { !rig.sockets.all.isEmpty }
        let socket = try XCTUnwrap(rig.sockets.all.first)
        socket.push(open)
        await waitUntil("engine open") { rig.client.count("open:") == 1 }

        socket.push("2")

        await waitUntil("pong written") { socket.sent.contains("3") }
        await waitUntil("ping reported") { rig.client.count("ping") == 1 }
    }

    func test_AC_21_3_aFailedSocketReportsAnErrorThenClose() async throws {
        let sessions = SessionBox(URLSession(configuration: .ephemeral))
        let rig = makeRig(sessions: sessions)
        rig.engine.connect()
        await waitUntil("socket created") { !rig.sockets.all.isEmpty }
        let socket = try XCTUnwrap(rig.sockets.all.first)
        socket.push(open)
        await waitUntil("engine open") { rig.client.count("open:") == 1 }

        socket.fail(URLError(.networkConnectionLost))

        await waitUntil("error and close") { rig.client.count("error:") == 1 && rig.client.count("close:") == 1 }
        XCTAssertFalse(rig.engine.connected)
        XCTAssertTrue(rig.engine.closed)
        await waitUntil("socket cancelled") { socket.wasCancelled }
    }

    func test_AC_21_3_disconnectSendsTheClosePacketAndReportsOnce() async throws {
        let sessions = SessionBox(URLSession(configuration: .ephemeral))
        let rig = makeRig(sessions: sessions)
        rig.engine.connect()
        await waitUntil("socket created") { !rig.sockets.all.isEmpty }
        let socket = try XCTUnwrap(rig.sockets.all.first)
        socket.push(open)
        await waitUntil("engine open") { rig.client.count("open:") == 1 }

        rig.engine.disconnect(reason: "manual")

        await waitUntil("close packet written") { socket.sent.contains("1") }
        await waitUntil("socket cancelled") { socket.wasCancelled }
        await waitUntil("client told") { rig.client.events.contains("close:manual") }
        // The failed receive that follows the cancellation must not report again.
        socket.fail(URLError(.cancelled))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.client.count("close:"), 1)
        XCTAssertEqual(rig.client.count("error:"), 0)
    }

    func test_AC_22_6_reconnectionOpensANewSocketOnTheCurrentSession() async throws {
        let first = URLSession(configuration: .ephemeral)
        let second = URLSession(configuration: .ephemeral)
        let sessions = SessionBox(first)
        let rig = makeRig(sessions: sessions)

        rig.engine.connect()
        await waitUntil("first socket") { rig.sockets.all.count == 1 }
        rig.sockets.all[0].push(open)
        await waitUntil("engine open") { rig.client.count("open:") == 1 }

        // A certificate change replaced the session; `SocketManager` reconnects
        // by calling `connect()` on the same engine.
        sessions.session = second
        rig.engine.connect()
        await waitUntil("second socket") { rig.sockets.all.count == 2 }

        XCTAssertTrue(rig.sockets.all[0].session === first)
        XCTAssertTrue(rig.sockets.all[1].session === second, "the session is read again at every connect")
        XCTAssertTrue(rig.sockets.all[0].wasCancelled, "the previous socket is dropped")
        XCTAssertFalse(rig.engine.connected, "the new connection is not open until the server says so")
    }

    func test_AC_21_3_unknownPacketIsAnError() async throws {
        let sessions = SessionBox(URLSession(configuration: .ephemeral))
        let rig = makeRig(sessions: sessions)
        rig.engine.connect()
        await waitUntil("socket created") { !rig.sockets.all.isEmpty }

        rig.sockets.all[0].push("x-not-a-packet")

        await waitUntil("error reported") { rig.client.events.contains("error:Got unknown packet") }
    }
}

#endif
