"""Immich API stub for the shared-links end-to-end scenario (UITests).

Committed on purpose: the stacks stub originally lived in /tmp, so a
`rm -rf /tmp/*` (or a reboot) silently destroyed the harness and only the test
comments remembered it existed. This one is self-contained and is run by hand
before the XCUITest:

    python3 UITests/stubs/immich_stub_shared_links.py 8421
    xcodebuild test -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \\
        -destination 'platform=iOS Simulator,name=iPhone 17' \\
        -only-testing:ImmichSwiftUIUITests/ImmichRenderScreenshots/test_07_sharedLinks

It serves the OAuth handshake the app needs to reach the authenticated shell
(same shape as the partner stub) plus the shared-link routes. Three behaviours
matter beyond "returns data":

* `externalDomain` is set to `https://photos.stub.test`, while the app dials
  `http://127.0.0.1:<port>`. The URL the app displays therefore proves which one
  it used: the bug was that it always hardcoded the address it dials plus
  `/share/<key>`, ignoring both the external domain and the link's slug.
* `POST /api/shared-links` echoes the `slug` it received (and 400s when an ALBUM
  link arrives without `albumId`), so the created link's public URL is `…/s/…`
  only if the app really sent a slug.
* `GET /__requests` exposes what the app actually sent, so the scenario can
  assert on the wire rather than on a screenshot.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import immich_stub_base as base  # SERVER_VERSION, serves, config payloads (L-20)

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8421
BASE = f"http://127.0.0.1:{PORT}"

# The public domain an admin would configure behind a reverse proxy. The app is
# pointed at 127.0.0.1, so any URL carrying this host came from `externalDomain`.
EXTERNAL_DOMAIN = "https://photos.stub.test"

ME = "11111111-1111-4111-8111-111111111111"
ALBUM = "22222222-2222-4222-8222-000000000002"
LINK_KEY = "c3R1Yi1rZXk"  # base64url of "stub-key"

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
    "externalDomain": EXTERNAL_DOMAIN, "publicUsers": True,
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


def link_dto(link_id, slug, description, expires_at, password):
    return {
        "id": link_id, "description": description, "password": password,
        "userId": ME, "key": LINK_KEY, "type": "ALBUM",
        "createdAt": "2026-01-01T00:00:00.000Z", "expiresAt": expires_at,
        "assets": [], "album": None,
        "allowUpload": False, "allowDownload": True, "showMetadata": True,
        "slug": slug,
    }


def initial_state():
    return {
        # No link at first: the scenario starts on the empty state.
        "links": [],
        "provider": "manual",
        "requests": [],
        "next_link": 1,
    }


STATE = initial_state()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("stub %s\n" % (fmt % args))

    def _send(self, payload, status=200, ctype="application/json"):
        body = payload if isinstance(payload, bytes) else (
            payload.encode() if ctype.startswith("text/") else json.dumps(payload).encode()
        )
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}") if length else {}

    def _log(self, entry):
        STATE["requests"].append(entry)

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

        if path == "/api/shared-links":
            self._log({"method": "GET", "path": path, "query": query})
            return self._send(STATE["links"])

        if path == "/api/albums":
            return self._send([ALBUM_DTO])

        routes = {
            "/api/server/ping": {"res": "pong"},
            "/api/server/version": base.version_payload(),
            "/api/server/config": CONFIG,
            "/api/public/config": base.public_config_payload(CONFIG),
            "/api/config": base.user_config_payload(CONFIG),
            "/api/users/me": ME_USER,
            "/api/users": [ME_USER],
            "/api/timeline/buckets": [],
            "/api/memories": [],
            "/api/partners": [],
            "/api/activities": [],
            "/api/notifications": [],
            "/api/stacks": [],
            "/api/tags": [],
        }
        if not base.serves("GET", path, base.parse_version(base.SERVER_VERSION)):
            self._log({"method": "GET", "path": path})
            return self._send({"message": f"Cannot GET {path}", "statusCode": 404}, status=404)
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

        if path == "/api/shared-links":
            self._log({
                "method": "POST", "path": path, "type": body.get("type"),
                "albumId": body.get("albumId"), "slug": body.get("slug"),
                "expiresAt": body.get("expiresAt"),
            })
            # Mirror the server's Zod refinement: an ALBUM link needs an albumId.
            if body.get("type") == "ALBUM" and not body.get("albumId"):
                return self._send(
                    {"error": "Bad Request", "message": ["albumId is required for type ALBUM"]},
                    status=400,
                )
            link_id = "99999999-9999-4999-8999-%012d" % STATE["next_link"]
            STATE["next_link"] += 1
            created = link_dto(
                link_id,
                body.get("slug") or None,
                body.get("description"),
                body.get("expiresAt"),
                body.get("password"),
            )
            STATE["links"].append(created)
            return self._send(created, status=201)

        if path.startswith("/api/"):
            return self._send({"successful": True})
        self._send({"error": "not found", "path": path}, status=404)

    # MARK: - PATCH / PUT / DELETE

    def do_PATCH(self):
        self._mutate(method="PATCH")

    def do_PUT(self):
        self._mutate(method="PUT")

    def _mutate(self, method):
        path = self.path.split("?")[0]
        body = self._body()
        self._log({"method": method, "path": path, "body": body})

        if "/shared-links/" not in path:
            return self._send({"error": "not found", "path": path}, status=404)

        # `PUT /shared-links/{id}` is what the app used to send; the server only
        # exposes PATCH, so answering 404 here is faithful and catches a relapse.
        if method == "PUT":
            return self._send({"error": "not found", "path": path}, status=404)

        link_id = path.split("/shared-links/")[1].split("/")[0]
        for link in STATE["links"]:
            if link["id"] != link_id:
                continue
            # `slug: dto.slug || null` — an omitted slug clears the stored one.
            link["slug"] = body.get("slug") or None
            for field in ("description", "expiresAt"):
                if field in body:
                    link[field] = body[field]
            return self._send(link)
        self._send({"error": "not found", "path": path}, status=404)

    def do_DELETE(self):
        path = self.path.split("?")[0]
        self._log({"method": "DELETE", "path": path})
        if path.startswith("/api/shared-links/"):
            link_id = path.rsplit("/", 1)[-1]
            before = len(STATE["links"])
            STATE["links"] = [link for link in STATE["links"] if link["id"] != link_id]
            if len(STATE["links"]) == before:
                return self._send({"error": "not found"}, status=404)
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return
        self._send({"error": "not found", "path": path}, status=404)


if __name__ == "__main__":
    print(json.dumps({
        "port": PORT,
        "externalDomain": EXTERNAL_DOMAIN,
        "endpoints": ["/api/shared-links", "/api/albums", "/__reset", "/__requests"],
    }))
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
