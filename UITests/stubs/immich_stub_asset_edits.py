"""Immich API stub for the server-side edits (`AssetEditsUITests`).

    python3 UITests/stubs/immich_stub_asset_edits.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/asset-edits.uitest.log \\
        UITests/stubs/immich_stub_asset_edits.py AssetEditsUITests --erase

Built on `immich_stub_base` (OAuth shell, request journal `/__requests`, asset
thumbnails and originals) and `immich_stub_socketio` (the `AssetEditReadyV2` event). What it adds is
the `/edits` family of Immich v3.4.0, the regeneration job that follows a change, one album, two
searches, and control routes to arm all of it.

SERVER VERSION
* `GET /api/server/version` answers the configured version: `3.4.0` (default) or
  `2.0.0`. At 2.0.0 the server does not know `/edits`: `GET`, `PUT` and `DELETE`
  `/api/assets/<id>/edits` answer **404**, and the asset has no `isEdited` key.

THE EDIT LIST, replaying `asset.service.ts` `editAsset` of Immich v3.4.0
* `GET /api/assets/<id>/edits` → `{assetId, edits: [{id, action, parameters}]}`.
* `PUT /api/assets/<id>/edits` replaces the whole list. It is a **400** when the
  list is empty, when a `crop` is not the first action, when a crop value is not
  an integer or leaves the 4000×3000 photo (EXIF orientation 1), when a rotation
  is not 0, 90, 180 or 270, or when a mirror axis is neither `horizontal` nor
  `vertical`. With `put=500` it answers 500 first. A good list is stored and
  answered back with one `id` per action.
* `DELETE /api/assets/<id>/edits` empties the list: 204.
* `GET /api/assets/<id>` is the base's asset with `isEdited` true when its list is
  not empty (the key is absent at 2.0.0), and a `livePhotoVideoId` when armed by
  `live=<id>`.
* `GET /api/assets/<id>/original` is the base's PNG: the journal keeps its
  `edited` query parameter (`params.edited`).
* `POST /api/assets` is the editor's copy upload: `{"id":"new-asset",
  "status":"created"}`, and the journal entry carries the file name sent
  (`filename`). A scenario that must prove "no copy" asserts there is no entry.

THE REGENERATION JOB, as v3.4.0 runs it after a `PUT` or `DELETE`
* Each change of a list (`PUT`, `DELETE`, `/api/__edits/remote`) is a new generation `n` of the asset.
  The server takes `regen` seconds (default 0) to regenerate the thumbnails, and until then it keeps
  serving the previous rendering: the previous list's image for `edited=true` and the previous
  thumbhash (`GET /api/assets/<id>`, `GET /api/timeline/bucket`), **after a `DELETE` as after a `PUT`**.
* Rendered images: a non-empty rendered list serves, for `edited=true`, an edited image (other colour
  AND other size: thumbnail 12×12, original 96×96); otherwise the image as uploaded (thumbnail 8×8,
  original 64×64). The journal notes `sha` (a fingerprint of what was served), `edited_served` and `at`
  (the time of the request).
* Thumbhash: the base's while the rendered list is empty (so after a removal, as a server that
  regenerates from the same original does), `<base>-e<n>` for the rendered generation `n` of an edited
  asset.
* At the end of the job the stub emits `AssetEditReadyV2` on the socket (`{"asset": {"id", "thumbhash"}}`)
  unless `event=0`. The socket is `ws://…/api/socket.io/` (see `immich_stub_socketio.py`); its journal
  entry has `status: 101`.

ALBUM AND SEARCHES (the scenarios' surfaces besides the timeline)
* `GET /api/albums` answers one album `eeeeeeee-2222-4222-8222-000000000001` ("Edits", cover = the first
  timeline photo, 6 photos, `updatedAt` 2026-09-01); `?shared=true` answers `[]`. `GET /api/albums/<id>` the
  same DTO, another id 404. Its `lastModifiedAssetTimestamp` is the time of the latest regeneration already
  done of one of its photos (what the server derives from `asset.updatedAt`), `updatedAt` before any.
* `POST /api/search/metadata` with `albumIds` containing the album: the six timeline photos; otherwise
  none. `POST /api/search/smart`: the first timeline photo, for any query. Both carry the photo's
  thumbhash of the moment.

CONTROL ROUTES (under `/api/`: the base answers every `/__…` path itself). Unknown parameters are
ignored; the state is wiped by `/__reset`.
* `GET /api/__edits/config?version=3.4.0|2.0.0&put=200|500&regen=<seconds>&live=<id>&event=0|1&down=0|1`
  sets what is given; `seed=<id>&edits=<json>` stores the list of an asset (`edits` is the JSON array of
  `{action, parameters}`; no generation). `down=1` is a server that does not answer: every `/api/` route
  but `/api/__edits/…` answers 503 (journal entry `dropped: true`), the socket is cut and refused.
* `GET /api/__edits/remote?id=<id>&edits=<json>` is a change made by ANOTHER client: no request from the
  app. `[]` empties the list, otherwise the list is checked like a `PUT` (400) and stored; then a new
  generation starts, with its event.
* `GET /api/__edits/state?id=<id>` answers `{now, generation, changedAt, readyAt, ready, emittedAt,
  thumbhash, sha: {thumbnail, thumbnailEdited, original, originalEdited}}`: the times are epoch
  seconds (`null` before any change), the `sha` values are the fingerprints a journal entry can be
  compared with.
"""
import datetime
import hashlib
import json
import re
import threading
import time
from urllib.parse import parse_qsl

from immich_stub_base import (STATE, TIMELINE_ASSETS, Response, StubHandler, asset, bucket_payload, main, png,
                              router)
from immich_stub_socketio import close_all, emit, is_upgrade, serve

WIDTH, HEIGHT = 4000, 3000
VERSIONS = {"3.4.0": (3, 4, 0), "2.0.0": (2, 0, 0)}
NEW_ASSET = "new-asset"
ALBUM = "eeeeeeee-2222-4222-8222-000000000001"
ALBUM_UPDATED_AT = "2026-09-01T00:00:00.000Z"


@router.reset
def fresh():
    STATE["edits"] = {
        "version": "3.4.0", "put": 200, "lists": {}, "live": set(), "regen": 0.0, "changes": {},
        "event": True, "down": False, "ready_at": {}, "emitted_at": {},
    }
    close_all()


fresh()  # a request before the first `/__reset` must not find an empty STATE


def serves_edits():
    return STATE["edits"]["version"] != "2.0.0"


def bump(aid, previous):
    """The edits of `aid` changed (`previous` is the list before): a new generation, which the server takes
    `regen` seconds to render, and then announces."""
    state = STATE["edits"]
    now = time.time()
    generation = state["changes"].get(aid, (0, 0, []))[1] + 1
    state["changes"][aid] = (now, generation, previous)
    state["ready_at"][aid] = now + state["regen"]
    state["emitted_at"].pop(aid, None)
    timer = threading.Timer(state["regen"], ready, (aid, generation, state))
    timer.daemon = True
    timer.start()


def ready(aid, generation, token):
    """The `AssetEditThumbnailGeneration` job of `generation` ends: `AssetEditReadyV2`."""
    while STATE["edits"] is token and not regenerated(aid):
        time.sleep(0.005)
    change = token["changes"].get(aid)
    if STATE["edits"] is not token or change is None or change[1] != generation or not token["event"]:
        return
    emit("AssetEditReadyV2", {"asset": {"id": aid, "thumbhash": thumbhash_of(aid)}})
    token["emitted_at"][aid] = time.time()


def regenerated(aid):
    """The server has finished the `AssetEditThumbnailGeneration` job of the last change of `aid`."""
    change = STATE["edits"]["changes"].get(aid)
    return change is None or time.time() - change[0] >= STATE["edits"]["regen"]


def rendered(aid):
    """`(generation, list)` the server renders now: the last change once its job is done, the one before
    until then."""
    state = STATE["edits"]
    current = state["lists"].get(aid, [])
    change = state["changes"].get(aid)
    if change is None:
        return 0, current
    _, generation, previous = change
    if regenerated(aid):
        return generation, current
    return generation - 1, previous


def edited_ready(aid):
    """`edited=true` serves the edited image: the rendered list is not empty."""
    return bool(rendered(aid)[1])


def thumbhash_of(aid):
    """The thumbhash advertised for `aid`: the base's while the rendered list is empty, then
    `<base>-e<n>` for the rendered generation `n`."""
    base = STATE["thumbhash"]
    generation, current = rendered(aid)
    return f"{base}-e{generation}" if current and generation else base


def not_found(path):
    return Response({"message": f"Cannot {path}", "error": "Not Found", "statusCode": 404}, status=404)


def bad_request(message):
    return Response({"message": [message], "error": "Bad Request", "statusCode": 400}, status=400)


def edits_payload(aid):
    return {"assetId": aid, "edits": STATE["edits"]["lists"].get(aid, [])}


def listed(edits):
    """A list with the `id` the server gives each action."""
    return [{"id": f"edit-{n}", "action": item["action"], "parameters": item["parameters"]}
            for n, item in enumerate(edits, start=1)]


def check(edits):
    """The reason the server would refuse this list, or `None`."""
    if not isinstance(edits, list) or not edits:
        return "edits must contain at least 1 elements"
    for index, item in enumerate(edits):
        action = item.get("action") if isinstance(item, dict) else None
        params = (item.get("parameters") if isinstance(item, dict) else None) or {}
        if action == "crop":
            if index != 0:
                return "Crop action must be the first edit action"
            values = [params.get(key) for key in ("x", "y", "width", "height")]
            if not all(isinstance(v, int) and not isinstance(v, bool) for v in values):
                return "crop parameters must be integers"
            x, y, width, height = values
            if x < 0 or y < 0 or width < 1 or height < 1 or x + width > WIDTH or y + height > HEIGHT:
                return "Crop parameters are out of bounds"
        elif action == "rotate":
            if params.get("angle") not in (0, 90, 180, 270) or isinstance(params.get("angle"), bool):
                return "angle must be one of 0, 90, 180, 270"
        elif action == "mirror":
            if params.get("axis") not in ("horizontal", "vertical"):
                return "axis must be one of horizontal, vertical"
        else:
            return "action must be one of crop, rotate, mirror"
    return None


def detail(aid):
    """`GET /api/assets/<id>`: the base's asset with the thumbhash of the rendered generation, `isEdited`
    and `livePhotoVideoId`. The searches serve the same."""
    record = asset(aid)
    record["thumbhash"] = thumbhash_of(aid)
    if serves_edits():
        record["isEdited"] = bool(STATE["edits"]["lists"].get(aid))
    else:
        record.pop("isEdited", None)
    if aid in STATE["edits"]["live"]:
        record["livePhotoVideoId"] = f"live-{aid}"
    return record


# MARK: - The server that does not answer


class EditsHandler(StubHandler):
    """`StubHandler`, plus the socket and the `down` switch."""

    def do_GET(self):
        if is_upgrade(self):
            if STATE["edits"]["down"]:
                self.close_connection = True
                self.send_error(503)
                return
            serve(self)
            return
        super().do_GET()

    def _dispatch(self, method):
        path, _, query = self.path.partition("?")
        if STATE["edits"]["down"] and path.startswith("/api/") and not path.startswith("/api/__edits/"):
            self._body()
            STATE["requests"].append({"method": method, "path": path,
                                      "params": dict(parse_qsl(query, keep_blank_values=True)),
                                      "body": {}, "dropped": True})
            self._send(Response({"message": "Service Unavailable"}, status=503))
            return
        super()._dispatch(method)


# MARK: - Version and asset


@router.get("/api/server/version")
def server_version(req):
    major, minor, patch = VERSIONS[STATE["edits"]["version"]]
    return Response({"major": major, "minor": minor, "patch": patch, "prerelease": None})


@router.get("/api/timeline/bucket")
def timeline_bucket(req):
    """The base's day, each photo advertising the thumbhash its edits generation has reached."""
    payload = bucket_payload(TIMELINE_ASSETS)
    payload["thumbhash"] = [thumbhash_of(aid) for aid in TIMELINE_ASSETS]
    return Response(payload)


@router.prefix("GET", "/api/assets/")
def get_asset_or_edits(req):
    aid, _, tail = req.rest.partition("/")
    if tail == "edits":
        return edits_payload_response(req, aid)
    if tail in ("thumbnail", "original"):
        return image(req, aid, tail)
    if tail:
        return None  # video playback… the base serves it
    return Response(detail(aid))


def sha_of(data):
    return hashlib.sha1(data).hexdigest()


def image(req, aid, kind):
    """`/thumbnail` and `/original`: the edited rendering for `edited=true` once the server has regenerated
    it, the file as uploaded otherwise. The two differ in colour AND size, so their bytes always differ.
    The journal notes a fingerprint of what was served (`sha`)."""
    shown_edited = req.params.get("edited") == "true" and edited_ready(aid)
    if kind == "original":
        data = png(aid + "-edited", size=96) if shown_edited else png(aid, size=64)
        ctype = "application/octet-stream"
    else:
        data = png(aid + "-edited", size=12) if shown_edited else png(aid)
        ctype = "image/png"
    req.note(sha=sha_of(data), edited_served=shown_edited, at=time.time())
    return Response(data, ctype=ctype, headers={"Cache-Control": "no-store"})


def edits_payload_response(req, aid):
    if not serves_edits():
        return not_found(f"GET {req.path}")
    return Response(edits_payload(aid))


# MARK: - Edits


@router.prefix("PUT", "/api/assets/")
def put_edits(req):
    aid, _, tail = req.rest.partition("/")
    if tail != "edits":
        return None
    if not serves_edits():
        return not_found(f"PUT {req.path}")
    if STATE["edits"]["put"] == 500:
        return Response({"message": "Internal server error", "statusCode": 500}, status=500)
    edits = (req.body or {}).get("edits")
    reason = check(edits)
    if reason:
        return bad_request(reason)
    previous = STATE["edits"]["lists"].get(aid, [])
    STATE["edits"]["lists"][aid] = listed(edits)
    bump(aid, previous)
    return Response(edits_payload(aid))


@router.prefix("DELETE", "/api/assets/")
def delete_edits(req):
    aid, _, tail = req.rest.partition("/")
    if tail != "edits":
        return None
    if not serves_edits():
        return not_found(f"DELETE {req.path}")
    previous = STATE["edits"]["lists"].pop(aid, [])
    bump(aid, previous)
    return Response(b"", status=204, ctype="application/octet-stream")


# MARK: - Copy upload


@router.post("/api/assets")
def upload(req):
    raw = req.body.get("raw", "") if isinstance(req.body, dict) else ""
    match = re.search(r'filename="([^"]*)"', raw)
    req.note(filename=match.group(1) if match else None)
    return Response({"id": NEW_ASSET, "status": "created"}, status=201)


# MARK: - Album and searches


def iso(epoch):
    stamp = datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc)
    return stamp.strftime("%Y-%m-%dT%H:%M:%S.") + f"{stamp.microsecond // 1000:03d}Z"


def album_dto():
    """A fresh dict per call. `lastModifiedAssetTimestamp`: the latest regeneration already done of a photo."""
    now = time.time()
    done = [at for aid, at in STATE["edits"]["ready_at"].items() if aid in TIMELINE_ASSETS and at <= now]
    return {
        "id": ALBUM, "albumName": "Edits", "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": ALBUM_UPDATED_AT,
        "albumThumbnailAssetId": TIMELINE_ASSETS[0], "shared": False, "hasSharedLink": False,
        "assetCount": len(TIMELINE_ASSETS), "isActivityEnabled": False, "order": "desc", "albumUsers": [],
        "lastModifiedAssetTimestamp": iso(max(done)) if done else ALBUM_UPDATED_AT,
    }


@router.get("/api/albums")
def albums(req):
    return Response([] if req.params.get("shared") == "true" else [album_dto()])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if not req.rest or "/" in req.rest:
        return None
    if req.rest == ALBUM:
        return Response(album_dto())
    return not_found(f"GET {req.path}")


def search_page(ids):
    items = [detail(aid) for aid in ids]
    return Response({"assets": {"count": len(items), "items": items, "nextPage": None, "nextCursor": None}})


@router.post("/api/search/metadata")
def search_metadata(req):
    body = req.body if isinstance(req.body, dict) else {}
    return search_page(TIMELINE_ASSETS if ALBUM in (body.get("albumIds") or []) else [])


@router.post("/api/search/smart")
def search_smart(req):
    return search_page(TIMELINE_ASSETS[:1])


# MARK: - Control


def state_payload(aid):
    state = STATE["edits"]
    change = state["changes"].get(aid)
    return {
        "now": time.time(),
        "generation": change[1] if change else 0,
        "changedAt": change[0] if change else None,
        "readyAt": state["ready_at"].get(aid),
        "ready": regenerated(aid),
        "emittedAt": state["emitted_at"].get(aid),
        "thumbhash": thumbhash_of(aid),
        "sha": {
            "thumbnail": sha_of(png(aid)),
            "thumbnailEdited": sha_of(png(aid + "-edited", size=12)),
            "original": sha_of(png(aid, size=64)),
            "originalEdited": sha_of(png(aid + "-edited", size=96)),
        },
    }


@router.get("/api/__edits/config")
def config(req):
    state = STATE["edits"]
    params = req.params
    if params.get("version") in VERSIONS:
        state["version"] = params["version"]
    if params.get("put") in ("200", "500"):
        state["put"] = int(params["put"])
    if params.get("regen"):
        state["regen"] = float(params["regen"])
    if params.get("event") in ("0", "1"):
        state["event"] = params["event"] == "1"
    if params.get("live"):
        state["live"].add(params["live"])
    if params.get("seed") and params.get("edits"):
        state["lists"][params["seed"]] = listed(json.loads(params["edits"]))
    if params.get("down") in ("0", "1"):
        state["down"] = params["down"] == "1"
        if state["down"]:
            close_all()
    return Response({"version": state["version"], "put": state["put"], "regen": state["regen"],
                     "event": state["event"], "down": state["down"],
                     "live": sorted(state["live"]), "seeded": sorted(state["lists"])})


@router.get("/api/__edits/remote")
def remote(req):
    """A change made by another client."""
    aid = req.params.get("id", "")
    edits = json.loads(req.params.get("edits") or "[]")
    if edits:
        reason = check(edits)
        if reason:
            return bad_request(reason)
    previous = STATE["edits"]["lists"].get(aid, [])
    if edits:
        STATE["edits"]["lists"][aid] = listed(edits)
    else:
        STATE["edits"]["lists"].pop(aid, None)
    bump(aid, previous)
    return Response(state_payload(aid))


@router.get("/api/__edits/state")
def state_route(req):
    return Response(state_payload(req.params.get("id", "")))


if __name__ == "__main__":
    main(label="asset_edits", handler=EditsHandler)
