"""Immich API stub for the custom-HTTP-headers scenario (`CustomHeadersUITests`).

A reverse proxy in front of the stub shell: this file adds no Immich route of its
own, it puts a GATE before every request the other stubs would answer, and it
records what each request carried. The pieces it reuses:

* `immich_stub_base` — the OAuth handshake, the day of timeline, the PNG
  thumbnails and originals, `/api/users/me`, the request log;
* `immich_stub_share_extension` — `GET /api/albums`, `POST /api/assets` and
  `PUT /api/albums/{id}/assets`, which the share extension calls;
* `immich_stub_video_player` — the video tile at the head of the day
  (`VIDEO_ID`) and `GET /api/assets/{VIDEO_ID}/video/playback`.

    python3 UITests/stubs/immich_stub_proxy_headers.py 8421

    curl http://127.0.0.1:8421/__whoami
    curl -X PUT -d '{"mode": "basic"}' http://127.0.0.1:8421/stub/proxy-mode

THE GATE (`STATE["proxy_mode"]`, set by `PUT /stub/proxy-mode`)

    xaccess   (default, restored by `/__reset`)
              403 `{"message": "proxy: missing X-Access"}` unless `X-Access: secret`.
    basic     401 WITH `WWW-Authenticate: Basic realm="stub-proxy"` unless
              `Authorization: Basic dXNlcjpwYXNz` — that is the PROXY refusing. Then,
              for a path that is not public and not the socket, 401 WITHOUT
              `WWW-Authenticate` and the body of Immich's own refusal unless
              `x-immich-user-token: stub-access-token` — that is the SERVER refusing.
    off       no gate.

The gate only applies to requests addressed to the host `127.0.0.1`. The same
process also answers as `localhost` (the "server B" of AC-120), and a request to
that host is never filtered: what the scenario proves there is what the app SENT.

`/__*` and `/provider-*` (the control routes and the web page of the SSO) are
answered by `immich_stub_base._dispatch` before any router, so they never reach
the gate and are not logged — a proxy does not stand in front of the browser
sheet's own page, and the scenario's polling must not grow the log.

THE LOG. Every request that reaches the router gets `headers` (everything
received, `dict(req.headers)`, names as the client wrote them) and `host` (the
`Host` header) in its `/__requests` entry; a request the gate refused also gets
`proxy_status` (the status it was answered with), because the base log keeps no
status and "no request was refused" is an assertion the scenario makes.
"""
import immich_stub_share_extension  # noqa: F401  (registers /api/albums, /api/assets, /api/albums/*)
import immich_stub_video_player  # noqa: F401  (the video tile and /api/assets/{VIDEO_ID}/video/playback)
from immich_stub_base import STATE, Response, main, router

MODES = ("xaccess", "basic", "off")
DEFAULT_MODE = "xaccess"

# The proxy of the "xaccess" mode wants this header, with this value.
ACCESS_VALUE = "secret"
# The proxy of the "basic" mode wants this credential (`user:pass`).
BASIC_AUTHORIZATION = "Basic dXNlcjpwYXNz"
# The token the stub's OAuth handshake hands out; behind the "basic" proxy the app
# sends it in `x-immich-user-token`, since `Authorization` carries the proxy's own.
USER_TOKEN = "stub-access-token"

# Paths a session-less caller reaches: the server step and the SSO handshake.
PUBLIC = {
    "/api/server/ping", "/api/server/version", "/api/server/config", "/api/server/features",
    "/api/oauth/authorize", "/api/oauth/callback", "/api/auth/login",
}
SOCKET_PREFIX = "/api/socket.io"

# The only host the gate applies to.
GATED_HOST = "127.0.0.1"

STATE["proxy_mode"] = DEFAULT_MODE


@router.put("/stub/proxy-mode")
def set_proxy_mode(req):
    """`PUT /stub/proxy-mode` with `{"mode": "xaccess" | "basic" | "off"}`."""
    mode = req.body.get("mode") if isinstance(req.body, dict) else None
    if mode not in MODES:
        return Response({"message": f"unknown proxy mode: {mode!r}", "modes": list(MODES)}, status=400)
    STATE["proxy_mode"] = mode
    req.note(mode=mode)
    return Response({"mode": mode})


@router.reset
def restore_proxy_mode():
    """`/__reset` wipes `STATE` first; the default mode is what a scenario starts from."""
    STATE["proxy_mode"] = DEFAULT_MODE


def _host_name(req):
    """The `Host` header without its port (`127.0.0.1:8421` → `127.0.0.1`)."""
    return (req.headers.get("Host") or "").split(":")[0].lower()


def _refuse(req, status, payload, headers=None):
    req.note(proxy_status=status)
    return Response(payload, status=status, headers=headers)


def _gate(req):
    """The proxy: a refusal `Response`, or `None` to let the request through."""
    if _host_name(req) != GATED_HOST:
        return None
    mode = STATE.get("proxy_mode", DEFAULT_MODE)
    if mode == "xaccess":
        if req.headers.get("X-Access") != ACCESS_VALUE:
            return _refuse(req, 403, {"message": "proxy: missing X-Access"})
        return None
    if mode == "basic":
        if req.headers.get("Authorization") != BASIC_AUTHORIZATION:
            return _refuse(req, 401, {"message": "proxy: authentication required"},
                           headers={"WWW-Authenticate": 'Basic realm="stub-proxy"'})
        if req.path in PUBLIC or req.path.startswith(SOCKET_PREFIX):
            return None
        if req.headers.get("x-immich-user-token") != USER_TOKEN:
            return _refuse(req, 401, {"message": "Invalid user token", "statusCode": 401})
    return None


_route = router.handle


def handle(req):
    """Logs what the request carried, applies the gate, then delegates to the
    routes registered by the stubs above — which answer `None` to let the shell
    of `immich_stub_base` reply. The mode switch is exempt: a gate that refused
    the call that opens it could never be opened."""
    req.note(headers=dict(req.headers), host=req.headers.get("Host"))
    if not (req.method == "PUT" and req.path == "/stub/proxy-mode"):
        refusal = _gate(req)
        if refusal is not None:
            return refusal
    return _route(req)


router.handle = handle


if __name__ == "__main__":
    main(label="proxy-headers")
