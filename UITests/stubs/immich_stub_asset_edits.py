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
* `GET /api/__edits/config?version=3.4.0|2.0.0&put=200|500&live=<id>` sets what
  is given; `seed=<id>&edits=<json>` stores the list of an asset (`edits` is the
  JSON array of `{action, parameters}`). Unknown parameters are ignored. The
  state is wiped by `/__reset`.
"""
import json
import re

from immich_stub_base import STATE, Response, asset, main, router

WIDTH, HEIGHT = 4000, 3000
VERSIONS = {"3.4.0": (3, 4, 0), "2.0.0": (2, 0, 0)}
NEW_ASSET = "new-asset"


@router.reset
def fresh():
    STATE["edits"] = {"version": "3.4.0", "put": 200, "lists": {}, "live": set()}


fresh()  # a request before the first `/__reset` must not find an empty STATE


def serves_edits():
    return STATE["edits"]["version"] != "2.0.0"


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


@router.prefix("GET", "/api/assets/")
def get_asset_or_edits(req):
    aid, _, tail = req.rest.partition("/")
    if tail == "edits":
        return edits_payload_response(req, aid)
    if tail:
        return None  # thumbnail, original… the base serves them
    detail = asset(aid)
    if serves_edits():
        detail["isEdited"] = bool(STATE["edits"]["lists"].get(aid))
    else:
        detail.pop("isEdited", None)
    if aid in STATE["edits"]["live"]:
        detail["livePhotoVideoId"] = f"live-{aid}"
    return Response(detail)


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
    return Response(edits_payload(aid))


@router.prefix("DELETE", "/api/assets/")
def delete_edits(req):
    aid, _, tail = req.rest.partition("/")
    if tail != "edits":
        return None
    if not serves_edits():
        return not_found(f"DELETE {req.path}")
    STATE["edits"]["lists"].pop(aid, None)
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
    if params.get("live"):
        state["live"].add(params["live"])
    if params.get("seed") and params.get("edits"):
        listed = json.loads(params["edits"])
        state["lists"][params["seed"]] = [
            {"id": f"edit-{n}", "action": item["action"], "parameters": item["parameters"]}
            for n, item in enumerate(listed, start=1)
        ]
    return Response({"version": state["version"], "put": state["put"],
                     "live": sorted(state["live"]), "seeded": sorted(state["lists"])})


if __name__ == "__main__":
    main(label="asset_edits")
