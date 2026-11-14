"""Immich API stub for the sign-in and startup scenarios (`LoginStartupUITests`, lot L-28).

    python3 UITests/stubs/immich_stub_login.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/login.uitest.log \\
        UITests/stubs/immich_stub_login.py \\
        LoginStartupUITests/test_AC_53 --erase

WHAT THIS STUB IS FOR

A server whose sign-in modes, version, reachability and token validity the
scenario sets from the test, on top of the shared shell (OAuth handshake, one
day of six photos, real thumbnails). Every control is a plain `GET`, answered
under `/control/` (the shell answers `/__…` itself, before the router); a
`GET /__reset` restores the defaults: version 2.0.0, password 1, oauth 1,
buttonText "Continue with Immich SSO", features `ok`, no revocation, no mute,
no delay, no hold (a request still held is released), no asset status override.

CONTROLS

* `/control/server?version=<x.y.z|bad|error>&password=<0|1>&oauth=<0|1>&buttonText=<text>&features=<ok|absent|error|bad>`
  Only the parameters that are present change; a blank `buttonText=` is a
  value (the empty label of AC-332).
    - `/api/server/version`: `bad` serves `{"oops": 1}` (undecodable), `error`
      serves 500, else the announced version.
    - `/api/public/config`: served only when the announced version is readable
      and >= 3.2.0 (full `PublicConfigDto` shape), else 404.
    - `/api/server/features`: `ok` serves 17 fields (`passwordLogin` and
      `oauth` among them), `absent` 404, `error` 500, `bad` `{"oops": 1}`.
    - `/api/server/config`: the shell's `CONFIG` with `oauthButtonText = buttonText`.
* `/control/revoke?on=<0|1>`: revoked, every authenticated `/api/…` route
  answers 401 without `WWW-Authenticate` (`validateToken` included).
  `/api/server/*`, `/api/auth/login`, `/api/oauth/*` and `/api/public/*` stay served.
* `/control/mute?mode=<off|hang|drop>&seconds=<n>`: `hang` makes every `/api/…`
  request (the ping included) sleep `n` seconds, then answer normally (the
  server is threaded: only that request blocks); `drop` raises inside the
  handler, so the connection closes with no response.
* `/control/delay?path=<exact path>&seconds=<n>`: delays one route; each call
  sets or replaces the delay of its own path and leaves the others alone;
  `seconds=0` removes it.
* `/control/hold?path=<exact path>&on=<0|1>`: `on=1` holds every request of that
  route until `on=0` releases them (at most 30 s, so a forgotten hold never
  pins a server thread): the scenario, not a clock, decides when the answer
  leaves, after it has seen what the app shows meanwhile.
* `/control/asset?id=<id>&status=<200|400|404>`: status of `GET /api/assets/<id>`
  for that id; its thumbnail and original stay served.

OTHER ROUTES

`POST /api/auth/login` (the shell's `LOGIN`), `POST /api/auth/validateToken`,
`GET /api/memories` (one memory of two shell photos, the shape of
`immich_stub_memories.memory_dto`), `POST /api/assets/bulk-upload-check`
(every asked id is a `reject`/`duplicate` of a shell photo: a manual backup pass
leaves its trace in the journal and uploads nothing).

HOW THE HOOKS ACT BEFORE ROUTING

The shell journals a request (`/__requests`) before it calls `router.handle`.
Mute, delay and revocation are therefore done in a wrapper installed on
`router.handle` itself: the request is already in the journal when it sleeps,
is dropped or is refused, and a route registered below needs no knowledge of
any of it. Overriding `StubHandler._dispatch` would run BEFORE the journal.
Control and `/__…` requests are never muted, delayed, held nor refused.
"""
import re
import threading
import time

from immich_stub_base import (
    CONFIG, LOGIN, ME, Response, STATE, TIMELINE_ASSETS, asset, main, router,
)

DEFAULTS = {
    "version": "2.0.0",
    "password": True,
    "oauth": True,
    "buttonText": "Continue with Immich SSO",
    "features": "ok",
    "revoked": False,
    "mute": "off",
    "muteSeconds": 0.0,
    "delays": {},
    "assetStatus": {},
}


# The held routes and their gates. Outside `STATE`, which the shell wipes before
# the reset hooks run: a gate dropped there would leave its request held.
_HOLDS = {}
_HOLDS_LOCK = threading.Lock()


def _release_all():
    with _HOLDS_LOCK:
        gates = list(_HOLDS.values())
        _HOLDS.clear()
    for gate in gates:
        gate.set()


@router.reset
def fresh():
    # A request held by the previous scenario answers now, not 30 s into this one.
    _release_all()
    for key, value in DEFAULTS.items():
        STATE[key] = dict(value) if isinstance(value, dict) else value


fresh()

_VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def _version():
    """`(major, minor, patch)` of the announced version, `None` when unreadable."""
    match = _VERSION.match(STATE["version"])
    return None if match is None else tuple(int(part) for part in match.groups())


def _seconds(raw):
    try:
        return max(0.0, float(raw))
    except (TypeError, ValueError):
        return 0.0


# The longest a held request waits for its release.
_HOLD_CAP = 30.0


# MARK: - Hooks before routing

_PUBLIC_PREFIXES = ("/api/server/", "/api/auth/login", "/api/oauth/", "/api/public/")


def _hooked(handle):
    def wrapper(request):
        path = request.path
        if path.startswith("/api/"):
            mode = STATE["mute"]
            if mode == "drop":
                # Not caught on purpose: the connection closes with no response.
                raise RuntimeError("stub: connection dropped on purpose")
            if mode == "hang":
                time.sleep(STATE["muteSeconds"])
            delay = STATE["delays"].get(path)
            if delay:
                time.sleep(delay)
            with _HOLDS_LOCK:
                gate = _HOLDS.get(path)
            if gate is not None:
                gate.wait(_HOLD_CAP)
            if STATE["revoked"] and not path.startswith(_PUBLIC_PREFIXES):
                return Response({"message": "Invalid user token", "error": "Unauthorized",
                                 "statusCode": 401}, status=401)
        return handle(request)
    return wrapper


router.handle = _hooked(router.handle)


# MARK: - Controls


@router.get("/control/server")
def control_server(req):
    params = req.params
    if "version" in params:
        STATE["version"] = params["version"]
    if "password" in params:
        STATE["password"] = params["password"] == "1"
    if "oauth" in params:
        STATE["oauth"] = params["oauth"] == "1"
    if "buttonText" in params:
        STATE["buttonText"] = params["buttonText"]
    if "features" in params:
        STATE["features"] = params["features"]
    return Response({k: STATE[k] for k in ("version", "password", "oauth", "buttonText", "features")})


@router.get("/control/revoke")
def control_revoke(req):
    STATE["revoked"] = req.params.get("on") == "1"
    return Response({"revoked": STATE["revoked"]})


@router.get("/control/mute")
def control_mute(req):
    mode = req.params.get("mode", "off")
    STATE["mute"] = mode if mode in ("off", "hang", "drop") else "off"
    STATE["muteSeconds"] = _seconds(req.params.get("seconds"))
    return Response({"mute": STATE["mute"], "seconds": STATE["muteSeconds"]})


@router.get("/control/delay")
def control_delay(req):
    path = req.params.get("path", "")
    seconds = _seconds(req.params.get("seconds"))
    if seconds > 0:
        STATE["delays"][path] = seconds
    else:
        STATE["delays"].pop(path, None)
    return Response({"delays": STATE["delays"]})


@router.get("/control/hold")
def control_hold(req):
    path = req.params.get("path", "")
    with _HOLDS_LOCK:
        if req.params.get("on") == "1":
            _HOLDS.setdefault(path, threading.Event())
            gate = None
        else:
            gate = _HOLDS.pop(path, None)
        held = sorted(_HOLDS)
    if gate is not None:
        gate.set()
    return Response({"holds": held})


@router.get("/control/asset")
def control_asset(req):
    aid = req.params.get("id", "")
    status = req.params.get("status", "200")
    if status == "200":
        STATE["assetStatus"].pop(aid, None)
    else:
        STATE["assetStatus"][aid] = int(status)
    return Response({"assetStatus": STATE["assetStatus"]})


# MARK: - Server


@router.get("/api/server/version")
def server_version(req):
    mode = STATE["version"]
    if mode == "error":
        return Response({"message": "boom", "statusCode": 500}, status=500)
    parsed = _version()
    if parsed is None:
        return Response({"oops": 1})
    major, minor, patch = parsed
    return Response({"major": major, "minor": minor, "patch": patch, "prerelease": None})


@router.get("/api/public/config")
def public_config(req):
    parsed = _version()
    if parsed is None or parsed < (3, 2, 0):
        return Response({"message": "Cannot GET /api/public/config", "statusCode": 404}, status=404)
    return Response({
        "ffmpeg": {"accel": "disabled", "accelDecode": False},
        "map": {"enabled": True, "lightStyle": "", "darkStyle": ""},
        "oauth": {
            "enabled": STATE["oauth"], "autoLaunch": False, "buttonText": STATE["buttonText"],
            "mobileOverrideEnabled": False, "mobileRedirectUri": "",
        },
        "passkey": {"enabled": False},
        "passwordLogin": {"enabled": STATE["password"]},
        "server": {
            "loginPageMessage": CONFIG["loginPageMessage"], "trashDays": 30, "userDeleteDelay": 7,
            "isInitialized": True, "isOnboarded": True, "externalDomain": "", "publicUsers": False,
            "mapDarkStyleUrl": "", "mapLightStyleUrl": "", "maintenanceMode": False, "minFaces": 0,
        },
    })


@router.get("/api/server/features")
def server_features(req):
    mode = STATE["features"]
    if mode == "absent":
        return Response({"message": "Cannot GET /api/server/features", "statusCode": 404}, status=404)
    if mode == "error":
        return Response({"message": "boom", "statusCode": 500}, status=500)
    if mode == "bad":
        return Response({"oops": 1})
    return Response({
        "trash": True, "map": True, "reverseGeocoding": True, "importFaces": False,
        "oauth": STATE["oauth"], "oauthAutoLaunch": False, "passwordLogin": STATE["password"],
        "sidecar": True, "search": True, "configFile": False, "duplicateDetection": False,
        "facialRecognition": True, "smartSearch": True, "email": False, "ocr": False,
        "publicUsers": False, "maintenanceMode": False,
    })


@router.get("/api/server/config")
def server_config(req):
    return Response({**CONFIG, "oauthButtonText": STATE["buttonText"]})


# MARK: - Session


@router.post("/api/auth/login")
def login(req):
    return Response(LOGIN)


@router.post("/api/auth/validateToken")
def validate_token(req):
    # A revoked session never gets here: the wrapper answered 401 first.
    return Response({"authStatus": True})


# MARK: - Assets, memories, backup


@router.prefix("GET", "/api/assets/")
def asset_status(req):
    """`GET /api/assets/<id>` answers the status set by `/control/asset`; the
    other routes under it (thumbnail, original) fall through to the shell."""
    if "/" in req.rest:
        return None
    status = STATE["assetStatus"].get(req.rest)
    if status is None:
        return None
    return Response({"message": "stub: refused", "statusCode": status}, status=status)


MEMORY = "dddddddd-4444-4444-8444-000000000001"
MEMORY_AT = "2022-07-01T00:00:00.000Z"


@router.get("/api/memories")
def memories(req):
    return Response([{
        "id": MEMORY,
        "createdAt": MEMORY_AT, "updatedAt": MEMORY_AT,
        "memoryAt": MEMORY_AT, "ownerId": ME, "type": "on_this_day",
        "data": {"year": 2022},
        "assets": [asset(aid) for aid in TIMELINE_ASSETS[:2]],
        "isSaved": False,
        "showAt": None, "hideAt": None, "seenAt": None, "deletedAt": None,
    }])


@router.get("/api/memories/statistics")
def memories_statistics(req):
    return Response({"total": 1})


@router.post("/api/assets/bulk-upload-check")
def bulk_upload_check(req):
    """Every asked id is a duplicate of a shell photo: the pass checks, never uploads."""
    items = req.body.get("assets", []) if isinstance(req.body, dict) else []
    req.note(checked=len(items))
    return Response({"results": [
        {"id": item.get("id"), "action": "reject", "reason": "duplicate",
         "assetId": TIMELINE_ASSETS[0], "isTrashed": False}
        for item in items
    ]})


if __name__ == "__main__":
    main(label="login")
