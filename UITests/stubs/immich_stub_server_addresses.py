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

Every `/__requests` entry carries what a scenario asserts on:
  address  `external` or `local`: the port the request arrived on;
  token    true when the request carried `Authorization`,
           `x-immich-user-token` or an `immich_access_token` cookie;
  xAccess  the value of `X-Access`, or null.

Control (never logged, answered on both ports)
----------------------------------------------
  GET /__addresses?local=<mode>   sets the behaviour of the local address:
      immich        (default after `/__reset`) answers like the external one;
      silent        every request is answered after 3 s (a probe times out);
      notimmich     `GET /api/server/ping` is 200 `{"status":"ok"}` and
                    `GET /api/server/version` is 404 (a web server that is not Immich);
      otherversion  `GET /api/server/version` answers 1.118.0 (another server).
  GET /__whoami                    the base's answer plus `localPort` and `deadPort`.
  GET /__reset, GET /__requests    as in the base (`/__reset` also puts the local
                                   address back to `immich`).

`/api/assets/<id>/video/playback` and `/api/socket.io/` are only logged (the
base answers them like any unrouted read), which is all a scenario needs: the
log says WHICH address a video read and a socket handshake went to.

Run by hand (the launcher `.omp/orchestration/uitest.sh` is not involved):

    python3 -u UITests/stubs/immich_stub_server_addresses.py 8421 &
    curl http://127.0.0.1:8421/__whoami   # {"port": 8421, "localPort": <L>, "deadPort": <D>, ...}
    TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test \\
        -scheme ImmichSwiftUI -destination 'platform=iOS Simulator,name=<iPhone>' \\
        -only-testing:ImmichSwiftUIUITests/ServerAddressesUITests
"""

import json
import os
import socket
import sys
import threading
import time
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qsl

import immich_stub_base as base
from immich_stub_base import STATE, Request, Response, StubHandler, router

SILENT_DELAY = 3.0
LOCAL_MODES = ("immich", "silent", "notimmich", "otherversion")

# One dict, mutated in place; `/__reset` puts `local` back (`router.reset`).
ADDRESSES = {"local": "immich", "localPort": 0, "deadPort": 0}


@router.reset
def _reset_addresses():
    ADDRESSES["local"] = "immich"


def _carries_token(headers):
    cookie = headers.get("Cookie") or ""
    return bool(headers.get("Authorization") or headers.get("x-immich-user-token")
                or "immich_access_token" in cookie)


class AddressHandler(StubHandler):
    """The base handler, plus the annotations of this stub's log and the modes of
    the local address. `address` is set by the two subclasses below."""

    address = "external"

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
                "deadPort": ADDRESSES["deadPort"],
                "pid": os.getpid(),
                "stub": os.path.basename(sys.argv[0]),
            })
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


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8421
    # The external port taken raises OSError here: no silent fallback to another.
    external = ThreadingHTTPServer(("127.0.0.1", port), ExternalHandler)
    local = ThreadingHTTPServer(("127.0.0.1", 0), LocalHandler)
    # Bound, never listening: a connection to it is refused, and the port stays
    # ours (so free of any other listener) until the process exits.
    dead = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    dead.bind(("127.0.0.1", 0))
    STATE["port"] = external.server_address[1]
    ADDRESSES["localPort"] = local.server_address[1]
    ADDRESSES["deadPort"] = dead.getsockname()[1]
    print(json.dumps({
        "port": STATE["port"],
        "localPort": ADDRESSES["localPort"],
        "deadPort": ADDRESSES["deadPort"],
        "label": "server_addresses",
        "timeline_day": base.TIMELINE_DAY,
        "endpoints": base.BASE_ENDPOINTS + ["GET /__addresses"] + router.endpoints(),
    }), flush=True)
    threading.Thread(target=local.serve_forever, daemon=True).start()
    external.serve_forever()


if __name__ == "__main__":
    main()
