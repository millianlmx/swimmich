"""Viewer-zoom stub (L-14 / B-18): the photo grows out of its thumbnail and shrinks
back onto it (`ViewerZoomUITests`).

    python3 UITests/stubs/immich_stub_viewer_zoom.py 8421

The scenario FILMS the simulator and finds the photo in each frame by its colour,
so what the stub serves is chosen for that:

    * ONE photo at a time is MARKED. Its thumbnail (`?size=thumbnail`) is pure
      magenta (255,0,255), 40×30 — 48×27 for the video, at the 16:9 of its file —
      and its preview/original (`?size=preview`) pure yellow (255,255,0), 80×60.
      Magenta + yellow never share a pixel, and any mix of the two (the
      cross-fade) stays on the line R=255, G+B=255.
    * every other photo is a neutral grey (R=G=B between 90 and 170, by rank), so
      the marked one is the only coloured component on screen.

`POST /control/mark {"id": …, "previewDelay": seconds}` arms the marked photo for
the NEXT launch (the app caches by URL; the scenario relaunches). `/__reset` puts
back "no mark" and a delay of 0. Every image is generated (never pasted: THE
THUMBNAIL TRAP, see `immich_stub_base.png`) and served `Cache-Control: no-store`.

The library: 150 photos of one day, ids `cccccccc-1414-4141-8141-<n:012d>`, ratio
4:3 (EXIF 4000×3000), served by the timeline, by ONE album (`ALBUM`) and by every
search (the album's own `albumIds` search included). Roles:

    n    role        what it is
    1    PHOTO       mine
    2    PARTNER     owned by someone else: the viewer offers no favorite
    3    SLOW        a photo like the others, meant to be marked with a preview delay
    4    VIDEO       12 s, 16:9 (EXIF 480×270, as the served file), `/video/playback`
                     is the green fixture, with ranges
    5    ARCHIVABLE  a photo like the others; the scenario archives it
    75   FAR         more than three screens below the first row on a 3-column grid

Non-regression (AC-27.8): the Trash (`isTrashed=true`) holds three grey photos
(n 101-103) and the folder `/x` three more (n 111-113).
"""
import os
import re
import time
import zlib

from immich_stub_base import (ME, STATE, Response, asset, bucket_payload, main, new_thumbhash,
                              router)

DAY = "2026-09-01"
ALBUM = "22222222-2222-4222-8222-000000001414"
ALBUM_NAME = "Zoom Album"
PARTNER_ID = "99999999-9999-4999-8999-999999999999"

COUNT = 150
IDS = [f"cccccccc-1414-4141-8141-{n:012d}" for n in range(1, COUNT + 1)]
PHOTO, PARTNER, SLOW, VIDEO, ARCHIVABLE = IDS[0], IDS[1], IDS[2], IDS[3], IDS[4]
FAR = IDS[74]
TRASHED = IDS[100:103]
FOLDER_PATH = "/x"
FOLDERED = IDS[110:113]

VIDEO_MS = 12_000
VIDEO_SIZE = (480, 270)
VIDEO_RATIO = VIDEO_SIZE[0] / VIDEO_SIZE[1]
PHOTO_RATIO = 1.333

MAGENTA = (255, 0, 255)
YELLOW = (255, 255, 0)

NO_STORE = {"Cache-Control": "no-store"}

FIXTURE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "fixtures", "media", "green-16x9-12s.mp4")
try:
    with open(FIXTURE, "rb") as handle:
        VIDEO_BYTES = handle.read()
except OSError as error:  # pragma: no cover - a broken checkout, not a scenario
    raise SystemExit(f"viewer-zoom stub: cannot read {FIXTURE}: {error}")
RANGE = re.compile(r"bytes=(\d*)-(\d*)")


@router.reset
def _restore_mark():
    STATE["mark"] = None
    STATE["previewDelay"] = 0.0


# MARK: - Images


def png_rect(rgb, width, height):
    """A real, decodable `width`×`height` PNG of one colour."""
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind, data):
        payload = kind + data
        return (len(data).to_bytes(4, "big") + payload
                + (zlib.crc32(payload) & 0xFFFFFFFF).to_bytes(4, "big"))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", width.to_bytes(4, "big") + height.to_bytes(4, "big")
                    + bytes((8, 2, 0, 0, 0)))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


def rank(aid):
    return IDS.index(aid) + 1


def grey(aid):
    level = 90 + (rank(aid) * 7) % 81
    return (level, level, level)


def image_for(aid, size):
    """(colour, width, height) of what `size` serves for `aid`."""
    marked = STATE.get("mark") == aid
    if size == "thumbnail":
        width, height = (48, 27) if aid == VIDEO else (40, 30)
        return (MAGENTA if marked else grey(aid)), width, height
    return (YELLOW if marked else grey(aid)), 80, 60


# MARK: - Payloads


def photo_dto(aid):
    """The `AssetResponseDto` of one library photo."""
    dto = asset(aid, day=DAY)
    if aid == PARTNER:
        dto["ownerId"] = PARTNER_ID
    if aid == VIDEO:
        width, height = VIDEO_SIZE
        dto.update({
            "type": "VIDEO", "duration": VIDEO_MS, "width": width, "height": height,
            "originalPath": f"/x/{aid}.mp4", "originalFileName": f"{aid[:4]}-{aid[-2:]}.mp4",
            "originalMimeType": "video/mp4",
        })
        dto["exifInfo"]["exifImageWidth"] = width
        dto["exifInfo"]["exifImageHeight"] = height
    return dto


def columns(ids, trashed=False):
    """The columnar day payload of `ids`, ratios and the video/partner rows set."""
    payload = bucket_payload(ids, day=DAY)
    payload["ratio"] = [VIDEO_RATIO if aid == VIDEO else PHOTO_RATIO for aid in ids]
    payload["isImage"] = [aid != VIDEO for aid in ids]
    payload["duration"] = [VIDEO_MS if aid == VIDEO else None for aid in ids]
    payload["ownerId"] = [PARTNER_ID if aid == PARTNER else ME for aid in ids]
    payload["isTrashed"] = [trashed] * len(ids)
    return payload


def search_page():
    return Response({"assets": {
        "count": COUNT,
        "items": [photo_dto(aid) for aid in IDS],
        "nextPage": None,
        "nextCursor": None,
    }})


# MARK: - Control


@router.post("/control/mark")
def mark(req):
    """Arms the marked photo (and the delay of its preview) for the next launch."""
    STATE["mark"] = req.body.get("id")
    STATE["previewDelay"] = float(req.body.get("previewDelay") or 0)
    # Rotated with the mark: the app's caches key on the URL.
    STATE["thumbhash"] = new_thumbhash()
    return Response({"mark": STATE["mark"], "previewDelay": STATE["previewDelay"]})


# MARK: - Timeline


@router.get("/api/timeline/buckets")
def buckets(req):
    if req.params.get("isTrashed") == "true":
        return Response([{"timeBucket": DAY, "count": len(TRASHED)}])
    return Response([{"timeBucket": DAY, "count": COUNT}])


@router.get("/api/timeline/bucket")
def bucket(req):
    if req.params.get("timeBucket") != DAY:
        return None
    if req.params.get("isTrashed") == "true":
        return Response(columns(TRASHED, trashed=True))
    return Response(columns(IDS))


# MARK: - Album, folders, search


def album_dto():
    return {
        "id": ALBUM, "albumName": ALBUM_NAME, "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": None, "shared": False, "hasSharedLink": False,
        "assetCount": COUNT, "isActivityEnabled": False, "order": "desc", "albumUsers": [],
    }


@router.get("/api/albums")
def albums(req):
    return Response([album_dto()])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if not req.rest or "/" in req.rest:
        return None  # a sub-resource: the shell's own answer
    if req.rest == ALBUM:
        return Response(album_dto())
    return Response({"error": "not found", "path": req.path}, status=404)


@router.post("/api/search/metadata")
def metadata_search(req):
    return search_page()


@router.post("/api/search/smart")
def smart_search(req):
    return search_page()


@router.get("/api/view/folder/unique-paths")
def unique_paths(req):
    return Response([FOLDER_PATH])


@router.get("/api/view/folder")
def folder_assets(req):
    if req.params.get("path") != FOLDER_PATH:
        return Response([])
    return Response([photo_dto(aid) for aid in FOLDERED])


# MARK: - Assets, images, video


@router.prefix("GET", "/api/assets/")
def asset_routes(req):
    parts = req.rest.split("/")
    aid = parts[0]
    if aid not in IDS:
        return None  # the shell's own answer
    tail = parts[1:]
    if tail == [""] or not tail:
        return Response(photo_dto(aid))
    if tail == ["thumbnail"]:
        size = req.params.get("size", "thumbnail")
        if size != "thumbnail" and STATE.get("mark") == aid and STATE.get("previewDelay"):
            # Held in this handler: the server is threaded, only this request waits.
            time.sleep(STATE["previewDelay"])
        colour, width, height = image_for(aid, size)
        return Response(png_rect(colour, width, height), ctype="image/png", headers=NO_STORE)
    if tail == ["original"]:
        colour, width, height = image_for(aid, "original")
        return Response(png_rect(colour, width, height), ctype="image/png", headers=NO_STORE)
    if aid == VIDEO and tail == ["video", "playback"]:
        return playback(req)
    return None


def playback(req):
    """The green fixture, with ranges: AVFoundation probes with `bytes=0-1`."""
    total = len(VIDEO_BYTES)
    header = (req.headers.get("Range") or "").strip()
    req.note(range=header or None, bytes=total)
    match = RANGE.fullmatch(header) if header else None
    headers = {"Accept-Ranges": "bytes", "Cache-Control": "no-store"}
    if match is None:
        return Response(VIDEO_BYTES, ctype="video/mp4", headers=headers)
    start = int(match.group(1)) if match.group(1) else 0
    end = int(match.group(2)) if match.group(2) else total - 1
    end = min(end, total - 1)
    if start > end or start >= total:
        return Response(b"", status=416, ctype="video/mp4",
                        headers={**headers, "Content-Range": f"bytes */{total}"})
    return Response(
        VIDEO_BYTES[start:end + 1], status=206, ctype="video/mp4",
        headers={**headers, "Content-Range": f"bytes {start}-{end}/{total}"},
    )


if __name__ == "__main__":
    main(label="viewer-zoom")
