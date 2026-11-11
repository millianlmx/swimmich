"""JPEG XL stub (L-05 / B-9): a server that generates its thumbnails, previews
and originals as JPEG XL.

    python3 UITests/stubs/immich_stub_jpeg_xl.py 8421

The bytes are REAL JPEG XL files (`fixtures/jxl/`, see its README), read at
import: a missing file kills the stub at startup instead of serving a tile that
looks broken for the wrong reason. Three of the timeline's photos play a role,
the other three stay the shell's PNGs (the control of AC-103):

    JXL_PHOTO       …0001  thumbnail 200×200, preview 1024×631, original 1600×1096
    BROKEN_JXL      …0003  thumbnail, preview and original are TRUNCATED
    THUMB_ONLY_JXL  …0004  VALID thumbnail, TRUNCATED preview and original — the
                           tier-0.5 trap: the grid has decoded and cached the
                           thumbnail when the viewer opens, then the preview fails

TRUNCATED is the two signature bytes `ff 0a` alone: no size header, so ImageIO
cannot build even a partial image from it (a longer prefix can).

Everything is served `Cache-Control: no-store`: the app's image caches key on the
URL, and a body cached by an earlier run would be replayed as-is.

`GET /control/unreachable?on=1|0` makes every `/api/…` request answer 503 (and
be logged with `dropped=True`): the server "goes down" while the app keeps
running, which is how a scenario proves an offline copy is read from disk. It is
a router route, not `/__…`: the base dispatches every `/__…` path to its own
control handler, which answers 404 to what it does not know.
"""
import os

from immich_stub_base import Response, STATE, TIMELINE_ASSETS, asset, main, router

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "jxl")


def _read(name):
    with open(os.path.join(FIXTURES, name), "rb") as handle:
        return handle.read()


THUMBNAIL = _read("thumbnail-200x200.jxl")
PREVIEW = _read("preview-1024x631.jxl")
ORIGINAL = _read("original-1600x1096.jxl")
TRUNCATED = PREVIEW[:2]

JXL_PHOTO = TIMELINE_ASSETS[0]
BROKEN_JXL = TIMELINE_ASSETS[2]
THUMB_ONLY_JXL = TIMELINE_ASSETS[3]

# id → (thumbnail, preview, original, originalFileName)
PHOTOS = {
    JXL_PHOTO: (THUMBNAIL, PREVIEW, ORIGINAL, "jxl-photo.jxl"),
    BROKEN_JXL: (TRUNCATED, TRUNCATED, TRUNCATED, "jxl-broken.jxl"),
    THUMB_ONLY_JXL: (THUMBNAIL, TRUNCATED, TRUNCATED, "jxl-thumb-only.jxl"),
}

ALBUM = "22222222-2222-4222-8222-000000000501"
ALBUM_NAME = "JXL Album"

NO_STORE = {"Cache-Control": "no-store"}


def jxl_asset(aid):
    """`AssetResponseDto` of a JPEG XL photo: the shell's, with the file facts a
    real server reports for a JPEG XL original."""
    dto = asset(aid)
    original = PHOTOS[aid][2]
    dto["originalFileName"] = PHOTOS[aid][3]
    dto["originalMimeType"] = "image/jxl"
    dto["originalPath"] = f"/x/{PHOTOS[aid][3]}"
    dto["width"] = 1600
    dto["height"] = 1096
    dto["exifInfo"]["exifImageWidth"] = 1600
    dto["exifInfo"]["exifImageHeight"] = 1096
    dto["exifInfo"]["fileSizeInByte"] = len(original)
    return dto


def album_dto():
    return {
        "id": ALBUM,
        "albumName": ALBUM_NAME,
        "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": None,
        "shared": False,
        "hasSharedLink": False,
        "assetCount": 2,
        "isActivityEnabled": False,
        "order": "desc",
        "albumUsers": [],
    }


# MARK: - Panne simulée

STATE["unreachable"] = False


@router.reset
def _restore_reachability():
    STATE["unreachable"] = False


@router.get("/control/unreachable")
def set_unreachable(req):
    STATE["unreachable"] = req.params.get("on") == "1"
    return Response({"unreachable": STATE["unreachable"]})


_handle = router.handle


def _gate(req):
    if STATE["unreachable"] and req.path.startswith("/api/"):
        req.note(dropped=True)
        return Response(b"", status=503, ctype="application/octet-stream")
    return _handle(req)


router.handle = _gate


# MARK: - Images


@router.prefix("GET", "/api/assets/")
def asset_routes(req):
    parts = req.rest.split("/")
    aid = parts[0]
    if aid not in PHOTOS:
        return None  # the shell's PNGs and `statistics`-style routes
    tail = parts[1] if len(parts) > 1 else ""
    thumbnail, preview, original, _ = PHOTOS[aid]
    if tail == "":
        return Response(jxl_asset(aid))
    if tail == "thumbnail":
        body = preview if req.params.get("size") == "preview" else thumbnail
        return Response(body, ctype="image/jxl", headers=NO_STORE)
    if tail == "original":
        return Response(original, ctype="image/jxl", headers=NO_STORE)
    return None


# MARK: - Album and search


@router.get("/api/albums")
def albums(req):
    return Response([album_dto()])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if not req.rest or "/" in req.rest:
        return None
    if req.rest == ALBUM:
        return Response(album_dto())
    return Response({"error": "not found", "path": req.path}, status=404)


def _page(ids):
    return Response({"assets": {
        "count": len(ids),
        "items": [jxl_asset(aid) for aid in ids],
        "nextPage": None,
        "nextCursor": None,
    }})


@router.post("/api/search/metadata")
def metadata_search(req):
    if req.body.get("albumIds") == [ALBUM]:
        return _page([JXL_PHOTO, BROKEN_JXL])
    return _page([])


@router.post("/api/search/smart")
def smart_search(req):
    return _page([JXL_PHOTO, BROKEN_JXL])


if __name__ == "__main__":
    main(label="jpeg-xl")
