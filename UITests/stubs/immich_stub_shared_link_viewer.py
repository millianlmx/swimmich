"""Immich API stub for the public shared-link viewer (issue #22, UITests).

Committed on purpose: the stacks stub originally lived in /tmp, so a
`rm -rf /tmp/*` (or a reboot) silently destroyed the harness and only the test
comments remembered it existed. This one is self-contained and is run by hand
before the XCUITest:

    python3 UITests/stubs/immich_stub_shared_link_viewer.py 8421
    xcodebuild test -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \\
        -destination 'platform=iOS Simulator,name=iPhone 17' \\
        -only-testing:ImmichSwiftUIUITests/ImmichRenderScreenshots/test_SLV_viewer

It serves the OAuth handshake the app needs to reach the authenticated shell
(same shape as the memories stub) plus the visitor routes of a shared link:

* `GET /api/shared-links/me?slug=|key=` — the visit. Protected links answer
  `401 {"message": "Password required"}` **until the request carries the cookie
  `POST /api/shared-links/login` handed out** — that is the server's rule
  (`SharedLinkService.getMine` compares the cookie token), and the whole reason
  a viewer must keep the cookie. Unknown/revoked slugs answer
  `401 {"message": "Invalid share slug"}`, which is how a dead link looks.
* `POST /api/shared-links/login?slug=|key=` — body `{password}`, answers 201 with
  `Set-Cookie: immich_shared_link_token=…` and the link DTO; a wrong password is
  `401 {"message": "Invalid password"}`.
* `POST /api/search/metadata?key=` — an album link's assets (`albumIds` filter
  only: the server refuses an unfiltered search under shared-link auth).
* `POST /api/assets?slug=` — a guest upload, refused with a bare 401 when the
  link has `allowUpload: false` (`requireUploadAccess`). The scenario does not
  drive it (the system photo picker is out of XCUITest's reach); it is here so
  the stub models the whole contract of a link, and so a manual run can.

Every visitor request is logged to `STATE["requests"]` with the cookie it
carried, readable at `GET /__requests`: the scenario asserts on the wire rather
than on a screenshot, which is the only way to prove the cookie was kept.
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

# The three links the scenario walks. `KEY` is a real-shaped key (50 random
# bytes, base64url) so the `/share/<key>` address of the *same* link can be
# pasted too — the server addresses a link by key or by slug interchangeably.
PASSWORD = "hunter2"
TOKEN = "stub-shared-link-token"
PROTECTED_SLUG = "trip-2026"
KEY = "wJalrXUtnFEMI7K7MDENGbPxRfiCYEXAMPLEKEY_0123456789-abcdef"
OPEN_SLUG = "open-link"
REVOKED_SLUG = "gone-2026"

# Asset ids carry a nonce regenerated on every `/__reset`.
# `AuthenticatedAsyncImage` caches thumbnails on disk by URL, so a fixed id would
# be served from that cache on a second run and the image request — the only
# place a link's credential appears in a URL — would never reach the stub again.
# The scenario finds cells by identifier prefix for the same reason.
def fresh_assets(prefix, count=3):
    """`count` asset ids whose nonce changes on every `/__reset` — see above."""
    run = "%08d" % (int(time.time() * 1000) % 10**8)
    return [f"{prefix}-{run}{i:04d}" for i in range(1, count + 1)]

# A real 8×8 PNG, generated rather than pasted: the pixels must be decodable or
# `AuthenticatedAsyncImage` falls back to its failure placeholder and every tile
# reads as a broken image (the sibling stubs' hand-written 1×1 JPEG bytes are
# not decodable by ImageIO — a screenshot of a blank grid is what that looks
# like). The colour derives from the asset id, so each cell of a screenshot is
# distinguishable and a mismatch is visible.
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


def asset(aid):
    """One asset of a link. Names derive from the id so each photo is
    identifiable in a screenshot ('bbbb-01.jpg', …)."""
    key = aid.replace("-", "")
    return {
        "id": aid, "type": "IMAGE", "thumbhash": None,
        "localDateTime": "2024-07-01T10:00:00.000Z", "duration": None, "hasMetadata": True,
        "width": 4000, "height": 3000, "createdAt": "2024-07-01T10:00:00.000Z",
        "ownerId": ME, "originalPath": f"/x/{key}.jpg",
        "originalFileName": f"{aid[:4]}-{aid[-2:]}.jpg",
        "fileCreatedAt": "2024-07-01T10:00:00.000Z", "fileModifiedAt": "2024-07-01T10:00:00.000Z",
        "updatedAt": "2024-07-01T10:00:00.000Z", "isFavorite": False, "isArchived": False,
        "isTrashed": False, "isOffline": False, "visibility": "timeline", "checksum": "abc",
        "isEdited": False,
    }


def album_dto(link):
    """`AlbumResponseDto` for the album link. The asset count is derived from the
    link's own list, so a guest upload is reflected on the next read."""
    count = len(link["assets"])
    return {
        "id": ALBUM, "albumName": "Stub Album", "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": link["assets"][0] if count else None,
        "shared": True, "hasSharedLink": True, "assetCount": count,
        "isActivityEnabled": False, "order": "desc", "albumUsers": [],
    }


def shared_link_dto(link):
    """`SharedLinkResponseDto` — `album` for an album link (never carrying the
    assets: `AlbumResponseDto` has no such field), `assets` inline for an
    individual one, exactly like `mapSharedLink`."""
    return {
        "id": link["id"], "description": link["description"], "password": link["password"],
        "userId": ME, "key": link["key"], "type": link["type"],
        "createdAt": "2026-01-01T00:00:00.000Z", "expiresAt": None,
        "assets": [asset(a) for a in link["assets"]] if link["type"] == "INDIVIDUAL" else [],
        "album": album_dto(link) if link["type"] == "ALBUM" else None,
        "allowUpload": link["allowUpload"], "allowDownload": True, "showMetadata": True,
        "slug": link["slug"],
    }


def initial_state():
    return {
        "links": [
            {"id": "link-protected", "slug": PROTECTED_SLUG, "key": KEY, "type": "ALBUM",
             "description": "Our trip", "password": PASSWORD, "allowUpload": True,
             "assets": fresh_assets("bbbbbbbb-2222-4222-8222")},
            {"id": "link-open", "slug": OPEN_SLUG, "key": "b3Blbi1saW5rLWtleQ", "type": "INDIVIDUAL",
             "description": None, "password": None, "allowUpload": False,
             "assets": fresh_assets("cccccccc-3333-4333-8333", count=2)},
        ],
        "provider": "manual",
        "requests": [],
    }


STATE = initial_state()

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
    # Empty on purpose: the scenario pastes links on 127.0.0.1, and the app
    # accepts either the API host or this domain as "our server".
    "externalDomain": "", "publicUsers": True,
    "mapDarkStyleUrl": "", "mapLightStyleUrl": "",
    "maintenanceMode": False, "minFaces": 0,
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


def unauthorized(message):
    return {"message": message, "error": "Unauthorized", "statusCode": 401}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("stub %s\n" % (fmt % args))

    def _send(self, payload, status=200, ctype="application/json", cookie=None, headers=None):
        body = payload if isinstance(payload, bytes) else (
            payload.encode() if ctype.startswith("text/") else json.dumps(payload).encode()
        )
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if cookie:
            self.send_header("Set-Cookie", cookie)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        # No keep-alive: every response closes, so a slow request cannot make the
        # next assertion race against a stale connection.
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}") if length else {}

    def _log(self, entry):
        STATE["requests"].append(entry)

    # MARK: - Links

    def _credential(self):
        """`(kind, value)` addressed by the query — `key` wins over `slug` in the
        server's own `AuthService.validate`."""
        query = self.path.split("?")[1] if "?" in self.path else ""
        params = dict(
            part.split("=", 1) for part in query.split("&") if "=" in part
        )
        if params.get("key"):
            return "key", params["key"]
        if params.get("slug"):
            return "slug", params["slug"]
        return None, None

    def _addressed(self):
        kind, value = self._credential()
        for link in STATE["links"]:
            if kind and link[kind] == value:
                return link
        return None

    def _has_session_cookie(self):
        cookie = self.headers.get("Cookie") or ""
        return f"immich_shared_link_token={TOKEN}" in cookie

    def _visit_entry(self, status):
        kind, value = self._credential()
        return {
            "method": status["method"], "path": status["path"],
            "credential": kind, "slug": value if kind == "slug" else None,
            "key": value if kind == "key" else None,
            "cookie": self._has_session_cookie(),
            # A visitor request must never carry the signed-in user's bearer —
            # logging it is the only way the scenario can prove the app stays a
            # visitor on a link it happens to own.
            "authorization": "Authorization" in self.headers,
            "password": status.get("password"),
        }

    # MARK: - GET

    def do_GET(self):
        path = self.path.split("?")[0]
        query = self.path.split("?")[1] if "?" in self.path else ""

        if path == "/__reset":
            STATE.update(initial_state())
            return self._send({"reset": True})
        if path == "/__provider":
            STATE["provider"] = "auto" if "auto" in query else "manual"
            return self._send({"provider": STATE["provider"]})
        if path == "/__requests":
            return self._send(STATE["requests"])
        if path == "/provider-manual":
            return self._send(PROVIDER_HTML, ctype="text/html; charset=utf-8")
        if path == "/provider-auto":
            return self._send(AUTO_HTML, ctype="text/html; charset=utf-8")

        # `/me` before the plain collection route: it is a literal path segment,
        # not a link id.
        if path == "/api/shared-links/me":
            entry = self._visit_entry({"method": "GET", "path": path})
            self._log(entry)
            link = self._addressed()
            if link is None:
                kind, _ = self._credential()
                return self._send(unauthorized("Invalid share slug" if kind == "slug"
                                               else "Invalid share key"), status=401)
            # The password is checked on the COOKIE, not on the key — the key
            # alone opens nothing on a protected link.
            if link["password"] and not self._has_session_cookie():
                return self._send(unauthorized("Password required"), status=401)
            return self._send(shared_link_dto(link))

        # The owner's own list. Empty: this stub has no owner-side links.
        if path == "/api/shared-links":
            return self._send([])

        if path.startswith("/api/assets/") and path.endswith("/thumbnail"):
            # The grid's images are public reads too: logging them lets the
            # scenario prove they carried the link's credential and no bearer.
            entry = self._visit_entry({"method": "GET", "path": path})
            entry["thumbnail"] = True
            self._log(entry)
            # `no-store`: the app's image session is `returnCacheDataElseLoad`,
            # so a cached body would be replayed without asking. Asset ids rotate
            # per `/__reset` here (which already changes the URL), but the header
            # makes the invariant explicit rather than implicit.
            return self._send(
                thumb(path.split("/")[3]),
                ctype="image/png",
                headers={"Cache-Control": "no-store"},
            )

        routes = {
            "/api/server/ping": {"res": "pong"},
            "/api/server/version": {"major": 2, "minor": 0, "patch": 0, "prerelease": None},
            "/api/server/config": CONFIG,
            "/api/users/me": ME_USER,
            "/api/users": [ME_USER],
            "/api/albums": [],
            "/api/timeline/buckets": [],
            "/api/timeline/bucket": {},
            "/api/memories": [],
            "/api/partners": [],
            "/api/activities": [],
            "/api/notifications": [],
            "/api/stacks": [],
            "/api/tags": [],
        }
        if path in routes:
            return self._send(routes[path])
        if path.startswith("/api/"):
            return self._send([])
        self._send({"error": "not found", "path": path}, status=404)

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

        if path == "/api/shared-links/login":
            entry = self._visit_entry({"method": "POST", "path": path,
                                       "password": body.get("password")})
            self._log(entry)
            link = self._addressed()
            if link is None:
                kind, _ = self._credential()
                return self._send(unauthorized("Invalid share slug" if kind == "slug"
                                               else "Invalid share key"), status=401)
            if not link["password"]:
                return self._send({"message": "Shared link is not password protected",
                                   "error": "Bad Request", "statusCode": 400}, status=400)
            if body.get("password") != link["password"]:
                return self._send(unauthorized("Invalid password"), status=401)
            return self._send(
                shared_link_dto(link),
                status=201,
                cookie=f"immich_shared_link_token={TOKEN}; Path=/; HttpOnly; SameSite=Lax",
            )

        # An album link's assets: the only search the server allows a visitor to
        # run, and only with an `albumIds` filter.
        if path == "/api/search/metadata":
            self._log({"method": "POST", "path": path, "albumIds": body.get("albumIds")})
            if not body.get("albumIds"):
                return self._send({"message": "Shared link access is only allowed in "
                                              "combination with an albumIds filter",
                                   "error": "Bad Request", "statusCode": 400}, status=400)
            link = self._addressed()
            if link is None:
                return self._send(unauthorized("Invalid share key"), status=401)
            items = [asset(a) for a in link["assets"]]
            return self._send({"assets": {"count": len(items), "items": items, "nextPage": None}})

        # Guest upload — refused with a bare 401 when the link forbids it.
        if path == "/api/assets":
            self._log({"method": "POST", "path": path, "upload": True})
            link = self._addressed()
            if link is None:
                return self._send(unauthorized("Invalid share key"), status=401)
            if not link["allowUpload"]:
                return self._send({"message": "Unauthorized", "error": "Unauthorized",
                                   "statusCode": 401}, status=401)
            new_id = fresh_assets("dddddddd-4444-4444-8444", count=1)[0]
            link["assets"].append(new_id)
            return self._send({"id": new_id, "status": "created"}, status=201)

        if path.startswith("/api/"):
            return self._send({"successful": True})
        self._send({"error": "not found", "path": path}, status=404)


if __name__ == "__main__":
    print(json.dumps({
        "port": PORT,
        "slugs": {"protected": PROTECTED_SLUG, "open": OPEN_SLUG, "revoked": REVOKED_SLUG},
        "key": KEY,
        "password": PASSWORD,
        "albumAssets": 3,
        "endpoints": ["/api/shared-links/me", "/api/shared-links/login",
                      "/api/search/metadata", "/api/assets", "/__reset", "/__requests"],
    }))
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
