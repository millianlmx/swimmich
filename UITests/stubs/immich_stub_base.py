"""Shared shell of the committed XCUITest stubs (`UITests/stubs/*.py`).

WHAT THIS SERVES
    The half of an Immich stub that every end-to-end scenario needs and none of
    them owns: the OAuth handshake that walks the real app from onboarding to
    the authenticated shell (`/api/oauth/authorize` → a provider page →
    `/api/oauth/callback`), the server configuration and version it reads on the
    way, the current user, one day of timeline (`/api/timeline/buckets` +
    `/api/timeline/bucket`), the asset routes (`/api/assets/{id}`, `/thumbnail`,
    `/original`) with REAL image bytes, and the introspection routes
    (`/__requests`, `/__reset`, `/__provider`, `/__whoami`) the scenarios assert
    against.

WHY `/__whoami` EXISTS
    A launcher that started a stub on a port can end up talking to someone
    else's server: an orphaned stub from an earlier session answers
    `/api/server/ping` exactly as happily, and a scenario served by the WRONG
    stub is a false green (measured: a two-hour-old `immich_stub_offline.py`
    squatting a slot port kept the timeline rendering with another feature's
    photos). `/__whoami` answers `{port, pid, stub}`; `.omp/orchestration/uitest.sh`
    refuses to run unless the port matches the one it asked for.

WHAT THIS IS NOT
    Not a feature. No `/api/memories`, `/api/albums`, `/api/stacks`, `/api/search`
    route lives here — a stub that added one would silently answer another
    scenario's requests. A feature declares its own routes (below), and an
    unrouted `/api/…` read answers `[]` so the app's unrelated list screens keep
    rendering.

HOW A FEATURE STUB USES IT (copy this skeleton)

    # UITests/stubs/immich_stub_<feature>.py
    from immich_stub_base import Response, STATE, router, main

    @router.get("/api/things")
    def list_things(req):
        return Response([{"id": "t1"}])

    @router.post("/api/things")
    def create_thing(req):
        req.note(name=req.body.get("name"))   # lands in /__requests
        return Response({"id": "t2"}, status=201)

    # A path with a variable tail: `router.prefix`, then read `req.rest`.
    # (An exact path never falls back to a prefix: `GET /api/memories/statistics`
    # therefore wins over `prefix("GET", "/api/memories/")` without ordering them.)
    @router.prefix("PUT", "/api/things/")
    def update_thing(req):
        return Response({"id": req.rest.split("/")[0]})

    @router.reset
    def fresh():
        STATE["things"] = []

    if __name__ == "__main__":
        main(label="things")

    Routes are consulted BEFORE the shell's own, in registration order, and the
    first handler that returns a `Response` wins. Returning `None` falls through
    to the next route and finally to the shell — that is how a feature answers
    only the shape it cares about (see `immich_stub_recent.py`, which answers the
    two ordered bucket lists and leaves the plain timeline to the shell).

WHY IT IS COMMITTED
    The first stub of this harness lived in /tmp and a `rm -rf /tmp/*` destroyed
    it; only the test comments remembered it existed. Everything a scenario needs
    is in the repository: `python3 UITests/stubs/immich_stub_<feature>.py 8421`.

THE THUMBNAIL TRAP (already paid for twice)
    `png()` generates real 8×8 PNG bytes and NOTHING here may replace it with a
    hand-written literal. `AuthenticatedAsyncImage` decodes the body with
    ImageIO: an undecodable fixture (a pasted 1×1 JPEG) does not fail the app —
    it turns every screenshot of a grid into broken tiles while the app itself is
    correct. Worse, it survives its own fix: both image caches key on the URL
    (`ImageCache` in memory, `URLCache` on disk, the session is
    `returnCacheDataElseLoad`), so a warm simulator keeps replaying the bad body
    and the stub looks broken. Hence two rules: the bytes are generated
    (`png()`), served `Cache-Control: no-store`, and `STATE["thumbhash"]` is
    rotated by `/__reset` so a stale body can never be replayed across runs.

WHAT IS LOGGED
    Every non-`/__*` request, as
    `{"method": …, "path": …, "params": {name: value}, "body": {…}}`.
    `/__requests` serves that list, which is what a scenario asserts on:
    `req.note(**fields)` adds feature-specific fields to the entry (a POST's
    `assetIds`, a PUT's `isSaved`). A duplicated query parameter keeps its LAST
    value, and a blank one is kept as `""` so `orderBy=` is distinguishable from
    an absent `orderBy`.

WHICH VERSION IT ANNOUNCES, AND WHAT IT SERVES (L-20)
    `IMMICH_STUB_VERSION` (default 1.119.0) is the version `GET /api/server/version`
    answers; a feature stub that overrides that route is followed by
    `announced_version()`. `ROUTE_TABLE` lists the replacement routes with the
    version that introduced them (upstream OpenAPI `x-immich-history`): a request
    for one of them below that version answers 404 `Cannot <METHOD> <path>` —
    and stays in `/__requests`, so a scenario can prove it never happened. The
    shell serves both route families (`/api/jobs` and `/api/queues`,
    `POST /api/people/{id}/merge` and `POST /api/people/merge`,
    `GET /api/server/config` and `GET /api/public/config` + `GET /api/config`).
"""
import json
import os
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl

# MARK: - Fixtures

ME = "11111111-1111-4111-8111-111111111111"

# The ordinary timeline: ONE day, six photos — a screenful, and enough for a
# scenario to open the viewer or multi-select. A feature that needs other days
# (or another sort axis) answers `/api/timeline/buckets` itself; the six ids are
# recognisable on purpose so a wrong payload is legible in a screenshot.
TIMELINE_DAY = "2026-09-01"
TIMELINE_ASSETS = [f"aaaaaaaa-1111-4111-8111-{i:012d}" for i in range(1, 7)]

# The colour of a photo derives from its id, exactly like a real thumbnail
# derives from its pixels: two tiles in one screenshot are never ambiguous.
PALETTE = [(0x42, 0x50, 0xAF), (0xE0, 0x7A, 0x5F), (0x2E, 0x8B, 0x57),
           (0xC9, 0xA2, 0x27), (0x7A, 0x4F, 0x9E), (0x2A, 0x7C, 0x9E)]

# Every parallel array of a bucket payload must be the same length: AssetReactItem.zip
# returns [] on a mismatch, which shows up as an EMPTY TIMELINE rather than a
# visual glitch — an easy stub bug to mistake for an app bug.
RATIOS = [1.333, 1.0, 1.5, 0.75, 1.0, 1.0, 2.0, 0.6]

ME_USER = {
    "id": ME, "name": "Stub User", "email": "stub@example.com",
    "profileImagePath": "", "avatarColor": "primary",
    "profileChangedAt": "2026-01-01T00:00:00.000Z",
    "isAdmin": False, "shouldChangePassword": False,
    "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
    "deletedAt": None, "status": "active",
    "quotaSizeInBytes": 107374182400, "quotaUsageInBytes": 21474836480,
    "storageLabel": None, "oauthId": "",
}

CONFIG = {
    "oauthButtonText": "Continue with Immich SSO",
    "loginPageMessage": "Stub server for UI verification",
    "trashDays": 30, "userDeleteDelay": 7,
    "isInitialized": True, "isOnboarded": True,
    "externalDomain": "", "publicUsers": False,
    "mapDarkStyleUrl": "", "mapLightStyleUrl": "",
    "maintenanceMode": False, "minFaces": 0,
}

LOGIN = {
    "accessToken": "stub-access-token", "userId": ME, "userEmail": ME_USER["email"],
    "name": ME_USER["name"], "isAdmin": False, "profileImagePath": "",
    "shouldChangePassword": False, "isOnboarded": True,
}

# `GET /api/server/statistics` — the instance totals, read by the Administration
# screen only (without a route the shell's `[]` decodes into nothing there).
# Kept for that screen: the Me hub, Media Stats and "On this device" read
# `ASSET_STATS` and `/api/users/me` instead.
STATS = {
    "photos": 128, "videos": 7,
    "usage": 3221225472, "usagePhotos": 2684354560, "usageVideos": 536870912,
    "usageByUser": [{
        "userId": ME, "userName": ME_USER["name"], "photos": 128, "videos": 7,
        "usage": 3221225472, "usagePhotos": 2684354560, "usageVideos": 536870912,
        "quotaSizeInBytes": ME_USER["quotaSizeInBytes"],
    }],
}

# `GET /api/assets/statistics` — the calling account's own counts. `total` exceeds
# `images + videos` on purpose (audio and other media): a screen that displayed it
# would give itself away.
ASSET_STATS = {"images": 128, "videos": 7, "total": 140}

PROVIDER_HTML = """<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Stub Identity Provider</title>
<style>
 body{font:16px -apple-system,sans-serif;margin:0;display:flex;align-items:center;
      justify-content:center;height:100vh;background:#f2f2f7;}
 .card{background:#fff;border-radius:18px;padding:28px;text-align:center;
       box-shadow:0 10px 40px rgba(0,0,0,.12);max-width:320px;}
 h1{font-size:20px;margin:0 0 6px;}p{color:#6b7280;margin:0 0 20px;font-size:14px;}
 a{display:block;background:#4250af;color:#fff;text-decoration:none;
   padding:14px;border-radius:12px;font-weight:600;}
</style></head>
<body><div class="card">
  <h1>Stub Identity Provider</h1>
  <p>Signing in as stub@example.com</p>
  <a id="authorize" href="app.immich:///oauth-callback?code=stub-code&amp;state=stub-state">Authorize</a>
</div></body></html>
"""

AUTO_HTML = """<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Stub Identity Provider</title></head>
<body style="font:16px -apple-system,sans-serif;text-align:center;padding-top:120px">
<p>Signing in as stub@example.com…</p>
<script>window.location = "app.immich:///oauth-callback?code=stub-code&state=stub-state";</script>
</body></html>
"""

# MARK: - Payload builders


def png(fingerprint, size=8):
    """A real, decodable PNG whose colour derives from `fingerprint`.

    Generated, never pasted: see THE THUMBNAIL TRAP in the module docstring.
    `size=8` is the thumbnail the grids ask for; `/original` streams a larger
    one so a downloaded file is visibly a photo and not an 8-pixel dot.
    """
    r, g, b = PALETTE[sum(fingerprint.encode()) % len(PALETTE)]
    raw = b"".join(b"\x00" + bytes((r, g, b)) * size for _ in range(size))

    def chunk(kind, data):
        payload = kind + data
        return (len(data).to_bytes(4, "big") + payload
                + (zlib.crc32(payload) & 0xFFFFFFFF).to_bytes(4, "big"))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", size.to_bytes(4, "big") + size.to_bytes(4, "big")
                    + bytes((8, 2, 0, 0, 0)))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


def new_thumbhash():
    """The content fingerprint the fixtures advertise. Rotated by `/__reset`.

    Not decoration: it is what invalidates the app's two image caches (both key
    on the URL) between two runs of a scenario on the same warm simulator.
    """
    return "stub-%08d" % (int(time.time() * 1000) % 10**8)


def asset(aid, day=TIMELINE_DAY):
    """The full `AssetResponseDto` of an asset taken on `day`.

    `exifInfo.fileSizeInByte` is deliberately realistic: it is the number the
    offline store checks against its cache budget, so omitting it would silently
    disable that gate in a download scenario. The timeline's columnar payload
    does not carry either field — a scenario that needs them refetches
    `/api/assets/{id}`, which is the real app's behaviour too.
    """
    stamp = f"{day}T10:00:00.000Z"
    return {
        "id": aid, "type": "IMAGE", "thumbhash": STATE["thumbhash"],
        "localDateTime": stamp, "duration": None, "hasMetadata": True,
        "width": 4000, "height": 3000, "createdAt": stamp,
        "ownerId": ME, "originalPath": f"/x/{aid}.png",
        "originalFileName": f"{aid[:4]}-{aid[-2:]}.jpg",
        "fileCreatedAt": stamp, "fileModifiedAt": stamp,
        "updatedAt": stamp, "isFavorite": False, "isArchived": False,
        "isTrashed": False, "isOffline": False, "visibility": "timeline", "checksum": "abc",
        "isEdited": False,
        "exifInfo": {
            "make": "Stub", "model": "Stub", "exifImageWidth": 4000, "exifImageHeight": 3000,
            "fileSizeInByte": 2048, "orientation": "1", "dateTimeOriginal": stamp,
            "modifyDate": stamp, "timeZone": "UTC", "lensModel": None,
        },
    }


def bucket_payload(ids, day=TIMELINE_DAY):
    """`GET /api/timeline/bucket` — the columnar day payload.

    Columnar, not a list of DTOs: the app zips these arrays by index, so every
    one of them must have exactly `len(ids)` entries (see RATIOS above).
    """
    stamp = f"{day}T10:00:00.000Z"
    return {
        "id": ids,
        "ownerId": [ME] * len(ids),
        "ratio": [RATIOS[i % len(RATIOS)] for i in range(len(ids))],
        "isFavorite": [False] * len(ids),
        "visibility": ["timeline"] * len(ids),
        "isTrashed": [False] * len(ids),
        "isImage": [True] * len(ids),
        "thumbhash": [STATE["thumbhash"]] * len(ids),
        "createdAt": [stamp] * len(ids),
        "fileCreatedAt": [stamp] * len(ids),
        "localOffsetHours": [0.0] * len(ids),
        "duration": [None] * len(ids),
        "livePhotoVideoId": [None] * len(ids),
        "projectionType": [None] * len(ids),
        "stack": [None] * len(ids),
        "city": [None] * len(ids),
        "country": [None] * len(ids),
        "latitude": [None] * len(ids),
        "longitude": [None] * len(ids),
    }


def bulk(ids):
    """`BulkIdResponseDto` for a mutation that answered one per id.

    The field is `id`, NOT `assetId` — and a wrong field decodes as an empty
    result rather than as an error, which is how the shared-link route already
    bit this harness once (`AssetIdsResponseDto` there really is `assetId`).
    """
    return [{"id": aid, "success": True, "error": None, "errorMessage": None} for aid in ids]


# MARK: - Routes


class Response:
    """What a route returns. `payload` is JSON unless `ctype` says otherwise
    (`bytes` go out verbatim; a `str` is only ever used with a `text/*` ctype)."""

    __slots__ = ("payload", "status", "ctype", "headers")

    def __init__(self, payload, status=200, ctype="application/json", headers=None):
        self.payload = payload
        self.status = status
        self.ctype = ctype
        self.headers = headers or {}


class Request:
    """One decoded request, handed to a route handler."""

    __slots__ = ("method", "path", "query", "params", "headers", "body", "rest", "extra")

    def __init__(self, method, path, query, headers, body):
        self.method = method
        self.path = path
        self.query = query
        # Last value wins on a duplicate, and a blank value is kept (`orderBy=`
        # is observable). The Host header is what the OAuth redirect is built on.
        self.params = dict(parse_qsl(query, keep_blank_values=True))
        self.headers = headers
        self.body = body
        # Set by the router for a prefix route: the path after the prefix.
        self.rest = ""
        self.extra = {}

    @property
    def host(self):
        """`127.0.0.1:<port>` as the app addressed this stub — the provider URL
        the OAuth route hands back must be absolute, and the port is per slot."""
        return self.headers.get("Host") or f"127.0.0.1:{STATE['port']}"

    def note(self, **fields):
        """Attach fields to this request's `/__requests` entry: what a scenario
        asserts on is the wire, and a feature's payload shape (`assetIds`,
        `isSaved`) is not derivable from `path` alone."""
        self.extra.update(fields)


class Router:
    """The routes of one feature stub, matched before the shell's own.

    An EXACT path is looked up first — so `GET /api/memories/statistics` can
    never be swallowed by a `{id}` prefix route — then the prefixes, in
    registration order. A handler returns a `Response`, or `None` to fall through
    to the next route and eventually to the shell: the seam that lets a feature
    answer part of a route and delegate the rest.
    """

    def __init__(self):
        self._exact = {}
        self._prefixed = []
        self.resets = []

    def get(self, path):
        return self._register("GET", path)

    def post(self, path):
        return self._register("POST", path)

    def put(self, path):
        return self._register("PUT", path)

    def patch(self, path):
        return self._register("PATCH", path)

    def delete(self, path):
        return self._register("DELETE", path)

    def prefix(self, method, path):
        """A route for every path that starts with `path` (handlers read
        `req.rest` for the tail, e.g. an id)."""
        return self._register(method, path, prefixed=True)

    def reset(self, hook):
        """Register a state restorer run by `/__reset`, AFTER the shell wiped
        `STATE` — a scenario must never depend on a previous run's leftovers."""
        self.resets.append(hook)
        return hook

    def _register(self, method, path, prefixed=False):
        def decorator(handler):
            if prefixed:
                self._prefixed.append((method, path, handler))
            else:
                self._exact[(method, path)] = handler
            return handler
        return decorator

    def handle(self, request):
        handler = self._exact.get((request.method, request.path))
        if handler is None:
            for method, prefix, candidate in self._prefixed:
                if method == request.method and request.path.startswith(prefix):
                    request.rest = request.path[len(prefix):]
                    handler = candidate
                    break
        return None if handler is None else handler(request)

    def endpoints(self):
        return ([f"{method} {path}" for method, path in self._exact]
                + [f"{method} {path}*" for method, path, _ in self._prefixed])

# The one router of this process: a stub declares its routes on it at import
# time and the handler consults it on every request.
router = Router()


@router.get("/api/assets/statistics")
def asset_statistics(req):
    """The account's own counts (Me hub, Media Stats, On this device).

    On the ROUTER, not in `_shell`: the exact path is consulted before any
    `prefix("GET", "/api/assets/")` of a feature stub, and before the shell's
    `GET /api/assets/<x>` fallback, which would read `statistics` as an asset id
    and answer an `AssetResponseDto`. A feature stub overrides it by registering
    the same exact path."""
    return Response(ASSET_STATS)


# MARK: - Announced version and route table (L-20)

SERVER_VERSION = os.environ.get("IMMICH_STUB_VERSION", "1.119.0")

# (method, path pattern, first version that serves it). `{name}` is one segment.
# Routes that exist in every supported version are not listed: they are served.
ROUTE_TABLE = [
    ("GET", "/api/queues", (2, 4, 0)),
    ("GET", "/api/queues/{name}", (2, 4, 0)),
    ("PUT", "/api/queues/{name}", (2, 4, 0)),
    ("GET", "/api/queues/{name}/jobs", (2, 4, 0)),
    ("DELETE", "/api/queues/{name}/jobs", (2, 4, 0)),
    ("GET", "/api/public/config", (3, 2, 0)),
    ("GET", "/api/config", (3, 2, 0)),
    ("POST", "/api/people/merge", (3, 2, 1)),
]


def parse_version(text):
    """`"3.4.0"` → `(3, 4, 0)`, None when it is not three integers."""
    try:
        major, minor, patch = (int(part) for part in text.split("."))
    except (AttributeError, ValueError):
        return None
    return (major, minor, patch)


def announced_version(request):
    """The `(major, minor, patch)` this process announces to `request`, None when
    its version route is broken (5xx, unreadable body).

    Asks the router first, exactly as the app's own `GET /api/server/version`
    would be answered (same headers, not journaled), so a feature stub that
    overrides the route — per host, per control route — is obeyed. `router` and
    `SERVER_VERSION` are read as module globals at every call.
    """
    probe = Request("GET", "/api/server/version", "", request.headers, {})
    response = router.handle(probe)
    if response is None:
        return parse_version(SERVER_VERSION)
    if response.status >= 400 or not isinstance(response.payload, dict):
        return None
    try:
        return (int(response.payload["major"]), int(response.payload["minor"]),
                int(response.payload["patch"]))
    except (KeyError, TypeError, ValueError):
        return None


def version_payload():
    """The body of `GET /api/server/version` for `SERVER_VERSION`."""
    major, minor, patch = parse_version(SERVER_VERSION) or (1, 119, 0)
    return {"major": major, "minor": minor, "patch": patch, "prerelease": None}


def _matches(pattern, path):
    want, got = pattern.split("/"), path.split("/")
    return len(want) == len(got) and all(
        w == g or (w.startswith("{") and g != "") for w, g in zip(want, got))


def serves(method, path, version):
    """Whether a server of `version` has this route. A route the table does not
    list is served by every version; a listed one needs a known version that is
    at least its threshold."""
    for table_method, pattern, minimum in ROUTE_TABLE:
        if table_method == method and _matches(pattern, path):
            return version is not None and tuple(version) >= minimum
    return True


def public_config_payload(config):
    """`GET /api/public/config` (v3.2.0+) from a `CONFIG`-shaped dict."""
    return {
        "oauth": {"enabled": True, "autoLaunch": False, "buttonText": config["oauthButtonText"]},
        "passwordLogin": {"enabled": True},
        "server": {"loginPageMessage": config.get("loginPageMessage", "")},
    }


def user_config_payload(config):
    """`GET /api/config` (v3.2.0+, authenticated) from a `CONFIG`-shaped dict."""
    return {
        "oauth": {"enabled": True, "autoLaunch": False, "buttonText": config["oauthButtonText"],
                  "accountManagementUrl": ""},
        "server": {"externalDomain": config.get("externalDomain", ""),
                   "loginPageMessage": config.get("loginPageMessage", ""),
                   "publicUsers": config.get("publicUsers", False)},
    }


BASE_ENDPOINTS = [
    "POST /api/oauth/authorize", "POST /api/oauth/callback", "POST /api/auth/logout",
    "GET /api/server/ping", "GET /api/server/version", "GET /api/server/config",
    "GET /api/public/config", "GET /api/config",
    "GET /api/server/statistics", "GET /api/assets/statistics",
    "GET /api/users/me", "GET /api/users",
    "GET /api/jobs", "PUT /api/jobs/{name}", "GET /api/queues", "PUT /api/queues/{name}",
    "DELETE /api/queues/{name}/jobs",
    "POST /api/people/{id}/merge", "POST /api/people/merge",
    "GET /api/timeline/buckets", "GET /api/timeline/bucket",
    "GET /api/assets/{id}", "GET /api/assets/{id}/thumbnail", "GET /api/assets/{id}/original",
    "GET /__requests", "GET /__reset", "GET /__provider", "GET /__whoami",
]


def initial_state():
    return {
        "port": 8421,
        "provider": "manual",
        "requests": [],
        # The job queues both route families read and write.
        "queues": {"thumbnailGeneration": {
            "isPaused": False,
            "statistics": {"active": 0, "completed": 12, "delayed": 0,
                           "failed": 0, "paused": 0, "waiting": 3},
        }},
        # Rotated by every `/__reset`; `asset()` and `bucket_payload()` read it,
        # and the app's image caches key on it. See THE THUMBNAIL TRAP.
        "thumbhash": new_thumbhash(),
    }


# `STATE` is mutated in place on reset (never rebound) so a feature stub that
# imported it keeps reading the live dict.
STATE = initial_state()


def _reset():
    STATE.clear()
    STATE.update(initial_state())
    for hook in router.resets:
        hook()


def _not_found(path):
    return Response({"error": "not found", "path": path}, status=404)


def _unrouted(method, path):
    """An unrouted `/api/…`: an empty page for a read, an acknowledgement for a
    write, like every stub of this harness. Consequence to know: a typo in a
    feature route reads as an EMPTY SCREEN, not as a 404 — when a route seems
    silent, read `/__requests` (a request that got there leaves a log entry) and
    the endpoint list `main()` prints."""
    if not path.startswith("/api/"):
        return _not_found(path)
    return Response([] if method == "GET" else {"successful": True})


def _queue_dto(name, queue):
    return {"name": name, "isPaused": queue["isPaused"], "statistics": dict(queue["statistics"])}


def _legacy_queue(queue):
    """`mapQueueLegacy`: active when a job runs, the statistics as `jobCounts`."""
    return {"queueStatus": {"isActive": queue["statistics"]["active"] > 0,
                            "isPaused": queue["isPaused"]},
            "jobCounts": dict(queue["statistics"])}


def _bad_request(message):
    return Response({"message": message, "statusCode": 400}, status=400)


def _served_config(request):
    """The `CONFIG`-shaped dict this process answers on `GET /api/server/config`.

    Asks the router first, like `announced_version()`, so a feature stub that
    overrides the legacy route (a long SSO label, say) gets the same values on
    `/api/public/config` and `/api/config` when it announces v3.2.0 or later.
    Keys the override leaves out keep the shell's values.
    """
    probe = Request("GET", "/api/server/config", "", request.headers, {})
    response = router.handle(probe)
    if response is None or response.status >= 400 or not isinstance(response.payload, dict):
        return CONFIG
    return {**CONFIG, **response.payload}



def _route_shell(method, request):
    """The routes whose family changed across versions: jobs and queues, the two
    person merges, the three configs. Both families are always served here;
    `serves()` (in `_dispatch`) is what refuses a route to an older server."""
    path = request.path
    parts = path.split("/")
    queues = STATE["queues"]

    if method == "GET":
        if path == "/api/jobs":
            return Response({name: _legacy_queue(queue) for name, queue in queues.items()})
        if path == "/api/queues":
            return Response([_queue_dto(name, queue) for name, queue in queues.items()])
        if path == "/api/public/config":
            return Response(public_config_payload(_served_config(request)))
        if path == "/api/config":
            return Response(user_config_payload(_served_config(request)))

    if method == "PUT" and len(parts) == 4 and parts[1:3] == ["api", "jobs"]:
        queue, command = queues.get(parts[3]), request.body.get("command")
        if queue is None:
            return _bad_request("Unknown queue")
        stats = queue["statistics"]
        if command == "pause":
            queue["isPaused"] = True
        elif command == "resume":
            queue["isPaused"] = False
        elif command == "empty":
            stats["waiting"] = stats["delayed"] = 0
        elif command == "clear-failed":
            stats["failed"] = 0
        elif command != "start":
            return _bad_request("Unknown command")
        return Response(_legacy_queue(queue))

    if method == "PUT" and len(parts) == 4 and parts[1:3] == ["api", "queues"]:
        queue, paused = queues.get(parts[3]), request.body.get("isPaused")
        if parts[3] == "backgroundTask" and paused is True:
            return _bad_request("The BackgroundTask queue cannot be paused")
        if queue is None:
            return _bad_request("Unknown queue")
        if isinstance(paused, bool):
            queue["isPaused"] = paused
        return Response(_queue_dto(parts[3], queue))

    if (method == "DELETE" and len(parts) == 5 and parts[1:3] == ["api", "queues"]
            and parts[4] == "jobs"):
        queue = queues.get(parts[3])
        if queue is None:
            return _bad_request("Unknown queue")
        stats = queue["statistics"]
        stats["waiting"] = stats["delayed"] = 0
        if request.body.get("failed") is True:
            stats["failed"] = 0
        return Response(b"", status=204)

    if method == "POST" and parts[1:3] == ["api", "people"]:
        ids = request.body.get("ids") or []
        if len(parts) == 4 and parts[3] == "merge":
            return Response([{"id": source, "success": True} for source in ids[1:]])
        if len(parts) == 5 and parts[4] == "merge":
            return Response([{"id": source, "success": True} for source in ids])
    return None


def _shell(method, request):
    """The shell's own routes: the authenticated boot, nothing feature-specific.

    `None` means "not mine" — the caller then answers `_unrouted`.
    """
    path = request.path

    versioned = _route_shell(method, request)
    if versioned is not None:
        return versioned

    if method == "POST":
        if path == "/api/oauth/authorize":
            return Response({"url": f"http://{request.host}/provider-{STATE['provider']}"})
        if path == "/api/oauth/callback":
            return Response(LOGIN)
        if path == "/api/auth/logout":
            return Response({"successful": True})

    if method == "GET":
        if path == "/api/server/ping":
            return Response({"res": "pong"})
        if path == "/api/server/version":
            return Response(version_payload())
        if path == "/api/server/config":
            return Response(CONFIG)
        if path == "/api/server/statistics":
            return Response(STATS)
        if path == "/api/users/me":
            return Response(ME_USER)
        if path == "/api/users":
            return Response([ME_USER])
        if path == "/api/timeline/buckets":
            return Response([{"timeBucket": TIMELINE_DAY, "count": len(TIMELINE_ASSETS)}])
        if path == "/api/timeline/bucket":
            return Response(bucket_payload(TIMELINE_ASSETS))

        parts = path.split("/")
        if len(parts) >= 4 and parts[1:3] == ["api", "assets"]:
            aid, tail = parts[3], parts[4] if len(parts) > 4 else ""
            if not tail:
                return Response(asset(aid))
            if tail == "thumbnail":
                # `no-store`: the app's image session is `returnCacheDataElseLoad`,
                # so a body cached under this URL would be replayed without asking.
                return Response(png(aid), ctype="image/png",
                                headers={"Cache-Control": "no-store"})
            if tail == "original":
                return Response(png(aid, size=64), ctype="application/octet-stream",
                                headers={"Cache-Control": "no-store"})

    return None


# MARK: - Server


class StubHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("stub %s\n" % (fmt % args))

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_PATCH(self):
        self._dispatch("PATCH")

    def do_DELETE(self):
        self._dispatch("DELETE")

    # MARK: - Dispatch

    def _dispatch(self, method):
        path, _, query = self.path.partition("?")
        if path.startswith("/__") or path.startswith("/provider-"):
            return self._send(self._control(path, query))
        request = Request(method, path, query, self.headers, self._body())
        entry = {"method": method, "path": path, "params": request.params, "body": request.body}
        STATE["requests"].append(entry)
        if not serves(method, path, announced_version(request)):
            return self._send(Response(
                {"message": f"Cannot {method} {path}", "statusCode": 404}, status=404))
        response = router.handle(request)
        if response is None:
            response = _shell(method, request)
        if response is None:
            response = _unrouted(method, path)
        # After the handler ran: `note()` is what it added about its own payload.
        entry.update(request.extra)
        self._send(response)

    def _control(self, path, query):
        """`/__reset`, `/__provider`, `/__requests`, `/__whoami` and the provider
        pages.

        Answered here, never by a feature route, and NOT logged: a scenario polls
        `/__requests` while asserting, and logging the poll would grow the log on
        every read. A feature that needs its own control route registers it like
        any other — it will simply be logged too.
        """
        params = dict(parse_qsl(query, keep_blank_values=True))
        if path == "/__reset":
            _reset()
            return Response({"reset": True})
        if path == "/__provider":
            mode = "auto" if (params.get("mode") == "auto" or "auto" in query) else "manual"
            STATE["provider"] = mode
            return Response({"provider": mode})
        if path == "/__requests":
            return Response(STATE["requests"])
        if path == "/__whoami":
            # Identity, not introspection: a launcher that started a stub on a
            # port can be talking to someone else's server — an orphan from an
            # earlier session answers `/api/server/ping` just as happily, and a
            # scenario served by the WRONG stub is a false green. The launcher
            # compares `port` with the one it asked for.
            return Response({
                "port": STATE["port"],
                "pid": os.getpid(),
                "stub": os.path.basename(sys.argv[0]),
            })
        if path == "/provider-manual":
            return Response(PROVIDER_HTML, ctype="text/html; charset=utf-8")
        if path == "/provider-auto":
            return Response(AUTO_HTML, ctype="text/html; charset=utf-8")
        return _not_found(path)

    def _body(self):
        """The request's JSON body, `{}` when there is none.

        Read for EVERY method: `DELETE` carries a JSON body on several Immich
        routes, so a handler that only parsed POST bodies would see `{}` there.
        """
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except ValueError:
            return {"raw": raw.decode("utf-8", "replace")}

    def _send(self, response):
        payload = response.payload
        if isinstance(payload, bytes):
            body = payload
        elif response.ctype.startswith("text/"):
            body = payload.encode()
        else:
            body = json.dumps(payload).encode()
        self.send_response(response.status)
        self.send_header("Content-Type", response.ctype)
        self.send_header("Content-Length", str(len(body)))
        for name, value in response.headers.items():
            self.send_header(name, value)
        # HTTP/1.1 with an explicit length and no keep-alive: one request per
        # connection, which is what the sibling stubs have always done.
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


def main(port=None, label="stub"):
    """Serve the shell plus the routes registered on `router`.

    `port` defaults to `sys.argv[1]` (how `.omp/orchestration/uitest.sh` and a
    by-hand run both pass it), else 8421. Blocks forever; a feature stub's
    epilogue is one line:

        if __name__ == "__main__":
            main(label="things")

    The startup line is the stub's contract, for a by-hand run: it lists every
    endpoint this process answers, shell first, feature routes after. `/__whoami`
    answers the same port, which is how the launcher proves it is talking to the
    stub IT started — hence the bind first, and only then the port on the record.
    """
    if port is None:
        port = int(sys.argv[1]) if len(sys.argv) > 1 else 8421
    server = ThreadingHTTPServer(("127.0.0.1", port), StubHandler)
    STATE["port"] = server.server_address[1]
    print(json.dumps({
        "port": STATE["port"],
        "label": label,
        "timeline_day": TIMELINE_DAY,
        "endpoints": BASE_ENDPOINTS + router.endpoints(),
    }))
    server.serve_forever()


if __name__ == "__main__":
    main(label="base")
