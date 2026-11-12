"""Immich API stub for the Reduce Motion scenarios (`ReduceMotionUITests`, lot L-18, AC-33, AC-162..AC-171).

    python3 UITests/stubs/immich_stub_reduce_motion.py 8421

Built on `immich_stub_base.py` (the OAuth handshake of the shell signs the app in).
It serves what every full-screen presentation of the app needs to be opened:

* a TIMELINE of 90 photos over 30 days (3 a day, newest day first), ids
  `aaaaaaaa-1111-4111-8111-000000000001` .. `…090` — enough to scroll, pinch and
  to have a tile half off the screen;
* an ALBUM of 40 photos with a cover (`albumThumbnailAssetId` is its first photo);
* TWO MEMORIES of 3 photos each (2022, 2023);
* TWO TRASHED photos (`isTrashed=true` on the timeline routes);
* an INDIVIDUAL SHARED LINK of 3 photos, addressed by the fixed key `SHARED_KEY`
  (`GET /api/shared-links/me?key=…`);
* one NAMED PERSON without a birth date;
* `GET /__reset?slow=1`: every `GET /api/assets/{id}/thumbnail` then waits 3 s
  before answering (a tile stays in its waiting state, which is what the shimmer
  scenario films). A plain `/__reset` restores the immediate answer.

Thumbnails and originals are the shell's own (`png()`, `Cache-Control: no-store`).
"""
import time

import immich_stub_base as base
from immich_stub_base import (
    ME, STATE, Response, asset, bucket_payload, main, png, router,
)

# MARK: - Fixtures


def uid(prefix, n, tail="1818-4818-8818"):
    return f"{prefix}-{tail}-{n:012d}"


DAYS = 30
PER_DAY = 3
SLOW_DELAY = 3.0

# Ids carry the shell's own shape (`aaaaaaaa-1111-4111-8111-…`): the first six are
# the shell's six photos, so a sibling scenario's identifiers read the same way.
TIMELINE = [f"aaaaaaaa-1111-4111-8111-{n:012d}" for n in range(1, DAYS * PER_DAY + 1)]


def day_of(index):
    """The day of photo `index`: 3 a day, the newest (2026-09-30) first."""
    return f"2026-09-{30 - index // PER_DAY:02d}"


TIMELINE_BY_DAY = {}
for _index, _id in enumerate(TIMELINE):
    TIMELINE_BY_DAY.setdefault(day_of(_index), []).append(_id)
DAY_LIST = list(TIMELINE_BY_DAY)  # newest first

ALBUM = "22222222-2222-4222-8222-000000001818"
ALBUM_ASSETS = [uid("a1b2c3d4", n) for n in range(1, 41)]

MEMORY_OLD = uid("eeeeeeee", 1)
MEMORY_NEW = uid("eeeeeeee", 2)
MEMORY_ASSETS = {
    MEMORY_OLD: [uid("bbbbbbbb", n) for n in (1, 2, 3)],
    MEMORY_NEW: [uid("bbbbbbbb", n) for n in (4, 5, 6)],
}
MEMORY_YEAR = {MEMORY_OLD: 2022, MEMORY_NEW: 2023}
MEMORY_DAY = "2024-07-01"

TRASHED = [uid("cccccccc", 1), uid("cccccccc", 2)]
TRASH_DAY = "2026-08-15"

SHARED_KEY = "reduce-motion-shared-key-1818"
SHARED_ASSETS = [uid("ffffffff", n) for n in (1, 2, 3)]
SHARED_DAY = "2026-07-04"

PERSON = uid("99999999", 1, "1818-4818-8818")
PERSON_NAME = "Ada"

STAMP = "2026-01-01T00:00:00.000Z"


def person_dto():
    return {"id": PERSON, "name": PERSON_NAME, "birthDate": None, "thumbnailPath": "",
            "isHidden": False, "color": "#4a5aef", "isFavorite": False, "updatedAt": STAMP}


@router.reset
def fresh():
    STATE["slow"] = False


fresh()  # a request before the first `/__reset` must not find the key missing


# MARK: - /__reset?slow=1
# The shell answers `/__reset` itself (before any route) and has no hook for its
# query: wrap its control handler, keep its answer, then read `slow` from the query.

_shell_control = base.StubHandler._control


def _control(self, path, query):
    response = _shell_control(self, path, query)
    if path == "/__reset":
        params = dict(base.parse_qsl(query, keep_blank_values=True))
        STATE["slow"] = params.get("slow") == "1"
    return response


base.StubHandler._control = _control


@router.prefix("GET", "/api/assets/")
def slow_thumbnail(req):
    """With `slow=1`, a thumbnail waits 3 s; everything else is the shell's own."""
    if STATE.get("slow") and req.rest.endswith("/thumbnail"):
        time.sleep(SLOW_DELAY)
    return None


# MARK: - Timeline and trash


def _trashed(params):
    return params.get("isTrashed") == "true"


@router.get("/api/timeline/buckets")
def buckets(req):
    if _trashed(req.params):
        return Response([{"timeBucket": TRASH_DAY, "count": len(TRASHED)}])
    if req.params.get("userId") or req.params.get("visibility") in ("archive", "locked"):
        return Response([])
    return Response([{"timeBucket": day, "count": len(ids)} for day, ids in TIMELINE_BY_DAY.items()])


@router.get("/api/timeline/bucket")
def bucket(req):
    if _trashed(req.params):
        payload = bucket_payload(TRASHED, day=TRASH_DAY)
        payload["isTrashed"] = [True] * len(TRASHED)
        return Response(payload)
    day = req.params.get("timeBucket")
    return Response(bucket_payload(TIMELINE_BY_DAY.get(day, []), day=day or DAY_LIST[0]))


# MARK: - Albums


def album_dto():
    return {
        "id": ALBUM, "albumName": "Reduce Motion Album", "description": "",
        "createdAt": STAMP, "updatedAt": STAMP,
        "albumThumbnailAssetId": ALBUM_ASSETS[0], "shared": False, "hasSharedLink": False,
        "assetCount": len(ALBUM_ASSETS), "isActivityEnabled": False, "order": "desc",
        "ownerId": ME, "albumUsers": [],
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
def metadata(req):
    body = req.body or {}
    if body.get("albumIds") == [ALBUM]:
        ids, day = ALBUM_ASSETS, "2026-06-01"
    elif body.get("personIds") == [PERSON]:
        ids, day = TIMELINE[:3], day_of(0)
    else:
        ids, day = [], day_of(0)
    items = [asset(aid, day) for aid in ids]
    return Response({"assets": {"count": len(items), "items": items,
                                "nextPage": None, "nextCursor": None}})


# MARK: - Memories


def memory_dto(memory_id):
    at = f"{MEMORY_YEAR[memory_id]}-11-12T00:00:00.000Z"
    return {
        "id": memory_id, "createdAt": at, "updatedAt": at, "memoryAt": at, "ownerId": ME,
        "type": "on_this_day", "data": {"year": MEMORY_YEAR[memory_id]},
        "assets": [asset(aid, MEMORY_DAY) for aid in MEMORY_ASSETS[memory_id]],
        "isSaved": False, "showAt": None, "hideAt": None, "seenAt": None, "deletedAt": None,
    }


@router.get("/api/memories")
def memories(req):
    return Response([memory_dto(MEMORY_NEW), memory_dto(MEMORY_OLD)])


@router.get("/api/memories/statistics")
def memories_statistics(req):
    return Response({"total": len(MEMORY_ASSETS)})


@router.prefix("GET", "/api/memories/")
def memory_detail(req):
    if req.rest in MEMORY_ASSETS:
        return Response(memory_dto(req.rest))
    return Response({"error": "not found", "path": req.path}, status=404)


# MARK: - The named person


@router.get("/api/people")
def people(req):
    return Response({"people": [person_dto()], "hidden": 0, "total": 1, "hasNextPage": False})


@router.prefix("GET", "/api/people/")
def one_person(req):
    pid, _, tail = req.rest.partition("/")
    if pid != PERSON:
        return None
    if tail == "statistics":
        return Response({"assets": 3})
    if tail == "thumbnail":
        return Response(png(pid), ctype="image/png", headers={"Cache-Control": "no-store"})
    return Response(person_dto())


# MARK: - The individual shared link


def shared_link_dto():
    return {
        "id": "link-reduce-motion", "description": None, "password": None,
        "userId": ME, "key": SHARED_KEY, "type": "INDIVIDUAL",
        "createdAt": STAMP, "expiresAt": None,
        "assets": [asset(aid, SHARED_DAY) for aid in SHARED_ASSETS],
        "album": None, "allowUpload": False, "allowDownload": True, "showMetadata": True,
        "slug": None,
    }


@router.get("/api/shared-links/me")
def shared_link(req):
    if req.params.get("key") != SHARED_KEY:
        return Response({"message": "Invalid share key", "error": "Unauthorized",
                         "statusCode": 401}, status=401)
    return Response(shared_link_dto())


if __name__ == "__main__":
    main(label="reduce-motion")
