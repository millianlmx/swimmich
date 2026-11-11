"""Immich API stub that REQUIRES a TLS client certificate (`ClientCertificateUITests`, L-10).

What it is for
--------------
The server a user keeps behind mutual TLS: the whole Immich API on HTTPS, with
`verify_mode = CERT_REQUIRED`. A client that presents no certificate chaining to
the stub's CA never gets past the handshake, so an entry in `/__requests` can
only exist if the app presented a good identity, and `/__handshakes` says which.

    python3 -u UITests/stubs/immich_stub_client_cert.py 8421 &
    curl http://127.0.0.1:8422/__whoami     # {"port": 8421, "stub": "immich_stub_client_cert.py", …}
    TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test \\
        -scheme ImmichSwiftUI -destination 'platform=iOS Simulator,name=<iPhone>' \\
        -only-testing:ImmichSwiftUIUITests/ClientCertificateUITests

Three ports (P = the port given on the command line, default 8421)
------------------------------------------------------------------
  P      HTTPS, client certificate required. The API: `immich_stub_base` shell +
         `immich_stub_selfsigned` routes (Road Trip, OAuth) + this file's.
  P + 1  Plain HTTP. Control routes only (what the XCUITest runner uses: its
         `URLSession.shared` can neither trust the server certificate nor present
         one) and the OAuth provider pages. Never logged.
  P + 2  HTTPS, same API, same TLS context: "the same host, another port"
         (AC-22.4 — a certificate attached to P must never be shown to P + 2).

The server certificate is `immich_stub_selfsigned.make_certificate()` (self-signed,
SAN IP:127.0.0.1): the scenarios launch the app with `-trustedServers ("127.0.0.1")`.

Certificates (generated at every start, `openssl` on the PATH, exit 2 without it)
--------------------------------------------------------------------------------
  CA                     "Swimmich Test CA"
  client A (CN client-a) password `alpha`, `extendedKeyUsage=clientAuth`
  client B (CN client-b) password `bravo`, same CA
  fixtures served        a.p12, b.p12, nokey.p12 (A's certificate without its key,
                         password `alpha`) and notp12 (PNG bytes). PKCS#12 written
                         with the legacy algorithms (3DES, SHA-1 MAC) the system
                         reads.

Control routes (on P + 1, also answered on P and P + 2)
-------------------------------------------------------
  GET /__handshakes
      One entry per ACCEPTED connection, in the order the handshakes ended:
      `{"port", "ok", "resumed", "cert", "error", "path"}`.
        ok       the TLS handshake succeeded (a client without certificate: false)
        resumed  `session_reused` (None when the handshake failed): a `false`
                 is a FULL handshake, which is what a certificate change must cause
        cert     "A" or "B" (SHA-256 of the peer's DER), "unknown", None if none
        path     the first path served on the connection (None if no request came)
  GET /__client-cert/select?name=a|b|nokey|notp12   → {"selected": name}
  GET /__client-cert/current   the bytes of the selected file (default `a`); the
                               app downloads them under `-uiTestClientCertificateFeed`
  GET /__client-cert/info      {"a": {"password": "alpha"}, "b": …, "nokey": …}
  GET /__emit?event=<name>     adds a 7th asset to the timeline and sends the
                               Socket.IO event `42["<name>","<id>"]` to every open
                               WebSocket → {"sockets": n}
  GET /__reset                 also empties the journal, selects `a`, closes the
                               WebSockets and removes the 7th asset

Socket.IO (engine.io v4, WebSocket only) on P
---------------------------------------------
`GET /api/socket.io/?EIO=4&transport=websocket` with `Upgrade: websocket`: logged
in `/__requests` with `auth` (an `Authorization: Bearer …` was sent), answered 101;
then `0{"sid":…}` is sent, `40` is answered `40{"sid":"stub-nsp"}`, `3` is ignored,
`2` is sent every 20 s, and a close frame ends the connection. Client frames are
masked, the server's are not. One thread per connection does ALL the I/O on its
socket (an SSL object is not safe for a concurrent read and write): `/__emit` hands
its text over through a queue and wakes that thread.

Timeline
--------
The shell's day, six photos, the SIXTH of which is a video (`VIDEO_ID`, the
fixture of `immich_stub_video_player.py`, `Range` → 206 on
`/api/assets/<id>/video/playback`). `/__emit` adds a seventh photo (`EMIT_ID`).
`POST /api/assets` is the share extension's upload route
(`immich_stub_share_extension.py`).

Extending it
------------
Like `immich_stub_selfsigned.py`: an asset added to `GET /api/assets/…` is a branch
in `asset_route` below, NEVER a second `@router.prefix("GET", "/api/assets/")`
(`Router.handle` only consults the first prefix that matches). This module
REPLACES the selfsigned prefix by `asset_route`, which calls it for the rest.
"""
import hashlib
import json
import os
import queue
import re
import select
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
from base64 import b64encode
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qsl

import immich_stub_base as base
import immich_stub_selfsigned as selfsigned
from immich_stub_base import STATE, Response, router

# MARK: - Fixtures

CLIENTS = {"a": ("client-a", "alpha"), "b": ("client-b", "bravo")}

# The six photos of the shell's day; the sixth is the video. A photo the viewer
# opens must NOT be the first: that one is `selfsigned.TARGET`, whose original
# is streamed for ~16 s.
VIDEO_ID = base.TIMELINE_ASSETS[5]
EMIT_ID = "aaaaaaaa-1111-4111-8111-000000000007"

VIDEO_MS = 12_000
VIDEO_SIZE = (480, 270)
VIDEO_FIXTURE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "fixtures", "media", "green-16x9-12s.mp4")
RANGE = re.compile(r"bytes=(\d*)-(\d*)")

# Read once, at import: a stub whose fixture is missing must die at startup.
try:
    with open(VIDEO_FIXTURE, "rb") as handle:
        VIDEO_BYTES = handle.read()
except OSError as error:  # a broken checkout, not a scenario
    raise SystemExit(f"client-cert stub: cannot read {VIDEO_FIXTURE}: {error}")

UPLOAD_ID = "dddddddd-1111-4111-8111-000000000001"

# Filled by `make_fixtures()`: the p12 bytes by name, and "A"/"B" by DER SHA-256.
FIXTURES = {}
FINGERPRINTS = {}
PASSWORDS = {"a": "alpha", "b": "bravo", "nokey": "alpha"}

SELECTED = {"name": "a"}
EMITTED = {"seventh": False}

HANDSHAKES = []
HANDSHAKES_LOCK = threading.Lock()

SOCKETS = []
SOCKETS_LOCK = threading.Lock()

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
PING_SECONDS = 20
OPEN_PACKET = ('0{"sid":"stub-sid","upgrades":[],"pingInterval":25000,'
               '"pingTimeout":60000,"maxPayload":1000000}')

# MARK: - Certificates

CA_CONFIG = """\
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Swimmich Test CA
[v3]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
"""

CLIENT_CONFIG = """\
[req]
distinguished_name = dn
prompt = no
[dn]
CN = {cn}
"""

CLIENT_EXTENSIONS = """\
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
"""

# The algorithms `SecPKCS12Import` reads (the OpenSSL 3 defaults are not
# guaranteed to be read, see the registry): 3DES and a SHA-1 MAC.
LEGACY_P12 = ["-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"]


def openssl(*args):
    """Run `openssl`, or exit 2 with what it said."""
    try:
        subprocess.run(["openssl", *args], check=True, capture_output=True)
    except FileNotFoundError:
        sys.stderr.write("immich_stub_client_cert: the `openssl` binary is not on the PATH\n")
        sys.exit(2)
    except subprocess.CalledProcessError as error:
        sys.stderr.write("immich_stub_client_cert: openssl " + " ".join(args) + " failed:\n"
                         + error.stderr.decode("utf-8", "replace") + "\n")
        sys.exit(2)


def write(path, text):
    with open(path, "w") as handle:
        handle.write(text)


def make_fixtures():
    """The CA, the clients A and B and the four files served; returns the CA's path."""
    folder = tempfile.mkdtemp(prefix="immich-stub-client-cert-")

    def at(name):
        return os.path.join(folder, name)

    write(at("ca.cnf"), CA_CONFIG)
    openssl("req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "30", "-nodes",
            "-keyout", at("ca.key"), "-out", at("ca.pem"), "-config", at("ca.cnf"))
    write(at("client.ext"), CLIENT_EXTENSIONS)

    for name, (cn, password) in CLIENTS.items():
        write(at(f"{name}.cnf"), CLIENT_CONFIG.format(cn=cn))
        openssl("req", "-new", "-newkey", "rsa:2048", "-sha256", "-nodes",
                "-keyout", at(f"{name}.key"), "-out", at(f"{name}.csr"), "-config", at(f"{name}.cnf"))
        openssl("x509", "-req", "-in", at(f"{name}.csr"), "-CA", at("ca.pem"), "-CAkey", at("ca.key"),
                "-CAcreateserial", "-days", "30", "-sha256", "-extfile", at("client.ext"),
                "-out", at(f"{name}.pem"))
        openssl("pkcs12", "-export", "-inkey", at(f"{name}.key"), "-in", at(f"{name}.pem"),
                *LEGACY_P12, "-passout", f"pass:{password}", "-out", at(f"{name}.p12"))
        with open(at(f"{name}.pem")) as handle:
            der = ssl.PEM_cert_to_DER_cert(handle.read())
        FINGERPRINTS[hashlib.sha256(der).hexdigest()] = name.upper()

    # A's certificate WITHOUT its key: a PKCS#12 the importer must refuse.
    openssl("pkcs12", "-export", "-nokeys", "-in", at("a.pem"),
            *LEGACY_P12, "-passout", "pass:alpha", "-out", at("nokey.p12"))

    for name in ("a", "b", "nokey"):
        with open(at(f"{name}.p12"), "rb") as handle:
            FIXTURES[name] = handle.read()
    FIXTURES["notp12"] = base.png("not-a-pkcs12")
    return at("ca.pem")


def peer_label(tls):
    """"A", "B", "unknown", or None when the peer showed no certificate."""
    der = tls.getpeercert(binary_form=True)
    if der is None:
        return None
    return FINGERPRINTS.get(hashlib.sha256(der).hexdigest(), "unknown")


# MARK: - Timeline

def timeline_ids():
    return list(base.TIMELINE_ASSETS) + ([EMIT_ID] if EMITTED["seventh"] else [])


def video_dto():
    """The video as a full `AssetResponseDto` (shape of `immich_stub_video_player.video_dto`)."""
    dto = base.asset(VIDEO_ID)
    width, height = VIDEO_SIZE
    dto.update({
        "type": "VIDEO",
        "duration": VIDEO_MS,
        "width": width,
        "height": height,
        "originalPath": f"/x/{VIDEO_ID}.mp4",
        "originalFileName": f"{VIDEO_ID[:4]}-{VIDEO_ID[-2:]}.mp4",
        "originalMimeType": "video/mp4",
    })
    return dto


@router.get("/api/timeline/buckets")
def buckets(req):
    return Response([{"timeBucket": base.TIMELINE_DAY, "count": len(timeline_ids())}])


@router.get("/api/timeline/bucket")
def one_day(req):
    """The shell's day, its sixth tile a video, plus the seventh once `/__emit` ran.
    Same ids in every parallel array (the app zips them by index)."""
    if req.params.get("timeBucket") != base.TIMELINE_DAY:
        return None
    ids = timeline_ids()
    payload = base.bucket_payload(ids)
    index = ids.index(VIDEO_ID)
    payload["isImage"][index] = False
    payload["duration"][index] = VIDEO_MS
    payload["ratio"][index] = VIDEO_SIZE[0] / VIDEO_SIZE[1]
    return Response(payload)


def asset_route(req):
    """The ONE `GET /api/assets/` prefix: the video, then the selfsigned stub's own."""
    parts = req.rest.split("/")

    if parts == [VIDEO_ID]:
        return Response(video_dto())

    if parts == [VIDEO_ID, "video", "playback"]:
        return playback(req)

    return selfsigned.one_asset(req)


def playback(req):
    """The fixture, `206` + `Content-Range` when a `Range` came (AVFoundation reads
    a progressive MP4 with `Range: bytes=0-1` first). `range` lands in `/__requests`."""
    total = len(VIDEO_BYTES)
    header = (req.headers.get("Range") or "").strip()
    req.note(range=header or None, bytes=total)
    match = RANGE.fullmatch(header) if header else None
    headers = {"Accept-Ranges": "bytes", "Cache-Control": "no-store"}
    if match is None:
        return Response(VIDEO_BYTES, ctype="video/mp4", headers=headers)

    start = int(match.group(1)) if match.group(1) else 0
    end = int(match.group(2)) if match.group(2) else total - 1
    end = min(end, total - 1)
    if start > end or start >= total:
        return Response(b"", status=416, ctype="video/mp4",
                        headers={**headers, "Content-Range": f"bytes */{total}"})
    return Response(VIDEO_BYTES[start:end + 1], status=206, ctype="video/mp4",
                    headers={**headers, "Content-Range": f"bytes {start}-{end}/{total}"})


# `Router.handle` consults only the first matching prefix: take the selfsigned
# stub's out and put the combined one in its place.
router._prefixed[:] = [entry for entry in router._prefixed
                       if not (entry[0] == "GET" and entry[1] == "/api/assets/")]
router.prefix("GET", "/api/assets/")(asset_route)


# MARK: - Upload (copied from immich_stub_share_extension.py)

def _part_names(raw):
    """The `name="…"` of every part of a multipart body, in order."""
    return re.findall(r'(?<!file)name="([^"]+)"', raw)


def _value(raw, name):
    """The text value of a multipart part (`fileCreatedAt`, `deviceId`, …)."""
    match = re.search(r'name="%s"\r\n\r\n(.*?)\r\n' % re.escape(name), raw, re.S)
    return match.group(1) if match else None


@router.post("/api/assets")
def upload(req):
    """The extension's multipart upload — parsed, so a wrong body is visible."""
    raw = req.body.get("raw", "")
    names = _part_names(raw)
    filename = (re.search(r'filename="([^"]*)"', raw) or [None, None])[1]
    req.note(
        parts=names,
        filename=filename,
        asset_data=("assetData" in names),
        file_created_at=_value(raw, "fileCreatedAt"),
        device_asset_id=_value(raw, "deviceAssetId"),
        device_id=_value(raw, "deviceId"),
        checksum=req.headers.get("x-immich-checksum"),
        authorization=req.headers.get("Authorization"),
        content_type=(req.headers.get("Content-Type") or "").split(";")[0],
    )
    return Response({"id": UPLOAD_ID, "status": "created"}, status=201)


# MARK: - WebSocket (Socket.IO over engine.io v4)

class WebSocket:
    """One open connection. Its handler thread does every read and write on the
    socket; other threads only `post()` a text (or `None` to close) and wake it."""

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


def emit(event):
    """Send `42["<event>","<id>"]` to every open WebSocket; how many there are."""
    packet = "42" + json.dumps([event, EMIT_ID])
    with SOCKETS_LOCK:
        for ws in SOCKETS:
            ws.post(packet)
        return len(SOCKETS)


def close_sockets():
    with SOCKETS_LOCK:
        for ws in SOCKETS:
            ws.post(None)


# MARK: - Journal and control

def record(entry):
    with HANDSHAKES_LOCK:
        HANDSHAKES.append(entry)


def set_path(entry, path):
    with HANDSHAKES_LOCK:
        if entry["path"] is None:
            entry["path"] = path


def control(path, query):
    """The stub's own control routes, or None for the base's."""
    params = dict(parse_qsl(query, keep_blank_values=True))

    if path == "/__handshakes":
        with HANDSHAKES_LOCK:
            return Response([dict(entry) for entry in HANDSHAKES])

    if path == "/__client-cert/select":
        name = params.get("name")
        if name not in FIXTURES:
            return Response({"error": "unknown file", "name": name}, status=400)
        SELECTED["name"] = name
        return Response({"selected": name})

    if path == "/__client-cert/current":
        return Response(FIXTURES[SELECTED["name"]], ctype="application/octet-stream",
                        headers={"Cache-Control": "no-store"})

    if path == "/__client-cert/info":
        return Response({name: {"password": password} for name, password in PASSWORDS.items()})

    if path == "/__emit":
        EMITTED["seventh"] = True
        return Response({"sockets": emit(params.get("event") or "on_upload_success")})

    return None


@router.reset
def restore_client_cert():
    """`/__reset` wipes `STATE`; this wipes what this module keeps beside it."""
    with HANDSHAKES_LOCK:
        HANDSHAKES.clear()
    SELECTED["name"] = "a"
    EMITTED["seventh"] = False
    close_sockets()


# MARK: - Servers

class CertControl:
    """The control routes above, ahead of the base's (a mixin of both handlers)."""

    def _control(self, path, query):
        response = control(path, query)
        return response if response is not None else super()._control(path, query)


class ClientCertHandler(CertControl, selfsigned.SelfSignedHandler):
    """The API handler: records the first path of its connection in the
    handshake journal and serves the Socket.IO WebSocket."""

    def _dispatch(self, method):
        path, _, query = self.path.partition("?")
        entry = getattr(self.request, "journal_entry", None)
        if entry is not None:
            set_path(entry, path)
        if (method == "GET" and path.rstrip("/") == "/api/socket.io"
                and "websocket" in (self.headers.get("Upgrade") or "").lower()):
            self._websocket(path, query)
            return
        super()._dispatch(method)

    def _websocket(self, path, query):
        request = base.Request("GET", path, query, self.headers, {})
        authorization = self.headers.get("Authorization") or ""
        STATE["requests"].append({
            "method": "GET", "path": path, "params": request.params, "body": {},
            "auth": authorization.startswith("Bearer "), "status": 101,
        })
        key = self.headers.get("Sec-WebSocket-Key")
        tls = self.request
        if not key:
            self._send_counted(base._not_found(path))
            return
        accept = b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.close_connection = True
        ws = WebSocket()
        try:
            tls.sendall(("HTTP/1.1 101 Switching Protocols\r\n"
                         "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                         f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
            tls.sendall(encode_frame(0x1, OPEN_PACKET.encode()))
            with SOCKETS_LOCK:
                SOCKETS.append(ws)
            self._pump(tls, ws)
        except (OSError, EOFError, ValueError):
            pass  # the client left, or `/__reset` cut the connection
        finally:
            with SOCKETS_LOCK:
                if ws in SOCKETS:
                    SOCKETS.remove(ws)
            ws.dispose()

    def _pump(self, tls, ws):
        """Serve one WebSocket until a close frame, a reset or the client leaves."""
        next_ping = time.monotonic() + PING_SECONDS
        while True:
            if tls.pending():
                ready = [tls]
            else:
                wait = max(0.0, next_ping - time.monotonic())
                ready, _, _ = select.select([tls, ws.wake_r], [], [], wait)

            if ws.wake_r in ready:
                ws.drain()
            while True:
                try:
                    text = ws.outbox.get_nowait()
                except queue.Empty:
                    break
                if text is None:
                    tls.sendall(encode_frame(0x8))
                    return
                tls.sendall(encode_frame(0x1, text.encode()))

            if tls in ready:
                opcode, payload = read_frame(tls)
                if opcode == 0x8:  # close: answer it and stop
                    tls.sendall(encode_frame(0x8, payload[:2]))
                    return
                if opcode == 0x9:  # protocol-level ping
                    tls.sendall(encode_frame(0xA, payload))
                elif opcode in (0x1, 0x2):
                    text = payload.decode("utf-8", "replace")
                    if text.startswith("40"):  # Socket.IO: connect to the namespace
                        tls.sendall(encode_frame(0x1, b'40{"sid":"stub-nsp"}'))
                    # "3" (pong) and every other packet: ignored

            if time.monotonic() >= next_ping:
                tls.sendall(encode_frame(0x1, b"2"))
                next_ping = time.monotonic() + PING_SECONDS


class ClientCertControlHandler(CertControl, selfsigned.ControlHandler):
    """Plain-HTTP port P+1."""


class JournalingTLSServer(selfsigned.TLSServer):
    """`selfsigned.TLSServer`, plus one journal entry per accepted connection."""

    def finish_request(self, request, client_address):
        entry = {"port": self.server_address[1], "ok": False, "resumed": None,
                 "cert": None, "error": None, "path": None}
        request.settimeout(30)
        try:
            tls = self.context.wrap_socket(request, server_side=True)
        except OSError as error:  # no certificate, a bad one, or the client cut the socket
            selfsigned.count("handshakesFailed")
            entry["error"] = str(error)
            record(entry)
            sys.stderr.write(f"stub tls handshake failed: {error}\n")
            return
        selfsigned.count("handshakesOK")
        entry.update(ok=True, resumed=bool(tls.session_reused), cert=peer_label(tls))
        tls.journal_entry = entry
        record(entry)
        try:
            self.RequestHandlerClass(tls, client_address, self)
        except OSError:
            pass  # the client left mid-request; `_send_counted` already recorded it
        finally:
            tls.close()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8421
    selfsigned.PORT = port
    selfsigned.CONTROL_PORT = port + 1

    cert, key = selfsigned.make_certificate()
    ca = make_fixtures()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    context.verify_mode = ssl.CERT_REQUIRED
    context.load_verify_locations(ca)
    # The default session tickets are kept on purpose: AC-22 and AC-37.2 assert
    # that a certificate change is a FULL handshake, which only means something
    # on a server that would resume.

    # A port already taken raises OSError here: no silent fallback to another.
    api = JournalingTLSServer(("127.0.0.1", port), ClientCertHandler, context)
    other = JournalingTLSServer(("127.0.0.1", port + 2), ClientCertHandler, context)
    plain = ThreadingHTTPServer(("127.0.0.1", port + 1), ClientCertControlHandler)

    STATE["port"] = port
    print(json.dumps({
        "port": port,
        "controlPort": port + 1,
        "otherPort": port + 2,
        "label": "client_cert",
        "cert": os.path.abspath(cert),
        "ca": os.path.abspath(ca),
        "endpoints": base.BASE_ENDPOINTS + [
            "GET /__tls", "GET /__handshakes", "GET /__client-cert/select",
            "GET /__client-cert/current", "GET /__client-cert/info", "GET /__emit",
            "GET /api/socket.io/ (WebSocket)",
        ] + router.endpoints(),
    }), flush=True)
    threading.Thread(target=plain.serve_forever, daemon=True).start()
    threading.Thread(target=other.serve_forever, daemon=True).start()
    api.serve_forever()


if __name__ == "__main__":
    main()
