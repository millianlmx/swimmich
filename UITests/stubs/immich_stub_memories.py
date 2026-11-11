"""Immich API stub for the memories end-to-end scenario (UITests).

Committed on purpose: the stacks stub originally lived in /tmp, so a
`rm -rf /tmp/*` (or a reboot) silently destroyed the harness and only the test
comments remembered it existed. This one is self-contained — no sibling module
to import — and is run by hand before the XCUITest:

    python3 UITests/stubs/immich_stub_memories.py 8421
    xcodebuild test -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \\
        -destination 'platform=iOS Simulator,name=iPhone 17' \\
        -only-testing:ImmichSwiftUIUITests/ImmichRenderScreenshots/test_08_memories

It serves the OAuth handshake the app needs to reach the authenticated shell
(same shape as the shared-links stub) plus the memory routes, and enough of the
timeline to multi-select photos on the Photos tab. `GET /__reset` restores the
single initial memory; `GET /__reset?fixture=chain` (a birthday and two
"on this day" memories, served out of order) and `?fixture=types` (an unnamed
birthday and a memory of a type the app does not know) load the sets the
MemoriesChainUITests scenarios need. Five behaviours matter beyond "returns data":

* `GET /api/memories` drops memories that lost their last asset, which is what
  the real server's search does. The scenario deletes a memory's last asset and
  expects the card to disappear — a stub that keeps serving it would hide that.
* `POST /api/memories` validates like the server's Zod DTO (400 without
  `data`, `memoryAt` or `type`, and for any `type` other than `on_this_day`), so
  a malformed create is a hard failure instead of a silently stored row.
* the two `/api/memories/{id}/assets` routes answer `BulkIdResponseDto` — field
  `id`, NOT `assetId`. That distinction already bit the shared-link route
  (`AssetIdsResponseDto` there really is `assetId`); a wrong field decodes as an
  empty result rather than an error.
* `GET /__requests` exposes what the app actually sent — the scenario asserts
  on the wire (which `isSaved` value, which `assetIds`), not on a screenshot.
* thumbnails are a real generated 8×8 PNG, served `Cache-Control: no-store`.
  `AuthenticatedAsyncImage` needs bytes ImageIO can decode, and its session is
  `returnCacheDataElseLoad` — an undecodable fixture (what this file shipped
  first) turns every screenshot of a grid into broken images, and then survives
  its own fix on a warm simulator because the bad body is replayed from cache.
"""
import json
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8421
BASE = f"http://127.0.0.1:{PORT}"

ME = "11111111-1111-4111-8111-111111111111"
ALBUM = "22222222-2222-4222-8222-000000000002"

# The initial memory, with a fixed id so the scenario can address it directly.
MEMORY = "dddddddd-4444-4444-8444-000000000001"

# Eight library assets living in ONE 2024-07-01 bucket: enough photos for the
# scenario to multi-select on the Photos tab, then create a memory from them.
# The readable prefix makes a failure legible in a screenshot and in curl.
LIBRARY = [f"aaaaaaaa-1111-4111-8111-{i:012d}" for i in range(1, 9)]
BUCKET = "2024-07-01"

# A real 8×8 PNG, generated rather than pasted. `AuthenticatedAsyncImage` decodes
# the bytes with ImageIO and falls back to a failure placeholder when it cannot —
# the 1×1 JPEG this file used to embed (copied into the viewer stub too) was
# undecodable, so every screenshot of a grid showed broken images while the app
# was correct. Generated pixels also let each photo be told apart: the colour
# derives from the asset id, exactly like the real filenames do.
PALETTE = [(0x42, 0x50, 0xAF), (0xE0, 0x7A, 0x5F), (0x2E, 0x8B, 0x57),
           (0xC9, 0xA2, 0x27), (0x7A, 0x4F, 0x9E), (0x2A, 0x7C, 0x9E)]


def thumb(aid):
    r, g, b = PALETTE[sum(aid.encode()) % len(PALETTE)]
    size = 8
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


DEFAULT_TAKEN = "2024-07-01T10:00:00.000Z"


def asset(aid, taken=DEFAULT_TAKEN):
    """A library asset. Names are derived from the id so every photo is
    identifiable in a screenshot ('aaaa-01.jpg', 'aaaa-08.jpg', …)."""
    key = aid.replace("-", "")
    return {
        "id": aid, "type": "IMAGE", "thumbhash": THUMBHASH,
        "localDateTime": taken, "duration": None, "hasMetadata": True,
        "width": 4000, "height": 3000, "createdAt": taken,
        "ownerId": ME, "originalPath": f"/x/{key}.jpg",
        "originalFileName": f"{aid[:4]}-{aid[-2:]}.jpg",
        "fileCreatedAt": taken, "fileModifiedAt": taken,
        "updatedAt": "2024-07-01T10:00:00.000Z", "isFavorite": False, "isArchived": False,
        "isTrashed": False, "isOffline": False, "visibility": "timeline", "checksum": "abc",
        "isEdited": False,
    }


# Every parallel array of the bucket payload must have the same length:
# AssetReactItem.zip returns [] on a mismatch, which surfaces as an empty
# timeline rather than a visual glitch — an easy stub bug to mistake for an app
# bug.
RATIOS = [1.333, 1.0, 1.5, 0.75, 1.0, 1.0, 2.0, 0.6]


def bucket():
    """The 2024-07-01 timeline bucket: the eight library photos, unstacked."""
    ids = LIBRARY
    return {
        "id": ids,
        "ownerId": [ME] * len(ids),
        "ratio": [RATIOS[i % len(RATIOS)] for i in range(len(ids))],
        "isFavorite": [False] * len(ids),
        "visibility": ["timeline"] * len(ids),
        "isTrashed": [False] * len(ids),
        "isImage": [True] * len(ids),
        "thumbhash": [THUMBHASH] * len(ids),
        "createdAt": ["2024-07-01T10:00:00.000Z"] * len(ids),
        "fileCreatedAt": ["2024-07-01T10:00:00.000Z"] * len(ids),
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

ALBUM_DTO = {
    "id": ALBUM, "albumName": "Stub Album", "description": "",
    "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
    "albumThumbnailAssetId": None, "shared": False, "hasSharedLink": False,
    "assetCount": 0, "isActivityEnabled": False, "order": "desc", "albumUsers": [],
}

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

# Stamped on `updatedAt` by every mutation. Deterministic on purpose: the
# scenario can assert that a PUT moved the field without racing a clock.
TOUCHED_AT = "2026-09-13T00:00:00.000Z"


def memory_dto(memory_id, asset_ids, year, memory_at, is_saved=False, type="on_this_day", data=None, taken=None):
    """`taken` maps an asset id to the date it was taken (default: 2024-07-01)."""
    taken = taken or {}
    return {
        "id": memory_id,
        "createdAt": memory_at, "updatedAt": memory_at,
        "memoryAt": memory_at, "ownerId": ME, "type": type,
        "data": data if data is not None else {"year": year},
        "assets": [asset(aid, taken.get(aid, DEFAULT_TAKEN)) for aid in asset_ids],
        "isSaved": is_saved,
        "showAt": None, "hideAt": None, "seenAt": None, "deletedAt": None,
    }


# Fixture `chain`: a birthday and two "on this day" memories. The server serves
# them out of order on purpose: the app must sort by `memoryAt`, giving
# BIRTHDAY, OTD_2023, OTD_2022. The birth year (1990) is not a memory year.
BIRTHDAY = "eeeeeeee-5555-4555-8555-000000000001"
OTD_2023 = "eeeeeeee-5555-4555-8555-000000000002"
OTD_2022 = "eeeeeeee-5555-4555-8555-000000000003"


def chain_asset(n):
    return f"bbbbbbbb-2222-4222-8222-{n:012d}"


# Fixture `types`: an "on this day", a memory of an unknown type carrying extra
# `data` keys, and a birthday without `personName`.
TYPES_OTD = "ffffffff-6666-4666-8666-000000000001"
TYPES_TRIP = "ffffffff-6666-4666-8666-000000000002"
TYPES_UNNAMED_BIRTHDAY = "ffffffff-6666-4666-8666-000000000003"


def fixture_memories(fixture):
    """The memory set of a named fixture, or the single initial memory."""
    if fixture == "chain":
        return [
            memory_dto(OTD_2022, [chain_asset(4), chain_asset(5)], 2022, "2022-07-01T00:00:00.000Z",
                       taken={chain_asset(4): "2022-07-01T10:00:00.000Z", chain_asset(5): "2022-07-01T11:00:00.000Z"}),
            memory_dto(BIRTHDAY, [chain_asset(1), chain_asset(2)], 1990, "2026-07-01T00:00:00.000Z",
                       type="birthday",
                       data={"year": 1990, "personId": "cccccccc-7777-4777-8777-000000000001", "personName": "Alice"},
                       taken={chain_asset(1): "2020-07-01T10:00:00.000Z", chain_asset(2): "2021-07-01T10:00:00.000Z"}),
            memory_dto(OTD_2023, [chain_asset(3)], 2023, "2023-07-01T00:00:00.000Z",
                       taken={chain_asset(3): "2023-07-01T10:00:00.000Z"}),
        ]
    if fixture == "types":
        return [
            memory_dto(TYPES_OTD, [chain_asset(11), chain_asset(12)], 2023, "2023-07-01T00:00:00.000Z",
                       taken={chain_asset(11): "2023-07-01T10:00:00.000Z", chain_asset(12): "2023-07-01T11:00:00.000Z"}),
            memory_dto(TYPES_TRIP, [chain_asset(13), chain_asset(14)], 2021, "2021-07-01T00:00:00.000Z",
                       type="trip",
                       data={"year": 2021, "tripName": "Lisbon", "places": ["Lisbon"]},
                       taken={chain_asset(13): "2021-07-01T10:00:00.000Z", chain_asset(14): "2021-07-01T11:00:00.000Z"}),
            memory_dto(TYPES_UNNAMED_BIRTHDAY, [chain_asset(15)], 1985, "2026-07-02T00:00:00.000Z",
                       type="birthday",
                       data={"year": 1985, "personId": "cccccccc-7777-4777-8777-000000000002"},
                       taken={chain_asset(15): "2020-07-01T10:00:00.000Z"}),
        ]
    return [memory_dto(MEMORY, LIBRARY[:3], 2022, "2022-07-01T00:00:00.000Z")]


def bulk(ids):
    """`BulkIdResponseDto` — the field is `id`, not `assetId`."""
    return [{"id": aid, "success": True, "error": None, "errorMessage": None} for aid in ids]


def new_thumbhash():
    """A fresh `thumbhash` — the content fingerprint the fixtures advertise.

    Rotated on every `/__reset`, and that is not decoration: both of the app's
    image caches key on the URL (`ImageCache` in memory, `URLCache` on disk via
    `returnCacheDataElseLoad`), so a fixed value lets a body cached by an earlier
    run be replayed without any request leaving the app. That is exactly how the
    undecodable fixture this file shipped first survived its own fix — the tiles
    kept rendering broken while the stub was already serving valid PNGs. A real
    server's thumbhash changes whenever the pixels do; a stub whose pixels
    changed with the fix must change it too.
    """
    return "stub-%08d" % (int(time.time() * 1000) % 10**8)


# Module-level (not part of STATE): `asset()` reads it while `initial_state()`
# builds the very state that would hold it.
THUMBHASH = new_thumbhash()


def initial_state(fixture=None):
    return {
        # `fixture_memories(None)`: one "on this day" memory over the first three
        # library photos.
        "memories": fixture_memories(fixture),
        "provider": "manual",
        "requests": [],
        # Starts at 2: suffix 1 is the fixed id of the initial memory above, and
        # a generated id must never collide with it.
        "next_memory": 2,
    }


STATE = initial_state()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("stub %s\n" % (fmt % args))

    def _send(self, payload, status=200, ctype="application/json", headers=None):
        body = payload if isinstance(payload, bytes) else (
            payload.encode() if ctype.startswith("text/") else json.dumps(payload).encode()
        )
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}") if length else {}

    def _log(self, entry):
        STATE["requests"].append(entry)

    def _memory(self, memory_id):
        for memory in STATE["memories"]:
            if memory["id"] == memory_id:
                return memory
        return None

    def _not_found(self, path):
        self._send({"error": "not found", "path": path}, status=404)

    # MARK: - GET

    def do_GET(self):
        path = self.path.split("?")[0]
        query = self.path.split("?")[1] if "?" in self.path else ""

        if path == "/__reset":
            global THUMBHASH
            fixture = query.split("fixture=")[1].split("&")[0] if "fixture=" in query else None
            if fixture not in (None, "chain", "types"):
                return self._send({"error": "unknown fixture", "fixture": fixture}, status=400)
            THUMBHASH = new_thumbhash()
            STATE.update(initial_state(fixture))
            return self._send({"reset": True, "fixture": fixture} if fixture else {"reset": True})
        if path == "/__provider":
            STATE["provider"] = "auto" if "auto" in query else "manual"
            return self._send({"provider": STATE["provider"]})
        if path == "/__requests":
            return self._send(STATE["requests"])
        if path == "/provider-manual":
            return self._send(PROVIDER_HTML, ctype="text/html; charset=utf-8")
        if path == "/provider-auto":
            return self._send(AUTO_HTML, ctype="text/html; charset=utf-8")

        if path == "/api/memories":
            self._log({"method": "GET", "path": path, "query": query})
            # The server's search drops a memory once it has no asset left.
            return self._send([m for m in STATE["memories"] if m["assets"]])
        # Must be matched BEFORE the `{id}` route: it is not a memory id.
        if path == "/api/memories/statistics":
            live = [m for m in STATE["memories"] if m["assets"]]
            return self._send({"total": len(live)})
        if path.startswith("/api/memories/"):
            memory_id = path[len("/api/memories/"):].split("/")[0]
            memory = self._memory(memory_id)
            if memory is None:
                return self._not_found(path)
            return self._send(memory)

        if path == "/api/timeline/buckets":
            return self._send([{"timeBucket": BUCKET, "count": len(LIBRARY)}])
        if path == "/api/timeline/bucket":
            return self._send(bucket())
        if path.startswith("/api/assets/") and path.endswith("/thumbnail"):
            # `no-store` because the app's image session is
            # `returnCacheDataElseLoad`: a body cached under this URL is replayed
            # without asking, so the previous undecodable fixture would survive
            # the fix on a warm simulator and keep the screenshots broken.
            return self._send(
                thumb(path.split("/")[3]),
                ctype="image/png",
                headers={"Cache-Control": "no-store"},
            )

        routes = {
            "/api/server/ping": {"res": "pong"},
            "/api/server/version": {"major": 1, "minor": 119, "patch": 0, "prerelease": None},
            "/api/server/config": CONFIG,
            "/api/users/me": ME_USER,
            "/api/users": [ME_USER],
            "/api/albums": [ALBUM_DTO],
            "/api/partners": [],
            "/api/activities": [],
            "/api/notifications": [],
            "/api/stacks": [],
            "/api/tags": [],
        }
        if path in routes:
            return self._send(routes[path])
        if path.startswith("/api/"):
            # `/api/search/...` and friends: an empty page rather than a 404.
            return self._send([])
        self._not_found(path)

    # MARK: - POST

    def do_POST(self):
        path = self.path.split("?")[0]
        body = self._body()

        if path == "/api/oauth/authorize":
            return self._send({"url": f"{BASE}/provider-manual" if STATE["provider"] == "manual"
                               else f"{BASE}/provider-auto"})
        if path == "/api/oauth/callback":
            return self._send({
                "accessToken": "stub-access-token", "userId": ME, "userEmail": ME_USER["email"],
                "name": ME_USER["name"], "isAdmin": False, "profileImagePath": "",
                "shouldChangePassword": False, "isOnboarded": True,
            })
        if path == "/api/auth/logout":
            return self._send({"successful": True})

        if path == "/api/memories":
            self._log({
                "method": "POST", "path": path,
                "assetIds": body.get("assetIds"), "memoryAt": body.get("memoryAt"),
                "type": body.get("type"), "data": body.get("data"),
                "isSaved": body.get("isSaved"),
            })
            # `MemoryCreateDto` on the server: data, memoryAt and type are
            # required, and "on_this_day" is the only type this client creates.
            missing = [f for f in ("data", "memoryAt", "type") if body.get(f) is None]
            if missing:
                return self._send(
                    {"error": "Bad Request", "message": [f"{f} is required" for f in missing]},
                    status=400,
                )
            if body["type"] != "on_this_day":
                return self._send(
                    {"error": "Bad Request", "message": ["type must be on_this_day"]},
                    status=400,
                )
            # `MemoryDataDto.year` is a non-optional Int in the app, so a memory
            # stored without one would break the next `GET /api/memories`.
            if not isinstance(body["data"], dict) or not isinstance(body["data"].get("year"), int):
                return self._send(
                    {"error": "Bad Request", "message": ["data.year must be a number"]},
                    status=400,
                )
            memory_id = "dddddddd-4444-4444-8444-%012d" % STATE["next_memory"]
            STATE["next_memory"] += 1
            # `assetIds` may repeat or name an asset this stub never served:
            # dedup keeps the app's order, `asset()` synthesises the rest.
            created = memory_dto(
                memory_id,
                list(dict.fromkeys(body.get("assetIds") or [])),
                body["data"].get("year") if isinstance(body["data"], dict) else None,
                body["memoryAt"],
                body.get("isSaved", False),
            )
            STATE["memories"].append(created)
            return self._send(created, status=201)

        if path == "/api/search/metadata":
            # The sheets' picker pages through this route, so it must serve the
            # library — an empty page would leave both create flows with nothing
            # to select and no way to reach the memory routes.
            return self._send({
                "assets": {"count": len(LIBRARY), "items": [asset(aid) for aid in LIBRARY], "nextPage": None},
            })

        if path.startswith("/api/"):
            return self._send({"successful": True})
        self._not_found(path)

    # MARK: - PUT / DELETE

    def do_PUT(self):
        path = self.path.split("?")[0]
        body = self._body()
        # Logged flat (not as a nested `body`) so the scenario's Decodable can
        # read every request with one shape.
        self._log({
            "method": "PUT", "path": path,
            "isSaved": body.get("isSaved"), "ids": body.get("ids"),
        })

        memory = self._addressed(path)
        if memory is None:
            return self._not_found(path)
        if path.endswith("/assets"):
            memory["assets"] = self._with_assets(memory["assets"], body.get("ids") or [])
        else:
            for field in ("isSaved", "memoryAt", "seenAt"):
                if field in body:
                    memory[field] = body[field]
        memory["updatedAt"] = TOUCHED_AT
        if path.endswith("/assets"):
            return self._send(bulk(body.get("ids") or []))
        self._send(memory)

    def do_DELETE(self):
        path = self.path.split("?")[0]
        # This route carries a JSON body on DELETE, so it must be read here.
        body = self._body()
        self._log({
            "method": "DELETE", "path": path,
            "isSaved": body.get("isSaved"), "ids": body.get("ids"),
        })

        memory = self._addressed(path)
        if memory is None:
            return self._not_found(path)
        if path.endswith("/assets"):
            gone = set(body.get("ids") or [])
            memory["assets"] = [a for a in memory["assets"] if a["id"] not in gone]
            memory["updatedAt"] = TOUCHED_AT
            # `DELETE …/assets` answers the bulk result, not 204.
            return self._send(bulk(body.get("ids") or []))
        STATE["memories"] = [m for m in STATE["memories"] if m is not memory]
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def _addressed(self, path):
        """The memory a `/api/memories/{id}[/assets]` path points at, or None."""
        if not path.startswith("/api/memories/"):
            return None
        return self._memory(path[len("/api/memories/"):].split("/")[0])

    def _with_assets(self, assets, ids):
        """Union of the memory's assets and `ids`, order preserved."""
        seen = {a["id"] for a in assets}
        merged = list(assets)
        for aid in ids:
            if aid not in seen:
                seen.add(aid)
                merged.append(asset(aid))
        return merged


if __name__ == "__main__":
    print(json.dumps({
        "port": PORT,
        "memory": MEMORY,
        "library": len(LIBRARY),
        "fixtures": ["(none: one initial memory)", "chain", "types"],
        "endpoints": [
            "/api/memories", "/api/memories/statistics", "/api/memories/{id}",
            "/api/memories/{id}/assets", "/api/timeline/buckets", "/api/timeline/bucket",
            "/api/assets/{id}/thumbnail", "/__reset[?fixture=chain|types]", "/__provider", "/__requests",
        ],
    }))
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
