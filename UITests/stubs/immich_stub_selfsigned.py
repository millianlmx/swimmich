"""Immich API stub served over HTTPS with a SELF-SIGNED certificate
(`SelfSignedTrustUITests`).

What it is for
--------------
The app trusts a self-signed server only for hosts the user approved
(`trustedServers` in `UserDefaults`). This stub is the server such an approval
is about: the whole Immich API on HTTPS, with a certificate no system trust
store knows. A scenario that launches the app with
`-trustedServers '("127.0.0.1")'` and sees requests arrive here has proven the
TLS handshake really passed — thumbnails, the full-screen image and the
transfers included.

Two ports (P = the port given on the command line, default 8421)
-----------------------------------------------------------------
  P      HTTPS. The API (`immich_stub_base` shell + this file's routes). The
         ONLY port whose requests are logged, so every `/__requests` entry
         proves the TLS handshake succeeded.
  P + 1  Plain HTTP. The control routes (`/__reset`, `/__provider`,
         `/__requests`, `/__whoami`, `/__tls`) and the OAuth provider pages
         (`/provider-manual`, `/provider-auto`), nothing else: `/api/…` answers
         404 there and is never logged. The XCUITest runner probes and drives
         the stub through it, because `URLSession.shared` refuses the
         self-signed port.
  `POST /api/oauth/authorize` answers `http://127.0.0.1:P+1/provider-<mode>`.

Run by hand (the launcher `.omp/orchestration/uitest.sh` is not involved):

    python3 -u UITests/stubs/immich_stub_selfsigned.py 8421 &
    TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test \\
        -scheme ImmichSwiftUI -destination 'platform=iOS Simulator,name=<iPhone>' \\
        -only-testing:ImmichSwiftUIUITests/SelfSignedTrustUITests

Ready when `http://127.0.0.1:8422/__whoami` answers.

What it adds to the base
------------------------
* Journal fields, set AFTER the last byte of the response was written (or the
  write failed): `status`, `contentLength` (bytes announced), `sent` (body
  bytes actually written), and `aborted: true` when the client cut the
  connection. A request whose entry has no `status` yet is still in flight, so
  a scenario POLLS `/__requests` until it sees them.
* `GET /__tls` (control port): `{"connections", "handshakesOK",
  "handshakesFailed"}` counted on P. `connections` counts TCP accepts; a
  handshake only counts as OK once the client sent its `Finished`, so a client
  that refuses the certificate shows up as `handshakesFailed`. Zeroed by
  `/__reset`. A plain-HTTP connection to P also counts as a failed handshake.
* The original of `TARGET` (the first timeline asset) is a 77 KiB PNG sent in
  16 chunks one second apart (~16 s): the scenario's clock for observing a
  download in flight. `fileSizeInByte` of its DTO announces that length.
  Everything else under `/api/assets/` is the base's own (`png()` thumbnails
  and originals, `Cache-Control: no-store`).

Certificate
-----------
Generated at every start by `openssl req -x509` into a temp dir (RSA 2048,
SHA-256, 30 days, SAN `IP:127.0.0.1`, EKU serverAuth, CA:TRUE — what iOS needs
to accept it as its own anchor). The key is a throwaway test key. Needs the
`openssl` binary on the PATH (macOS ships one); the stub exits 2 without it.

Extending it
------------
A sub-feature (Road Trip: album, geotagged assets, `POST /api/search/metadata`)
adds its fixtures to THIS file. An asset added later to `GET /api/assets/…` is
a branch on the id inside `one_asset` below, NEVER a second
`@router.prefix("GET", "/api/assets/")`: `Router.handle` only consults the
first prefix that matches.
"""
import json
import os
import random
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from http.server import ThreadingHTTPServer

import immich_stub_base as base
from immich_stub_base import Response, STATE, router

# Module state, set by `main()`: `restore()` and the OAuth route read them.
PORT = 8421
CONTROL_PORT = PORT + 1

# The asset whose original is streamed slowly (`DownloadPanelUITests` uses the
# same one).
TARGET = base.TIMELINE_ASSETS[0]

SIDE = 160              # 160×160 RGB → ~77 KiB of pixels
CHUNK_BYTES = 5 * 1024  # → 16 chunks
CHUNK_SECONDS = 1.0     # → ~16 s per original

CERT_CONFIG = """\
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = 127.0.0.1
[v3]
subjectAltName = IP:127.0.0.1
extendedKeyUsage = serverAuth
basicConstraints = critical, CA:TRUE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
"""

TLS = {"connections": 0, "handshakesOK": 0, "handshakesFailed": 0}
TLS_LOCK = threading.Lock()


def count(field):
    with TLS_LOCK:
        TLS[field] += 1


# MARK: - Fixtures


def original(aid, side=SIDE):
    """The asset's original: a real PNG of a size worth streaming.

    The pixels come from a PRNG seeded by the id, so the deflate stream cannot
    shrink them away and two calls return the same length (which is what lets
    the DTO announce it).
    """
    rng = random.Random(aid)
    raw = b"".join(b"\x00" + rng.randbytes(side * 3) for _ in range(side))

    def chunk(kind, data):
        payload = kind + data
        return (len(data).to_bytes(4, "big") + payload
                + (zlib.crc32(payload) & 0xFFFFFFFF).to_bytes(4, "big"))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", side.to_bytes(4, "big") + side.to_bytes(4, "big")
                    + bytes((8, 2, 0, 0, 0)))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


class Paced(Response):
    """A `Response` written one chunk at a time, `seconds` apart."""

    __slots__ = ("seconds",)

    def __init__(self, payload, status=200, ctype="application/octet-stream", seconds=CHUNK_SECONDS):
        super().__init__(payload, status=status, ctype=ctype,
                         headers={"Cache-Control": "no-store"})
        self.seconds = seconds


# MARK: - Routes


@router.post("/api/oauth/authorize")
def authorize(req):
    """The provider page lives on the plain-HTTP control port: the system web
    session that shows it must not be asked to trust the self-signed one."""
    return Response({"url": f"http://127.0.0.1:{CONTROL_PORT}/provider-{STATE['provider']}"})


@router.prefix("GET", "/api/assets/")
def one_asset(req):
    """The asset and its original. `None` for everything else, which the base
    shell answers. See the module docstring before adding a second prefix."""
    parts = req.rest.split("/")

    if parts == [TARGET]:
        dto = base.asset(TARGET)
        dto["exifInfo"]["fileSizeInByte"] = len(original(TARGET))
        return Response(dto)

    if parts == [TARGET, "original"]:
        return Paced(original(TARGET))

    return None


@router.reset
def restore():
    """`/__reset` wipes `STATE`, including the port `/__whoami` reports."""
    STATE["port"] = PORT
    with TLS_LOCK:
        for field in TLS:
            TLS[field] = 0


# MARK: - Certificate


def make_certificate():
    """`(cert, key)` paths of a fresh self-signed certificate, or exit 2."""
    folder = tempfile.mkdtemp(prefix="immich-stub-selfsigned-")
    cnf = os.path.join(folder, "openssl.cnf")
    key = os.path.join(folder, "key.pem")
    cert = os.path.join(folder, "cert.pem")
    with open(cnf, "w") as handle:
        handle.write(CERT_CONFIG)
    try:
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256",
                        "-days", "30", "-nodes", "-keyout", key, "-out", cert, "-config", cnf],
                       check=True, capture_output=True)
    except FileNotFoundError:
        sys.stderr.write("immich_stub_selfsigned: the `openssl` binary is not on the PATH\n")
        sys.exit(2)
    except subprocess.CalledProcessError as error:
        sys.stderr.write("immich_stub_selfsigned: openssl failed:\n"
                         + error.stderr.decode("utf-8", "replace") + "\n")
        sys.exit(2)
    return cert, key


# MARK: - Servers


class SelfSignedHandler(base.StubHandler):
    """The base handler, with what was really written recorded per request."""

    def _dispatch(self, method):
        path, _, query = self.path.partition("?")
        if path.startswith("/__") or path.startswith("/provider-"):
            self._send_counted(self._control(path, query))
            return
        request = base.Request(method, path, query, self.headers, self._body())
        entry = {"method": method, "path": path, "params": request.params, "body": request.body}
        STATE["requests"].append(entry)
        response = router.handle(request)
        if response is None:
            response = base._shell(method, request)
        if response is None:
            response = base._unrouted(method, path)
        entry.update(request.extra)
        status, length, sent, aborted = self._send_counted(response)
        entry.update(status=status, contentLength=length, sent=sent)
        if aborted:
            entry["aborted"] = True

    def _send_counted(self, response):
        """Send `response`; return `(status, length, sent, aborted)`."""
        payload = response.payload
        if isinstance(payload, bytes):
            body = payload
        elif response.ctype.startswith("text/"):
            body = payload.encode()
        else:
            body = json.dumps(payload).encode()
        sent = 0
        try:
            self.send_response(response.status)
            self.send_header("Content-Type", response.ctype)
            self.send_header("Content-Length", str(len(body)))
            for name, value in response.headers.items():
                self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            if isinstance(response, Paced):
                for start in range(0, len(body), CHUNK_BYTES):
                    piece = body[start:start + CHUNK_BYTES]
                    self.wfile.write(piece)
                    self.wfile.flush()
                    sent += len(piece)
                    time.sleep(response.seconds)
            else:
                self.wfile.write(body)
                sent = len(body)
        except OSError:
            self.close_connection = True
            return response.status, len(body), sent, True
        return response.status, len(body), sent, False

    def _control(self, path, query):
        if path == "/__tls":
            with TLS_LOCK:
                return Response(dict(TLS))
        return super()._control(path, query)


class ControlHandler(SelfSignedHandler):
    """Plain-HTTP port P+1: control routes and provider pages only, never logged."""

    def _dispatch(self, method):
        path, _, query = self.path.partition("?")
        if path.startswith("/__") or path.startswith("/provider-"):
            self._send_counted(self._control(path, query))
        else:
            self._send_counted(base._not_found(path))


class TLSServer(ThreadingHTTPServer):
    """HTTPS: wraps each accepted connection in its worker thread, so a slow or
    refused handshake never blocks the accept loop, and counts the outcome."""

    def __init__(self, address, handler, context):
        super().__init__(address, handler)
        self.context = context

    def get_request(self):
        sock, address = self.socket.accept()
        count("connections")
        return sock, address

    def finish_request(self, request, client_address):
        request.settimeout(30)
        try:
            tls = self.context.wrap_socket(request, server_side=True)
        except OSError as error:  # ssl.SSLError, or the client cut the socket
            count("handshakesFailed")
            sys.stderr.write(f"stub tls handshake failed: {error}\n")
            return
        count("handshakesOK")
        try:
            self.RequestHandlerClass(tls, client_address, self)
        except OSError:
            pass  # the client left mid-request; `_send_counted` already recorded it
        finally:
            tls.close()


def main():
    global PORT, CONTROL_PORT
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8421

    cert, key = make_certificate()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)

    # A port already taken raises OSError here: no silent fallback to another.
    server = TLSServer(("127.0.0.1", port), SelfSignedHandler, context)
    control = ThreadingHTTPServer(("127.0.0.1", port + 1), ControlHandler)

    PORT = port
    CONTROL_PORT = port + 1
    STATE["port"] = port
    print(json.dumps({
        "port": PORT,
        "controlPort": CONTROL_PORT,
        "label": "selfsigned",
        "cert": os.path.abspath(cert),
        "timeline_day": base.TIMELINE_DAY,
        "endpoints": base.BASE_ENDPOINTS + ["GET /__tls"] + router.endpoints(),
    }), flush=True)
    threading.Thread(target=control.serve_forever, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
