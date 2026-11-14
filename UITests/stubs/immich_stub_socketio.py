"""Engine.IO v4 over a plain WebSocket, for the stubs that must push a server event (`AssetEditReadyV2`).

    from immich_stub_socketio import close_all, emit, is_upgrade, serve

    class Handler(StubHandler):
        def do_GET(self):
            if is_upgrade(self):
                return serve(self)
            super().do_GET()

The app opens `ws://<host>/api/socket.io/?transport=websocket&EIO=4` (`URLSessionSocketEngine`). The
sequence is Engine.IO v4: the server opens with `0{"sid":…}`, the client answers `40`, the server
confirms `40{"sid":"stub-nsp"}`, and then pings with a text `2` every 20 s. `emit(event, payload)` sends
`42["<event>",<payload>]` to every open connection.

`serve` is meant to be called from the handler's own thread (it blocks until the connection ends). It
adds one entry to the journal (`/__requests`): `{"method": "GET", "path": "/api/socket.io/", "params":
…, "body": {}, "status": 101, "auth": <the request carried a Bearer token>}`. A scenario that needs the
event waits for that entry first.

The frame code is the one of `immich_stub_client_cert.py` (TLS): that stub registers its routes on import
and cannot be reused.
"""
import base64
import hashlib
import json
import queue
import select
import socket
import struct
import threading
import time

from immich_stub_base import STATE, Request

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OPEN_PACKET = '0{"sid":"stub-sid","upgrades":[],"pingInterval":25000,"pingTimeout":60000,"maxPayload":1000000}'
PING_SECONDS = 20

CONNECTIONS = []
LOCK = threading.Lock()


class Connection:
    """One open connection. Its handler thread does every read and write on the socket; other threads
    only `post()` a text (or `None` to close) and wake it."""

    def __init__(self):
        self.outbox = queue.Queue()
        self.wake_r, self.wake_w = socket.socketpair()
        self.wake_r.setblocking(False)

    def post(self, text):
        self.outbox.put(text)
        try:
            self.wake_w.send(b"x")
        except OSError:
            pass

    def drain(self):
        try:
            self.wake_r.recv(4096)
        except (BlockingIOError, OSError):
            pass

    def dispose(self):
        self.wake_r.close()
        self.wake_w.close()


def encode_frame(opcode, payload=b""):
    """A server frame: FIN set, never masked."""
    size = len(payload)
    if size < 126:
        header = bytes([0x80 | opcode, size])
    elif size < 65536:
        header = bytes([0x80 | opcode, 126]) + struct.pack(">H", size)
    else:
        header = bytes([0x80 | opcode, 127]) + struct.pack(">Q", size)
    return header + payload


def read_exact(sock, count):
    chunks = []
    while count:
        chunk = sock.recv(count)
        if not chunk:
            raise EOFError("the client closed the connection")
        chunks.append(chunk)
        count -= len(chunk)
    return b"".join(chunks)


def read_frame(sock):
    """`(opcode, payload)` of one client frame (masked, as RFC 6455 requires)."""
    first, second = read_exact(sock, 2)
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        length = struct.unpack(">H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exact(sock, 8))[0]
    mask = read_exact(sock, 4) if second & 0x80 else b""
    payload = read_exact(sock, length)
    if mask:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return opcode, payload


def is_upgrade(handler):
    """A WebSocket upgrade of `/api/socket.io` (a trailing slash is allowed)."""
    path = handler.path.partition("?")[0].rstrip("/")
    return path == "/api/socket.io" and (handler.headers.get("Upgrade") or "").lower() == "websocket"


def emit(event, payload):
    """Send `42["<event>",<payload>]` to every open connection; how many there are."""
    packet = "42" + json.dumps([event, payload])
    with LOCK:
        for connection in CONNECTIONS:
            connection.post(packet)
        return len(CONNECTIONS)


def close_all():
    """Close every open connection (a close frame)."""
    with LOCK:
        for connection in CONNECTIONS:
            connection.post(None)


def serve(handler):
    """Answer the upgrade and serve the connection until it ends."""
    path, _, query = handler.path.partition("?")
    request = Request("GET", path, query, handler.headers, {})
    authorization = handler.headers.get("Authorization") or ""
    STATE["requests"].append({
        "method": "GET", "path": path, "params": request.params, "body": {},
        "status": 101, "auth": authorization.startswith("Bearer "),
    })
    key = handler.headers.get("Sec-WebSocket-Key")
    handler.close_connection = True
    if not key:
        handler.send_error(400, "missing Sec-WebSocket-Key")
        return
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    sock = handler.connection
    connection = Connection()
    try:
        sock.sendall(("HTTP/1.1 101 Switching Protocols\r\n"
                      "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        sock.sendall(encode_frame(0x1, OPEN_PACKET.encode()))
        with LOCK:
            CONNECTIONS.append(connection)
        _pump(sock, connection)
    except (OSError, EOFError, ValueError):
        pass  # the client left, or `close_all` cut the connection
    finally:
        with LOCK:
            if connection in CONNECTIONS:
                CONNECTIONS.remove(connection)
        connection.dispose()
        handler.close_connection = True


def _pump(sock, connection):
    """Serve one WebSocket until a close frame, `close_all` or the client leaves."""
    next_ping = time.monotonic() + PING_SECONDS
    while True:
        wait = max(0.0, next_ping - time.monotonic())
        ready, _, _ = select.select([sock, connection.wake_r], [], [], wait)

        if connection.wake_r in ready:
            connection.drain()
        while True:
            try:
                text = connection.outbox.get_nowait()
            except queue.Empty:
                break
            if text is None:
                sock.sendall(encode_frame(0x8))
                return
            sock.sendall(encode_frame(0x1, text.encode()))

        if sock in ready:
            opcode, payload = read_frame(sock)
            if opcode == 0x8:  # close: answer it and stop
                sock.sendall(encode_frame(0x8, payload[:2]))
                return
            if opcode == 0x9:  # protocol-level ping
                sock.sendall(encode_frame(0xA, payload))
            elif opcode in (0x1, 0x2):
                text = payload.decode("utf-8", "replace")
                if text.startswith("40"):  # Socket.IO: connect to the namespace
                    sock.sendall(encode_frame(0x1, b'40{"sid":"stub-nsp"}'))
                # "3" (pong) and every other packet: ignored

        if time.monotonic() >= next_ping:
            sock.sendall(encode_frame(0x1, b"2"))
            next_ping = time.monotonic() + PING_SECONDS
