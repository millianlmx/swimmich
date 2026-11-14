"""Immich API stub for the editor's server-side edits (`AssetEditsUITests`).

    python3 UITests/stubs/immich_stub_asset_edits.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/asset-edits.uitest.log \\
        UITests/stubs/immich_stub_asset_edits.py AssetEditsUITests --erase

Built on `immich_stub_base` (OAuth shell, request journal `/__requests`, asset
thumbnails and originals). What it adds is the `/edits` family of Immich v3.4.0
and a control route to arm it.

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

CONTROL ROUTE (under `/api/`: the base answers every `/__…` path itself)
* `GET /api/__edits/config?version=3.4.0|2.0.0&put=200|500&regen=<seconds>&live=<id>` sets
  what is given; `seed=<id>&edits=<json>` stores the list of an asset (`edits` is the
  JSON array of `{action, parameters}`). Unknown parameters are ignored. The
  state is wiped by `/__reset`.

EDITED IMAGES AND THUMBHASH GENERATIONS (display and download scenarios)
* `GET /api/assets/<id>/thumbnail` and `/original` serve, for `edited=true` and a
  non-empty list, an edited image (other colour AND other size); otherwise the
  image as uploaded. The journal notes `sha` (a fingerprint of what was served).
* Each `PUT` or `DELETE /edits` is a new generation of the asset. Its thumbhash
  (`GET /api/assets/<id>`, `GET /api/timeline/bucket`) is `<base>-e<n>` and its
  edited image is served only `regen` seconds later (default 0): until then the
  old thumbhash and the old image, as a v3.4.0 server before its regeneration job
  ends. The `AssetEditReadyV2` websocket event is not emitted: the app also
  polls the record for as long as the official client waits for the event.
"""
import hashlib
import json
import re
import time

from immich_stub_base import STATE, TIMELINE_ASSETS, Response, asset, bucket_payload, main, png, router

WIDTH, HEIGHT = 4000, 3000
VERSIONS = {"3.4.0": (3, 4, 0), "2.0.0": (2, 0, 0)}
NEW_ASSET = "new-asset"


@router.reset
def fresh():
    STATE["edits"] = {"version": "3.4.0", "put": 200, "lists": {}, "live": set(), "regen": 0.0, "changes": {}}


fresh()  # a request before the first `/__reset` must not find an empty STATE


def serves_edits():
    return STATE["edits"]["version"] != "2.0.0"


def bump(aid):
    """The edits of `aid` changed: a new generation, which the server takes `regen` seconds to render."""
    generation = STATE["edits"]["changes"].get(aid, (0, 0))[1]
    STATE["edits"]["changes"][aid] = (time.time(), generation + 1)


def regenerated(aid):
    """The server has finished the `AssetEditThumbnailGeneration` job of the last change of `aid`."""
    change = STATE["edits"]["changes"].get(aid)
    return change is None or time.time() - change[0] >= STATE["edits"]["regen"]


def edited_ready(aid):
    """`edited=true` serves the edited image: the list is not empty and its generation is rendered."""
    return bool(STATE["edits"]["lists"].get(aid)) and regenerated(aid)


def thumbhash_of(aid):
    """The thumbhash advertised for `aid`: the base's, then `<base>-e<n>` for the n-th change, each one
    only once its thumbnails are regenerated (until then the previous one, as v3.4.0 does)."""
    base = STATE["thumbhash"]
    change = STATE["edits"]["changes"].get(aid)
    if change is None:
        return base
    generation = change[1] if regenerated(aid) else change[1] - 1
    return base if generation == 0 else f"{base}-e{generation}"


def not_found(path):
    return Response({"message": f"Cannot {path}", "error": "Not Found", "statusCode": 404}, status=404)


def bad_request(message):
    return Response({"message": [message], "error": "Bad Request", "statusCode": 400}, status=400)


def edits_payload(aid):
    return {"assetId": aid, "edits": STATE["edits"]["lists"].get(aid, [])}


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
    detail = asset(aid)
    detail["thumbhash"] = thumbhash_of(aid)
    if serves_edits():
        detail["isEdited"] = bool(STATE["edits"]["lists"].get(aid))
    else:
        detail.pop("isEdited", None)
    if aid in STATE["edits"]["live"]:
        detail["livePhotoVideoId"] = f"live-{aid}"
    return Response(detail)


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
    req.note(sha=hashlib.sha1(data).hexdigest(), edited_served=shown_edited)
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
    STATE["edits"]["lists"][aid] = [
        {"id": f"edit-{n}", "action": item["action"], "parameters": item["parameters"]}
        for n, item in enumerate(edits, start=1)
    ]
    bump(aid)
    return Response(edits_payload(aid))


@router.prefix("DELETE", "/api/assets/")
def delete_edits(req):
    aid, _, tail = req.rest.partition("/")
    if tail != "edits":
        return None
    if not serves_edits():
        return not_found(f"DELETE {req.path}")
    STATE["edits"]["lists"].pop(aid, None)
    bump(aid)
    return Response(b"", status=204, ctype="application/octet-stream")


# MARK: - Copy upload


@router.post("/api/assets")
def upload(req):
    raw = req.body.get("raw", "") if isinstance(req.body, dict) else ""
    match = re.search(r'filename="([^"]*)"', raw)
    req.note(filename=match.group(1) if match else None)
    return Response({"id": NEW_ASSET, "status": "created"}, status=201)


# MARK: - Control


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
    if params.get("live"):
        state["live"].add(params["live"])
    if params.get("seed") and params.get("edits"):
        listed = json.loads(params["edits"])
        state["lists"][params["seed"]] = [
            {"id": f"edit-{n}", "action": item["action"], "parameters": item["parameters"]}
            for n, item in enumerate(listed, start=1)
        ]
    return Response({"version": state["version"], "put": state["put"], "regen": state["regen"],
                     "live": sorted(state["live"]), "seeded": sorted(state["lists"])})


if __name__ == "__main__":
    main(label="asset_edits")
