"""Immich API stub for the offline-download end-to-end scenario (UITests).

Committed on purpose, like the memories and shared-links stubs: the stacks stub
originally lived in /tmp, so a `rm -rf /tmp/*` silently destroyed the harness.

    python3 UITests/stubs/immich_stub_offline.py 8421
    xcodebuild test -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \\
        -destination 'platform=iOS Simulator,name=iPhone 17' \\
        -only-testing:ImmichSwiftUIUITests/ImmichRenderScreenshots/test_09_offlineDownload

It serves the OAuth handshake the app needs to reach the authenticated shell,
the timeline (so a photo can be opened in the viewer), plus the two routes the
offline cache actually uses:

* `GET /api/assets/{id}` — the full DTO. It carries `originalFileName` (the
  cached file's display name) and `exifInfo.fileSizeInByte` (the announced size
  the budget is checked against before any byte is pulled). Both are absent from
  the timeline's columnar payload, which is why the download path refetches.
* `GET /api/assets/{id}/original` — the payload itself, streamed as
  `application/octet-stream` with a `Content-Length`. The app downloads it with
  `URLSession.download`, so the body must be a real file an ImageIO decode can
  turn into an image when the cache replays it offline — the same 8×8 PNG
  generator the sibling stubs use, for the same reason (a hand-written 1×1 JPEG
  literal is not decodable and every tile reads as broken).

`/__requests` records what the app sent, so the scenario asserts on the wire:
the `Authorization` header on the download, and that the request really hit
`/original` rather than a cached body.
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

# Nine library photos in one bucket. More than one screenful on purpose: the
# timeline pins a floating date header over its FIRST row, so a badge on a
# first-row tile is invisible in a screenshot — the scenario downloads a
# second-row photo and scrolls it clear before capturing the badge.
LIBRARY = [f"aaaaaaaa-1111-4111-8111-{i:012d}" for i in range(1, 10)]
BUCKET = "2024-07-01"

PALETTE = [(0x42, 0x50, 0xAF), (0xE0, 0x7A, 0x5F), (0x2E, 0x8B, 0x57),
           (0xC9, 0xA2, 0x27), (0x7A, 0x4F, 0x9E), (0x2A, 0x7C, 0x9E)]


def png(aid, size=8):
    """A real, decodable PNG whose colour derives from the asset id."""
    r, g, b = PALETTE[sum(aid.encode()) % len(PALETTE)]
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
    """Rotated on every `/__reset`: both app-side image caches key on the URL
    (`ImageCache` in memory, `URLCache` on disk via `returnCacheDataElseLoad`),
    so a fixed value lets an earlier run's body be replayed with no request."""
    return "stub-%08d" % (int(time.time() * 1000) % 10**8)


THUMBHASH = new_thumbhash()


def asset(aid):
    """The full `AssetResponseDto`.

    `exifInfo.fileSizeInByte` is deliberately a realistic size: it is the number
    the store checks against the cache budget before downloading, so leaving it
    out would silently disable that gate in the scenario.
    """
    return {
        "id": aid, "type": "IMAGE", "thumbhash": THUMBHASH,
        "localDateTime": "2024-07-01T10:00:00.000Z", "duration": None, "hasMetadata": True,
        "width": 4000, "height": 3000, "createdAt": "2024-07-01T10:00:00.000Z",
        "ownerId": ME, "originalPath": f"/x/{aid}.png",
        "originalFileName": f"stub-{aid[-2:]}.png",
        "fileCreatedAt": "2024-07-01T10:00:00.000Z", "fileModifiedAt": "2024-07-01T10:00:00.000Z",
        "updatedAt": "2024-07-01T10:00:00.000Z", "isFavorite": False, "isArchived": False,
        "isTrashed": False, "isOffline": False, "visibility": "timeline", "checksum": "abc",
        "isEdited": False,
        "exifInfo": {
            "make": "Stub", "model": "Stub", "exifImageWidth": 4000, "exifImageHeight": 3000,
            "fileSizeInByte": 2048, "orientation": "1", "dateTimeOriginal": "2024-07-01T10:00:00.000Z",
            "modifyDate": "2024-07-01T10:00:00.000Z", "timeZone": "UTC", "lensModel": None,
        },
    }


# Every parallel array must match the id array: AssetReactItem.zip returns [] on
# a mismatch, which shows up as an empty timeline rather than a visual glitch.
RATIOS = [1.333, 1.0, 1.5]


def bucket():
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


def initial_state():
    # `down` simulates a dead server: the scenario flips it after downloading, so
    # anything that still renders came from disk and not from the network.
    return {"provider": "manual", "requests": [], "downloads": 0, "down": False}


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

    def _log(self, entry):
        STATE["requests"].append(entry)

    def _not_found(self, path):
        self._send({"error": "not found", "path": path}, status=404)

    # MARK: - GET

    def do_GET(self):
        path = self.path.split("?")[0]
        query = self.path.split("?")[1] if "?" in self.path else ""

        if path == "/__reset":
            global THUMBHASH
            THUMBHASH = new_thumbhash()
            STATE.update(initial_state())
            return self._send({"reset": True})
        if path == "/__provider":
            STATE["provider"] = "auto" if "auto" in query else "manual"
            return self._send({"provider": STATE["provider"]})
        if path == "/__network":
            STATE["down"] = "down=1" in query
            return self._send({"down": STATE["down"]})
        if path == "/__requests":
            return self._send(STATE["requests"])
        if path == "/provider-manual":
            return self._send(PROVIDER_HTML, ctype="text/html; charset=utf-8")
        if path == "/provider-auto":
            return self._send(AUTO_HTML, ctype="text/html; charset=utf-8")

        if path == "/api/timeline/buckets":
            if STATE["down"]:
                return self._send({"error": "offline"}, status=503)
            return self._send([{"timeBucket": BUCKET, "count": len(LIBRARY)}])
        if path == "/api/timeline/bucket":
            if STATE["down"]:
                return self._send({"error": "offline"}, status=503)
            return self._send(bucket())
        if path.startswith("/api/assets/") and STATE["down"]:
            # Simulated dead server: the app must have nothing left to fetch.
            self._log({"method": "GET", "path": path, "assetId": path.split("/")[3], "offline": True})
            return self._send({"error": "offline"}, status=503)
        if path.startswith("/api/assets/") and path.endswith("/thumbnail"):
            # `no-store`: the app's image session is `returnCacheDataElseLoad`,
            # so a body cached under this URL is replayed without asking.
            return self._send(
                png(path.split("/")[3]), ctype="image/png",
                headers={"Cache-Control": "no-store"},
            )
        if path.startswith("/api/assets/") and path.endswith("/original"):
            aid = path.split("/")[3]
            STATE["downloads"] += 1
            self._log({
                "method": "GET", "path": path, "assetId": aid,
                "authorization": self.headers.get("Authorization"),
            })
            # A file the app actually stores and later decodes from disk. Full
            # `Content-Length` so the download reports determinate progress.
            return self._send(
                png(aid, size=64), ctype="application/octet-stream",
                headers={"Cache-Control": "no-store"},
            )
        if path.startswith("/api/assets/"):
            aid = path.split("/")[3]
            return self._send(asset(aid))

        routes = {
            "/api/server/ping": {"res": "pong"},
            "/api/server/version": {"major": 2, "minor": 0, "patch": 0, "prerelease": None},
            "/api/server/config": CONFIG,
            "/api/users/me": ME_USER,
            "/api/users": [ME_USER],
            "/api/albums": [ALBUM_DTO],
            "/api/partners": [],
            "/api/activities": [],
            "/api/notifications": [],
            "/api/stacks": [],
            "/api/tags": [],
            "/api/memories": [],
            "/api/search/cities": [],
        }
        if path in routes:
            return self._send(routes[path])
        if path.startswith("/api/"):
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

        if path == "/api/search/metadata":
            return self._send({
                "assets": {"count": len(LIBRARY), "items": [asset(a) for a in LIBRARY], "nextPage": None},
            })

        if path.startswith("/api/"):
            return self._send({"successful": True})
        self._not_found(path)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}") if length else {}

    # MARK: - PUT / DELETE

    def do_PUT(self):
        self._body()
        if self.path.split("?")[0].startswith("/api/"):
            return self._send({"successful": True})
        self._not_found(self.path)

    def do_DELETE(self):
        self._body()
        if self.path.split("?")[0].startswith("/api/"):
            return self._send({"successful": True})
        self._not_found(self.path)


if __name__ == "__main__":
    print(json.dumps({
        "port": PORT,
        "library": len(LIBRARY),
        "endpoints": [
            "/api/timeline/buckets", "/api/timeline/bucket",
            "/api/assets/{id}", "/api/assets/{id}/thumbnail", "/api/assets/{id}/original",
            "/__reset", "/__provider", "/__requests",
        ],
    }))
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
