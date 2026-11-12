"""Immich API stub for the VoiceOver-labels scenario (`VoiceOverLabelsUITests`).

The OAuth handshake, the server configuration, the current user and the real PNG
thumbnails come from `immich_stub_base`. This file adds what the screens of lot
L-19 (AC-34, "every button announces its action") need on top of it, and nothing
the scenario does not read:

    python3 UITests/stubs/immich_stub_voiceover.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/voiceover.uitest.log \\
        UITests/stubs/immich_stub_voiceover.py VoiceOverLabelsUITests/<test> --erase

* TIMELINE — one day (2024-07-29) of TWO assets: the PHOTO (taken at 10:00, in
  Lyon, rated 3) and the VIDEO (taken at 08:00, so it is the 2nd tile of the
  descending timeline and the 2nd cell of the viewer's filmstrip: "Photo 1 of 2",
  "Video 2 of 2"). Both ids are the shell's own first two timeline ids, so the
  base's `/thumbnail` and `/original` routes serve their generated PNGs. The
  detail route (`GET /api/assets/<id>`) is answered here for both: the photo
  carries `exifInfo.rating = 3` (the info panel's rating bar then has a current
  star), the video is a real `VIDEO` whose playback route
  (`/video/playback`) serves the fixture MP4 with `Range` support, exactly like
  `immich_stub_video_player.py` (without it the video page never shows its
  transport). `PUT /api/assets/<id>` answers the viewer's heart with the value
  sent, so its label can follow the flipped state.
* MAP — `GET /api/map/markers`: a marker WITH a place (Sydney, New South Wales,
  Australia) and a marker WITHOUT one (`city`, `state`, `country` all null). They
  are on two continents, so they do not cluster at the initial framing. Their
  thumbnails are the base's generated PNGs.
* MEMORIES — `GET /api/memories`: one `on_this_day` memory of two photos (shape of
  `immich_stub_memories.memory_dto`).
* PEOPLE — one person (`GET /api/people`, `/<id>/statistics`, `/<id>/thumbnail`,
  `PUT /api/people/<id>`) and the faces grid of its card (`POST
  /api/search/metadata` with `personIds`).
* PARTNERS — one outgoing partner (`direction=shared-by`), none incoming
  (`direction=shared-with`); `GET /api/partners` answers 400 without `direction`
  like the real server.
* SHARED LINKS — `GET /api/shared-links`: one link.
* ALBUM — "Voiceover Album" (`GET /api/albums`, `/api/albums/<id>`): two
  geotagged photos (`POST /api/search/metadata` with `albumIds`), the activity
  feed enabled (`GET /api/activities` empty, `/api/activities/statistics` zeros).

Every image served is GENERATED (`png()` of the base, zlib): see THE THUMBNAIL
TRAP in `immich_stub_base`, nothing is pasted. The MP4 is the committed fixture
`UITests/stubs/fixtures/media/green-16x9-12s.mp4`, read once at import.

Everything the base serves is kept: any other id or tail falls through to it.
"""
import os
import re

from immich_stub_base import (
    ME, Response, asset, bucket_payload, main, png, router,
)

# MARK: - Fixtures (recopied in `VoiceOverLabelsUITests`)

DAY = "2024-07-29"
PHOTO_STAMP = f"{DAY}T10:00:00.000Z"
VIDEO_STAMP = f"{DAY}T08:00:00.000Z"

# The shell's first two timeline ids: its generated PNGs already answer them.
PHOTO = "aaaaaaaa-1111-4111-8111-000000000001"
VIDEO = "aaaaaaaa-1111-4111-8111-000000000002"
TIMELINE = [PHOTO, VIDEO]  # descending: the photo (10:00) first, the video (08:00) second

PHOTO_CITY = "Lyon"
PHOTO_COUNTRY = "France"
PHOTO_RATING = 3

# Duration in MILLISECONDS (the Immich unit): the length of the MP4 fixture.
VIDEO_MS = 12_000
VIDEO_SIZE = (480, 270)

FIXTURE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "fixtures", "media", "green-16x9-12s.mp4")
try:
    with open(FIXTURE, "rb") as handle:
        VIDEO_BYTES = handle.read()
except OSError as error:  # pragma: no cover - a broken checkout, not a scenario
    raise SystemExit(f"voiceover stub: cannot read {FIXTURE}: {error}")

# `bytes=a-b`, `bytes=a-` and `bytes=-n` are all legal; AVFoundation sends the
# first two.
RANGE = re.compile(r"bytes=(\d*)-(\d*)")

# Two markers on two continents. The first names its place, the second names none.
MARKER_PLACE = "dddddddd-2222-4222-8222-000000000001"
MARKER_BARE = "dddddddd-2222-4222-8222-000000000002"
MARKERS = [
    {"id": MARKER_PLACE, "lat": -33.8688, "lon": 151.2093,
     "city": "Sydney", "state": "New South Wales", "country": "Australia"},
    {"id": MARKER_BARE, "lat": 48.8584, "lon": 2.2945,
     "city": None, "state": None, "country": None},
]

# The memory and its two photos (taken on the memory's day, 2022).
MEMORY = "eeeeeeee-4444-4444-8444-000000000001"
MEMORY_PHOTOS = ["bbbbbbbb-3333-4333-8333-000000000001", "bbbbbbbb-3333-4333-8333-000000000002"]
MEMORY_DAY = "2022-07-29"

PERSON = "eeeeeeee-5555-4555-8555-000000000001"
PERSON_NAME = "Ada Lovelace"
PERSON_ASSETS = 3

OUTGOING = "bbbbbbbb-2222-4222-8222-000000000002"
OUTGOING_NAME = "Outgoing Olive"

LINK = "cccccccc-6666-4666-8666-000000000001"
LINK_KEY = "c3R1Yi1rZXk"  # base64url of "stub-key"

ALBUM = "22222222-2222-4222-8222-000000000019"
ALBUM_NAME = "Voiceover Album"
ALBUM_DAY = "2024-08-02"
# Two stops more than 4 km apart, both geotagged (the Road Trip clusterer's rule).
ALBUM_ASSETS = [
    ("bbbbbbbb-4444-4444-8444-000000000001", 48.8566, 2.3522, "Paris", "France",
     f"{ALBUM_DAY}T09:00:00.000Z"),
    ("bbbbbbbb-4444-4444-8444-000000000002", 48.8049, 2.1204, "Versailles", "France",
     f"{ALBUM_DAY}T14:00:00.000Z"),
]


# MARK: - Payload builders


def _restamp(dto, stamp):
    for key in ("localDateTime", "createdAt", "fileCreatedAt", "fileModifiedAt", "updatedAt"):
        dto[key] = stamp
    dto["exifInfo"]["dateTimeOriginal"] = stamp
    return dto


def photo_dto():
    """The photo's `AssetResponseDto`: placed in Lyon and rated 3."""
    dto = _restamp(asset(PHOTO, day=DAY), PHOTO_STAMP)
    dto["exifInfo"].update({
        "city": PHOTO_CITY, "state": None, "country": PHOTO_COUNTRY,
        "latitude": 45.764, "longitude": 4.8357, "rating": PHOTO_RATING,
    })
    return dto


def video_dto():
    """The video as a full `AssetResponseDto` (built from the shell's photo DTO so
    every required key is present, then overridden where a video differs)."""
    dto = _restamp(asset(VIDEO, day=DAY), VIDEO_STAMP)
    width, height = VIDEO_SIZE
    dto.update({
        "type": "VIDEO", "duration": VIDEO_MS, "width": width, "height": height,
        "originalPath": f"/x/{VIDEO}.mp4",
        "originalFileName": f"{VIDEO[:4]}-{VIDEO[-2:]}.mp4",
        "originalMimeType": "video/mp4",
    })
    return dto


def album_asset(aid, lat, lon, city, country, stamp):
    dto = _restamp(asset(aid, day=ALBUM_DAY), stamp)
    dto["exifInfo"].update({
        "latitude": lat, "longitude": lon, "city": city, "state": None, "country": country,
    })
    return dto


def album_dto():
    """A fresh dict per call (the app and the scenario must never share one)."""
    return {
        "id": ALBUM, "albumName": ALBUM_NAME, "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": ALBUM_ASSETS[0][0], "shared": False, "hasSharedLink": False,
        "assetCount": len(ALBUM_ASSETS), "isActivityEnabled": True, "order": "desc",
        "albumUsers": [],
    }


def memory_dto():
    """One "on this day" memory (shape of `immich_stub_memories.memory_dto`)."""
    stamp = f"{MEMORY_DAY}T00:00:00.000Z"
    return {
        "id": MEMORY,
        "createdAt": stamp, "updatedAt": stamp,
        "memoryAt": stamp, "ownerId": ME, "type": "on_this_day",
        "data": {"year": 2022},
        "assets": [asset(aid, day=MEMORY_DAY) for aid in MEMORY_PHOTOS],
        "isSaved": False,
        "showAt": None, "hideAt": None, "seenAt": None, "deletedAt": None,
    }


def person_dto():
    """One `PersonResponseDto` — every non-optional field the app decodes."""
    return {
        "id": PERSON, "name": PERSON_NAME, "birthDate": None, "thumbnailPath": "",
        "isHidden": False, "color": "#4a5aef", "isFavorite": False,
        "updatedAt": "2026-09-01T10:00:00.000Z",
    }


def partner_dto(uid, name, email):
    return {
        "id": uid, "name": name, "email": email, "profileImagePath": "",
        "avatarColor": "primary", "profileChangedAt": "2026-01-01T00:00:00.000Z",
        "inTimeline": False,
    }


def link_dto():
    return {
        "id": LINK, "description": "Voiceover link", "password": None,
        "userId": ME, "key": LINK_KEY, "type": "ALBUM",
        "createdAt": "2026-01-01T00:00:00.000Z", "expiresAt": None,
        "assets": [], "album": None,
        "allowUpload": False, "allowDownload": True, "showMetadata": True,
        "slug": None,
    }


def page(items):
    return Response({"assets": {
        "count": len(items), "items": items, "nextPage": None, "nextCursor": None,
    }})


# MARK: - Timeline


@router.get("/api/timeline/buckets")
def buckets(req):
    return Response([{"timeBucket": DAY, "count": len(TIMELINE)}])


@router.get("/api/timeline/bucket")
def bucket(req):
    """The day: the photo, then the video taken two hours earlier. The columnar
    payload is zipped by index, so every array keeps `len(TIMELINE)` entries."""
    payload = bucket_payload(TIMELINE, day=DAY)
    for key in ("fileCreatedAt", "createdAt"):
        payload[key] = [PHOTO_STAMP, VIDEO_STAMP]
    payload["isImage"] = [True, False]
    payload["duration"] = [None, VIDEO_MS]
    payload["ratio"] = [4 / 3, VIDEO_SIZE[0] / VIDEO_SIZE[1]]
    payload["city"] = [PHOTO_CITY, None]
    payload["country"] = [PHOTO_COUNTRY, None]
    payload["latitude"] = [45.764, None]
    payload["longitude"] = [4.8357, None]
    return Response(payload)


@router.prefix("GET", "/api/assets/")
def asset_route(req):
    """The two timeline assets' details, and the video's playback bytes. `None` for
    everything else (thumbnails, originals, any other id), which is the shell's."""
    parts = req.rest.split("/")
    if parts == [PHOTO]:
        return Response(photo_dto())
    if parts == [VIDEO]:
        return Response(video_dto())
    if parts != [VIDEO, "video", "playback"]:
        return None

    # `206` + `Content-Range` + `Accept-Ranges` is not politeness: AVFoundation
    # probes a progressive MP4 with `Range: bytes=0-1` and stops there if the
    # answer is a plain `200`.
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
    return Response(VIDEO_BYTES[start:end + 1], status=206, ctype="video/mp4",
                    headers={**headers, "Content-Range": f"bytes {start}-{end}/{total}"})


@router.prefix("PUT", "/api/assets/")
def update_asset(req):
    """`PUT /api/assets/<id>` — the viewer's heart. Answered with the full DTO carrying
    the value sent (the app adopts the answer): the heart's label then follows the
    state the scenario flipped. `None` for any other id, which is the shell's."""
    if "/" in req.rest:
        return None
    build = {PHOTO: photo_dto, VIDEO: video_dto}.get(req.rest)
    if build is None:
        return None
    sent = (req.body or {}).get("isFavorite")
    req.note(isFavoriteSent=sent)
    dto = build()
    if sent is not None:
        dto["isFavorite"] = bool(sent)
    return Response(dto)


# MARK: - Map


@router.get("/api/map/markers")
def map_markers(req):
    return Response(MARKERS)


# MARK: - Memories


@router.get("/api/memories")
def memories(req):
    return Response([memory_dto()])


# MARK: - People


@router.get("/api/people")
def people(req):
    return Response({"people": [person_dto()], "hidden": 0, "total": 1, "hasNextPage": False})


@router.prefix("GET", "/api/people/")
def one_person(req):
    """The row's count and avatar; `None` for anything else (the shell's answer)."""
    pid, _, tail = req.rest.partition("/")
    if pid != PERSON:
        return None
    if tail == "statistics":
        return Response({"assets": PERSON_ASSETS})
    if tail == "thumbnail":
        return Response(png(pid), ctype="image/png", headers={"Cache-Control": "no-store"})
    return Response(person_dto()) if not tail else None


@router.prefix("PUT", "/api/people/")
def update_person(req):
    if req.rest != PERSON:
        return None
    return Response(person_dto())


# MARK: - Search (a person's faces grid, an album's assets)


@router.post("/api/search/metadata")
def search_metadata(req):
    body = req.body or {}
    if ALBUM in (body.get("albumIds") or []):
        return page([album_asset(*entry) for entry in ALBUM_ASSETS])
    if body.get("personIds"):
        return page([asset(aid) for aid in TIMELINE])
    return page([])


# MARK: - Albums


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


@router.get("/api/activities")
def activities(req):
    return Response([])


@router.get("/api/activities/statistics")
def activity_statistics(req):
    return Response({"comments": 0, "likes": 0})


# MARK: - Partners and shared links


@router.get("/api/partners")
def partners(req):
    direction = req.params.get("direction")
    req.note(direction=direction)
    if direction == "shared-by":
        return Response([partner_dto(OUTGOING, OUTGOING_NAME, "olive@example.com")])
    if direction == "shared-with":
        return Response([])
    return Response(
        {"error": "Bad Request", "message": ["direction must be one of: shared-by, shared-with"]},
        status=400,
    )


@router.get("/api/shared-links")
def shared_links(req):
    return Response([link_dto()])


if __name__ == "__main__":
    main(label="voiceover")
