"""Immich API stub that answers on TWO addresses (`ServerAddressesUITests`, L-26).

What it is for
--------------
A server can be reached on a local address and on an external one. This stub is
that server seen from both: the whole Immich API on `127.0.0.1:P` (the external
address, also the address the user connects with) and on `127.0.0.1:L` (the
local address), in ONE process, so both ports share one request log.

Ports (P = the port given on the command line, default 8421)
-------------------------------------------------------------
  P  External address. The API (`immich_stub_base` shell).
  L  Local address. The same API, in a mode a scenario picks. Chosen by the
     system (`bind` on port 0): a fixed offset from P can fall in the pool of
     another runner on the same Mac. Read it from `/__whoami` (`localPort`).
  D  A port nobody listens on (`deadPort` in `/__whoami`): bound by this
     process for its whole life WITHOUT `listen`, so a connection is refused
     and no other process can take the port meanwhile.
  T  Local address over TLS (`tlsLocalPort` in `/__whoami`, null without
     `openssl`): the same API as L (same modes), served with a self-signed
     certificate for 127.0.0.1 AND a REQUIRED client certificate (the CA of
     "Swimmich Test CA"; client A, PKCS#12 password `alpha`). A journal entry
     of this port exists only after a handshake where the client accepted the
     self-signed certificate and presented A. Chosen by the system like L.

Every `/__requests` entry carries what a scenario asserts on:
  address  `external` or `local`: the port the request arrived on (T is `local`);
  token    true when the request carried `Authorization`,
           `x-immich-user-token` or an `immich_access_token` cookie;
  xAccess  the value of `X-Access`, or null;
  tls      true only for a request that arrived on T;
  cert     on T, "A" / "unknown" (the label of the client certificate shown) or
           null (none); null on the other ports.

Control (never logged, answered on both ports)
----------------------------------------------
  GET /__addresses?local=<mode>   sets the behaviour of the local address:
      immich        (default after `/__reset`) answers like the external one;
      silent        every request is answered after 3 s (a probe times out);
      notimmich     `GET /api/server/ping` is 200 `{"status":"ok"}` and
                    `GET /api/server/version` is 404 (a web server that is not Immich);
      otherversion  `GET /api/server/version` answers 1.118.0 (another server).
  GET /__whoami                    the base's answer plus `localPort`, `tlsLocalPort`
                                   and `deadPort`.
  GET /__handshakes                the TLS handshakes of T since the last reset:
                                   [{"ok": bool, "cert": "A"|"unknown"|null, "error": str|null}].
  GET /__client-cert/current       the PKCS#12 of client A (`application/octet-stream`,
                                   `no-store`), the file `-uiTestClientCertificateFeed`
                                   downloads; 404 without TLS material.
  GET /__reset, GET /__requests    as in the base (`/__reset` also puts the local
                                   address back to `immich` and empties the handshakes).

`POST /api/assets` is the share extension's upload: multipart, answered 201
`{"id": <UPLOAD_ID>, "status": "created"}` (copied from `immich_stub_client_cert.py`).
The certificates are made at start-up with `openssl` (in a temporary folder;
copied from `immich_stub_selfsigned.py` CERT_CONFIG / make_certificate and
`immich_stub_client_cert.py` CA_CONFIG / CLIENT_* / make_fixtures, which this
module must NOT import: their routes would hijack the sign-in). Without `openssl`
the stub writes one line on stderr and runs without T (`tlsLocalPort: null`).

`/api/socket.io/` is only logged (the base answers it like any unrouted read),
which is all a scenario needs: the log says WHICH address a socket handshake
went to. The first asset of the day (`aaaaaaaa-…-000000000001`) is a video with
real MP4 bytes on `/api/assets/<id>/video/playback`: the routes of
`immich_stub_video_player` (imported below), so a video opened in the viewer is
read and logged on the address it went to (`ServerAddressesUITests.test_AC_238`).

Run by hand (the launcher `.omp/orchestration/uitest.sh` is not involved):

    python3 -u UITests/stubs/immich_stub_server_addresses.py 8421 &
    curl http://127.0.0.1:8421/__whoami   # {"port": 8421, "localPort": <L>, "deadPort": <D>, ...}
    TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test \\
        -scheme ImmichSwiftUI -destination 'platform=iOS Simulator,name=<iPhone>' \\
        -only-testing:ImmichSwiftUIUITests/ServerAddressesUITests
"""

import hashlib
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qsl

import immich_stub_base as base
# Registers the video routes on the shared router: the day's first tile is a
# real MP4 (timeline bucket, playback with byte ranges, one video memory).
import immich_stub_video_player  # noqa: F401
from immich_stub_base import STATE, Request, Response, StubHandler, router

SILENT_DELAY = 3.0
LOCAL_MODES = ("immich", "silent", "notimmich", "otherversion")
UPLOAD_ID = "dddddddd-1111-4111-8111-000000000001"

# One dict, mutated in place; `/__reset` puts `local` back (`router.reset`).
ADDRESSES = {"local": "immich", "localPort": 0, "deadPort": 0, "tlsLocalPort": None}

# The TLS port's material and journal. `P12` is the bytes of client A's file;
# `FINGERPRINTS` maps the SHA-256 of a DER client certificate to its label.
TLS_MATERIAL = {"p12": None}
FINGERPRINTS = {}
HANDSHAKES = []
HANDSHAKES_LOCK = threading.Lock()

# `immich_stub_selfsigned.py:105-118`
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

# `immich_stub_client_cert.py:152-177`
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

# The algorithms `SecPKCS12Import` reads (`immich_stub_client_cert.py:179-181`).
LEGACY_P12 = ["-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"]


@router.reset
def _reset_addresses():
    ADDRESSES["local"] = "immich"
    with HANDSHAKES_LOCK:
        HANDSHAKES.clear()


def _carries_token(headers):
    cookie = headers.get("Cookie") or ""
    return bool(headers.get("Authorization") or headers.get("x-immich-user-token")
                or "immich_access_token" in cookie)


# MARK: - TLS material

def _openssl(*args):
    subprocess.run(["openssl", *args], check=True, capture_output=True)


def _write(path, text):
    with open(path, "w") as handle:
        handle.write(text)


def make_tls_material():
    """`(server cert, server key, CA)` paths, with client A's PKCS#12 and its
    fingerprint filled in `TLS_MATERIAL` / `FINGERPRINTS`; None when `openssl`
    is absent or fails (one line on stderr, the stub runs without port T)."""
    try:
        folder = tempfile.mkdtemp(prefix="immich-stub-server-addresses-")

        def at(name):
            return os.path.join(folder, name)

        _write(at("server.cnf"), CERT_CONFIG)
        _openssl("req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "30", "-nodes",
                 "-keyout", at("server.key"), "-out", at("server.pem"), "-config", at("server.cnf"))
        _write(at("ca.cnf"), CA_CONFIG)
        _openssl("req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "30", "-nodes",
                 "-keyout", at("ca.key"), "-out", at("ca.pem"), "-config", at("ca.cnf"))
        _write(at("client.ext"), CLIENT_EXTENSIONS)
        _write(at("a.cnf"), CLIENT_CONFIG.format(cn="client-a"))
        _openssl("req", "-new", "-newkey", "rsa:2048", "-sha256", "-nodes",
                 "-keyout", at("a.key"), "-out", at("a.csr"), "-config", at("a.cnf"))
        _openssl("x509", "-req", "-in", at("a.csr"), "-CA", at("ca.pem"), "-CAkey", at("ca.key"),
                 "-CAcreateserial", "-days", "30", "-sha256", "-extfile", at("client.ext"),
                 "-out", at("a.pem"))
        _openssl("pkcs12", "-export", "-inkey", at("a.key"), "-in", at("a.pem"),
                 *LEGACY_P12, "-passout", "pass:alpha", "-out", at("a.p12"))
        with open(at("a.pem")) as handle:
            der = ssl.PEM_cert_to_DER_cert(handle.read())
        FINGERPRINTS[hashlib.sha256(der).hexdigest()] = "A"
        with open(at("a.p12"), "rb") as handle:
            TLS_MATERIAL["p12"] = handle.read()
        return at("server.pem"), at("server.key"), at("ca.pem")
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        detail = error.stderr.decode("utf-8", "replace") if isinstance(error, subprocess.CalledProcessError) else str(error)
        sys.stderr.write(f"immich_stub_server_addresses: no TLS port (openssl: {detail.strip()})\n")
        TLS_MATERIAL["p12"] = None
        FINGERPRINTS.clear()
        return None


def peer_label(tls):
    """"A", "unknown", or None when the peer showed no certificate
    (`immich_stub_client_cert.py:238-243`)."""
    der = tls.getpeercert(binary_form=True)
    if der is None:
        return None
    return FINGERPRINTS.get(hashlib.sha256(der).hexdigest(), "unknown")


# MARK: - Upload (copied from immich_stub_client_cert.py:329-359)

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




def _carries_token(headers):
    cookie = headers.get("Cookie") or ""
    return bool(headers.get("Authorization") or headers.get("x-immich-user-token")
                or "immich_access_token" in cookie)


class AddressHandler(StubHandler):
    """The base handler, plus the annotations of this stub's log and the modes of
    the local address. `address` is set by the two subclasses below."""

    address = "external"
    tls = False

    def _dispatch(self, method):
        path, _, query = self.path.partition("?")
        if path.startswith("/__") or path.startswith("/provider-"):
            return self._send(self._control(path, query))
        request = Request(method, path, query, self.headers, self._body())
        entry = {
            "method": method,
            "path": path,
            "params": request.params,
            "body": request.body,
            "address": self.address,
            "token": _carries_token(self.headers),
            "xAccess": self.headers.get("X-Access"),
            "tls": self.tls,
            "cert": getattr(self.request, "peer_cert_label", None) if self.tls else None,
        }
        STATE["requests"].append(entry)
        response = None
        if self.address == "local":
            response = self._local_mode(request)
        if response is None:
            response = router.handle(request)
        if response is None:
            response = base._shell(method, request)
        if response is None:
            response = base._unrouted(method, path)
        entry.update(request.extra)
        self._send(response)

    def _local_mode(self, request):
        """The behaviour of the local address, or None to answer as the external one."""
        mode = ADDRESSES["local"]
        if mode == "silent":
            time.sleep(SILENT_DELAY)
            return None
        if mode == "notimmich":
            if request.path == "/api/server/ping":
                return Response({"status": "ok"})
            if request.path == "/api/server/version":
                return Response({"error": "not found"}, status=404)
            return None
        if mode == "otherversion" and request.path == "/api/server/version":
            return Response({"major": 1, "minor": 118, "patch": 0, "prerelease": None})
        return None

    def _control(self, path, query):
        params = dict(parse_qsl(query, keep_blank_values=True))
        if path == "/__addresses":
            mode = params.get("local")
            if mode is not None:
                if mode not in LOCAL_MODES:
                    return Response({"error": f"unknown mode {mode}", "modes": list(LOCAL_MODES)}, status=400)
                ADDRESSES["local"] = mode
            return Response({"local": ADDRESSES["local"]})
        if path == "/__whoami":
            return Response({
                "port": STATE["port"],
                "localPort": ADDRESSES["localPort"],
                "tlsLocalPort": ADDRESSES["tlsLocalPort"],
                "deadPort": ADDRESSES["deadPort"],
                "pid": os.getpid(),
                "stub": os.path.basename(sys.argv[0]),
            })
        if path == "/__handshakes":
            with HANDSHAKES_LOCK:
                return Response(list(HANDSHAKES))
        if path == "/__client-cert/current":
            if TLS_MATERIAL["p12"] is None:
                return Response({"error": "no TLS material: is openssl on the PATH?"}, status=404)
            return Response(TLS_MATERIAL["p12"], ctype="application/octet-stream",
                            headers={"Cache-Control": "no-store"})
        return super()._control(path, query)

    def _send(self, response):
        try:
            super()._send(response)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the probe gave up before the answer (a `silent` local address)


class ExternalHandler(AddressHandler):
    address = "external"


class LocalHandler(AddressHandler):
    address = "local"


class LocalTLSHandler(AddressHandler):
    """The local address over TLS: the same modes as `LocalHandler`."""
    address = "local"
    tls = True


class LocalTLSServer(ThreadingHTTPServer):
    """`ThreadingHTTPServer` over TLS with a REQUIRED client certificate, one
    handshake journal entry per accepted connection
    (`immich_stub_client_cert.py:597-621`)."""

    def __init__(self, address, handler, context):
        super().__init__(address, handler)
        self.context = context

    def finish_request(self, request, client_address):
        request.settimeout(30)
        try:
            tls = self.context.wrap_socket(request, server_side=True)
        except OSError as error:  # no certificate, a bad one, or the client cut the socket
            with HANDSHAKES_LOCK:
                HANDSHAKES.append({"ok": False, "cert": None, "error": str(error)})
            return
        label = peer_label(tls)
        with HANDSHAKES_LOCK:
            HANDSHAKES.append({"ok": True, "cert": label, "error": None})
        tls.peer_cert_label = label
        try:
            self.RequestHandlerClass(tls, client_address, self)
        except OSError:
            pass  # the client left mid-request
        finally:
            tls.close()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8421
    # Material first: a few seconds at most, inside the launcher's wait for `/__whoami`.
    material = make_tls_material()
    # The external port taken raises OSError here: no silent fallback to another.
    external = ThreadingHTTPServer(("127.0.0.1", port), ExternalHandler)
    local = ThreadingHTTPServer(("127.0.0.1", 0), LocalHandler)
    tls_local = None
    if material is not None:
        cert, key, ca = material
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        context.verify_mode = ssl.CERT_REQUIRED
        context.load_verify_locations(ca)
        tls_local = LocalTLSServer(("127.0.0.1", 0), LocalTLSHandler, context)
    # Bound, never listening: a connection to it is refused, and the port stays
    # ours (so free of any other listener) until the process exits.
    dead = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    dead.bind(("127.0.0.1", 0))
    STATE["port"] = external.server_address[1]
    ADDRESSES["localPort"] = local.server_address[1]
    ADDRESSES["tlsLocalPort"] = tls_local.server_address[1] if tls_local else None
    ADDRESSES["deadPort"] = dead.getsockname()[1]
    print(json.dumps({
        "port": STATE["port"],
        "localPort": ADDRESSES["localPort"],
        "tlsLocalPort": ADDRESSES["tlsLocalPort"],
        "deadPort": ADDRESSES["deadPort"],
        "label": "server_addresses",
        "timeline_day": base.TIMELINE_DAY,
        "endpoints": base.BASE_ENDPOINTS + ["GET /__addresses", "GET /__handshakes",
                                            "GET /__client-cert/current"] + router.endpoints(),
    }), flush=True)
    threading.Thread(target=local.serve_forever, daemon=True).start()
    if tls_local:
        threading.Thread(target=tls_local.serve_forever, daemon=True).start()
    external.serve_forever()


if __name__ == "__main__":
    main()
