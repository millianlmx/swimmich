"""Immich API stub for the content-collections scenario (`ContentCollectionsUITests`, lot L-12).

    python3 UITests/stubs/immich_stub_collections.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/collections.uitest.log \\
        UITests/stubs/immich_stub_collections.py ContentCollectionsUITests --erase

WHAT IT IS FOR
    Lot L-12 moved the 15 content collections out of the "Me" sheet: twelve are
    tiles of the Albums tab's Library section, Favorites and Archive are the
    Photos tab's filter, Places is the Search tab's Explore mode. Every one of
    them needs ONE element of its own on this server, so a scenario can tell
    "the collection opened" from "some grid appeared". Built on
    `immich_stub_base` ONLY (the router is global: importing another feature
    stub would register its routes here too); the shapes are recopied from the
    stubs named below, never imported.

THE TIMELINE (one month, `2026-09-01`, seven photos + one locked)
* 2 ordinary (`aaaaaaaa…01-02`), 2 favorites (`fafafafa…`), 2 archived
  (`acacacac…`), 1 in the trash (`dddddddd…01`), 1 locked (`1c1c1c1c…01`).
* BOTH routes (`timeline/buckets` for the month's count, `timeline/bucket` for
  its content) filter on `isFavorite`, `visibility` and `isTrashed`, repeating
  the filters like the real server. `isTrashed` absent or `false`: only photos
  that are NOT in the trash; `isTrashed=true`: only the trashed one. There is no
  exception for the Trash screen: an app that reads a period without
  `isTrashed=true` shows the month's live photos there and fails the scenario.
* `visibility` absent: timeline and archive (never locked). `visibility=locked`
  answers only while the session is elevated (`POST /api/auth/session/unlock`).
* `orderBy=takenAt|createdAt` (Recently Taken / Recently Added) answers a day of
  its own (`bbbb…`, `cccc…`), as `immich_stub_recent.py` does.
* `userId=<partner>` answers the partner's one photo, month `2026-08-01`.
  The partner is "shared with me" with `inTimeline` false: the main timeline
  (`withPartners=true`) never carries that photo.

THE COLLECTIONS' OWN DATA
* one owned album (`album_dto` of `immich_stub_album_roles.py`, v2.x shape),
  its photos by `POST /api/search/metadata` with `albumIds`;
  `/control/albums?mode=normal|error|empty` (`error`: 500 on both reads of
  `GET /api/albums`; `empty`: `[]`; `/__reset` puts `normal` back);
* two people (`immich_stub_people_search.py`), one photo each by
  `POST /api/search/metadata` with `personIds`;
* one root tag; one stack of two photos; one partner "shared with me";
  folders `/Photos` and `/Photos/Trip`, one photo each; one duplicate group;
  two cities (`GET /api/search/cities`) with their `POST /api/search/statistics`;
* the locked folder (`immich_stub_locked_folder.py`): `GET /api/auth/status`
  starts at `{pinCode: true, isElevated: false}`, PIN `123456`.

CONTROLS (GET, outside `/__` and `/api/`: the base answers `/__…` itself, and a
control route is logged in `/__requests` like any request)
    /control/albums?mode=normal|error|empty
    /control/user?id=<uuid>&email=<e>&name=<n>
        replaces the signed-in user — `GET /api/users/me` and the OAuth callback —
        both as an ADMINISTRATOR (which is the default user too).
"""
from immich_stub_base import (
    LOGIN, ME, ME_USER, STATE, Response, asset, bucket_payload, main, png, router,
)

DAY = "2026-09-01"
PIN = "123456"
NO_CONTENT = Response(b"", status=204)


def uid(prefix, n, tail="1111-4111-8111"):
    return f"{prefix}-{tail}-{n:012d}"


# MARK: - The library of the signed-in user

ORDINARY = [uid("aaaaaaaa", n) for n in (1, 2)]
FAVORITES = [uid("fafafafa", n) for n in (1, 2)]
ARCHIVED = [uid("acacacac", n) for n in (1, 2)]
TRASHED = [uid("dddddddd", 1)]
LOCKED = [uid("1c1c1c1c", 1)]


def entry(pid, favorite=False, visibility="timeline", trashed=False):
    return {"id": pid, "favorite": favorite, "visibility": visibility, "trashed": trashed}


LIBRARY = (
    [entry(pid) for pid in ORDINARY]
    + [entry(pid, favorite=True) for pid in FAVORITES]
    + [entry(pid, visibility="archive") for pid in ARCHIVED]
    + [entry(pid, trashed=True) for pid in TRASHED]
    + [entry(pid, visibility="locked") for pid in LOCKED]
)

# Recently Taken / Recently Added: a day of their own each.
TAKEN_DAY, ADDED_DAY = "2024-07-01", "2025-11-20"
TAKEN = [uid("bbbbbbbb", n) for n in (1, 2)]
ADDED = [uid("cccccccc", n) for n in (1, 2)]
AXES = {"takenAt": (TAKEN_DAY, TAKEN), "createdAt": (ADDED_DAY, ADDED)}
RECENT_DAYS = {TAKEN_DAY: TAKEN, ADDED_DAY: ADDED}

# The partner: "shared with me", hidden from the main timeline.
PARTNER = "aaaaaaaa-5555-4555-8555-000000000001"
PARTNER_PHOTO = uid("a5a5a5a5", 1)
PARTNER_DAY = "2026-08-01"

# MARK: - The other collections

ALBUM = uid("a1b2c3d4", 1)
ALBUM_NAME = "Stub Album"

ADA = uid("eeeeeeee", 1, "3333-4333-8333")
ALAN = uid("eeeeeeee", 2, "3333-4333-8333")
PERSON_PHOTOS = {ADA: [uid("e1e1e1e1", 1)], ALAN: [uid("e1e1e1e1", 2)]}

TAG = "7a000000-0000-4000-8000-000000000001"

STACK = uid("57ac0000", 1)
STACK_PHOTOS = [uid("57ac0001", 1), uid("57ac0001", 2)]

FOLDERS = {
    "/Photos": [(uid("dd000001", 1), "photos-1.jpg", 10)],
    "/Photos/Trip": [(uid("dd000002", 1), "trip-1.jpg", 11)],
}

DUPLICATE = uid("d9d9d9d9", 0)
DUPLICATE_PHOTOS = [uid("d9d9d9d9", 1), uid("d9d9d9d9", 2)]

CITIES = [("Lisbon", "Lisboa", "Portugal", uid("c1c1c1c1", 1)),
          ("Porto", "Porto", "Portugal", uid("c1c1c1c1", 2))]


def stamp_of(day):
    return f"{day}T10:00:00.000Z"


def user_dto(user):
    return {k: user[k] for k in ("id", "name", "email", "profileImagePath", "avatarColor", "profileChangedAt")}


@router.reset
def fresh():
    STATE["albums_mode"] = "normal"
    STATE["user"] = dict(ME_USER, isAdmin=True)
    STATE["pin"] = PIN
    STATE["elevated"] = False


fresh()  # a request before the first `/__reset` must not find an empty STATE


# MARK: - Controls


@router.get("/control/albums")
def control_albums(req):
    mode = req.params.get("mode", "normal")
    STATE["albums_mode"] = mode if mode in ("normal", "error", "empty") else "normal"
    return Response({"albums_mode": STATE["albums_mode"]})


@router.get("/control/user")
def control_user(req):
    user = dict(STATE["user"], isAdmin=True)
    for param, key in (("id", "id"), ("email", "email"), ("name", "name")):
        if req.params.get(param):
            user[key] = req.params[param]
    STATE["user"] = user
    return Response({"user": user["id"], "email": user["email"]})


@router.get("/api/users/me")
def me(req):
    return Response(STATE["user"])


@router.post("/api/oauth/callback")
def sign_in(req):
    user = STATE["user"]
    return Response({**LOGIN, "userId": user["id"], "userEmail": user["email"],
                     "name": user["name"], "isAdmin": True})


# MARK: - Timeline


def _timeline_items(params):
    """The photos of the signed-in user (or of the partner) matching the filters."""
    user_id = params.get("userId")
    if user_id == PARTNER:
        return [entry(PARTNER_PHOTO)] if params.get("visibility", "timeline") == "timeline" else []
    if params.get("tagId"):
        return []
    trashed = params.get("isTrashed") == "true"
    visibility = params.get("visibility")
    favorite = params.get("isFavorite")
    items = []
    for item in LIBRARY:
        if item["trashed"] != trashed:
            continue
        if item["visibility"] == "locked" and (visibility != "locked" or not STATE["elevated"]):
            continue
        if visibility is not None and item["visibility"] != visibility:
            continue
        if favorite == "true" and not item["favorite"]:
            continue
        if favorite == "false" and item["favorite"]:
            continue
        items.append(item)
    return items


def _columnar(items, day, owner=ME):
    payload = bucket_payload([item["id"] for item in items], day=day)
    payload["ownerId"] = [owner] * len(items)
    payload["isFavorite"] = [item["favorite"] for item in items]
    payload["visibility"] = [item["visibility"] for item in items]
    payload["isTrashed"] = [item["trashed"] for item in items]
    return payload


@router.get("/api/timeline/buckets")
def buckets(req):
    axis = req.params.get("orderBy")
    if axis in AXES:
        day, ids = AXES[axis]
        return Response([{"timeBucket": day, "count": len(ids)}])
    if req.params.get("userId") == PARTNER:
        items = _timeline_items(req.params)
        return Response([{"timeBucket": PARTNER_DAY, "count": len(items)}] if items else [])
    items = _timeline_items(req.params)
    return Response([{"timeBucket": DAY, "count": len(items)}] if items else [])


@router.get("/api/timeline/bucket")
def bucket(req):
    month = req.params.get("timeBucket")
    if month in RECENT_DAYS:
        return Response(bucket_payload(RECENT_DAYS[month], day=month))
    items = _timeline_items(req.params)
    if req.params.get("userId") == PARTNER:
        return Response(_columnar(items, PARTNER_DAY, owner=PARTNER))
    return Response(_columnar(items, DAY))


# MARK: - Albums


def album_dto():
    owner = user_dto(STATE["user"])
    return {
        "id": ALBUM, "albumName": ALBUM_NAME, "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": None, "shared": False, "hasSharedLink": False,
        "assetCount": 1, "isActivityEnabled": True, "order": "desc",
        "ownerId": owner["id"], "owner": owner, "albumUsers": [],
    }


def _down(what):
    return Response({"error": "Internal Server Error", "message": f"stub: {what} is down"}, status=500)


@router.get("/api/albums")
def albums(req):
    mode = STATE["albums_mode"]
    if mode == "error":
        return _down("albums")
    return Response([] if mode == "empty" else [album_dto()])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if not req.rest or "/" in req.rest:
        return None
    if req.rest != ALBUM:
        return Response({"error": "not found", "path": req.path}, status=404)
    return Response(album_dto())


def _page(ids):
    items = [asset(pid) for pid in ids]
    return Response({"assets": {"count": len(items), "items": items,
                                "nextPage": None, "nextCursor": None}})


@router.post("/api/search/metadata")
def metadata(req):
    body = req.body or {}
    if body.get("albumIds"):
        return _page([ORDINARY[0]] if body["albumIds"][0] == ALBUM else [])
    if body.get("personIds"):
        return _page(PERSON_PHOTOS.get(body["personIds"][0], []))
    return _page([])


# MARK: - People


def person(pid, name):
    return {"id": pid, "name": name, "birthDate": None, "thumbnailPath": "", "isHidden": False,
            "color": "#4a5aef", "isFavorite": False, "updatedAt": "2026-09-01T10:00:00.000Z"}


PEOPLE = {ADA: person(ADA, "Ada"), ALAN: person(ALAN, "Alan")}


@router.get("/api/people")
def people(req):
    listed = list(PEOPLE.values())
    return Response({"people": listed, "hidden": 0, "total": len(listed), "hasNextPage": False})


@router.prefix("GET", "/api/people/")
def one_person(req):
    pid, _, tail = req.rest.partition("/")
    if pid not in PEOPLE:
        return None
    if tail == "statistics":
        return Response({"assets": len(PERSON_PHOTOS[pid])})
    if tail == "thumbnail":
        return Response(png(pid), ctype="image/png", headers={"Cache-Control": "no-store"})
    return None


# MARK: - Tags, stacks, duplicates


@router.get("/api/tags")
def tags(req):
    return Response([{"id": TAG, "name": "Voyages", "value": "Voyages", "color": None, "parentId": None,
                      "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z"}])


def stack_dto():
    return {"id": STACK, "primaryAssetId": STACK_PHOTOS[0], "assets": [asset(pid) for pid in STACK_PHOTOS]}


@router.get("/api/stacks")
def stacks(req):
    return Response([stack_dto()])


@router.prefix("GET", "/api/stacks/")
def one_stack(req):
    if req.rest != STACK:
        return Response({"error": "not found", "path": req.path}, status=404)
    return Response(stack_dto())


@router.get("/api/duplicates")
def duplicates(req):
    return Response([{"duplicateId": DUPLICATE, "assets": [asset(pid) for pid in DUPLICATE_PHOTOS],
                      "suggestedKeepAssetIds": [DUPLICATE_PHOTOS[0]]}])


# MARK: - Partners


def partner_dto():
    return {**user_dto({"id": PARTNER, "name": "Incoming Ivan", "email": "ivan@example.com",
                        "profileImagePath": "", "avatarColor": "primary",
                        "profileChangedAt": "2026-01-01T00:00:00.000Z"}), "inTimeline": False}


@router.get("/api/partners")
def partners(req):
    direction = req.params.get("direction")
    if direction == "shared-with":
        return Response([partner_dto()])
    return Response([])


@router.prefix("GET", "/api/assets/")
def partner_asset(req):
    """The partner's photo carries its real owner; everything else is the shell's."""
    if req.rest != PARTNER_PHOTO:
        return None
    return Response({**asset(PARTNER_PHOTO, PARTNER_DAY), "ownerId": PARTNER})


# MARK: - Folders


def folder_asset(aid, path, name, minute):
    dto = asset(aid)
    stamp = f"2025-04-01T10:{minute:02d}:00.000Z"
    dto.update({"originalPath": f"{path}/{name}", "originalFileName": name, "localDateTime": stamp,
                "createdAt": stamp, "fileCreatedAt": stamp, "fileModifiedAt": stamp, "updatedAt": stamp})
    dto["exifInfo"] = {**dto["exifInfo"], "dateTimeOriginal": stamp, "modifyDate": stamp}
    return dto


@router.get("/api/view/folder/unique-paths")
def unique_paths(req):
    return Response(list(FOLDERS))


@router.get("/api/view/folder")
def folder_assets(req):
    path = req.params.get("path", "")
    return Response([folder_asset(aid, path, name, minute) for aid, name, minute in FOLDERS.get(path, [])])


# MARK: - Places


@router.get("/api/search/cities")
def cities(req):
    out = []
    for n, (city, state, country, aid) in enumerate(CITIES):
        dto = asset(aid, day=f"2026-0{n + 1}-10")
        dto["exifInfo"] = {**dto["exifInfo"], "city": city, "state": state, "country": country}
        out.append(dto)
    return Response(out)


@router.post("/api/search/statistics")
def search_statistics(req):
    return Response({"total": 1})


# MARK: - The locked folder


def _bad_request(message):
    return Response({"message": message, "error": "Bad Request", "statusCode": 400}, status=400)


@router.get("/api/auth/status")
def auth_status(req):
    return Response({"expiresAt": None, "isElevated": STATE["elevated"], "password": True,
                     "pinCode": True, "pinExpiresAt": None})


@router.post("/api/auth/session/unlock")
def unlock(req):
    submitted = (req.body or {}).get("pinCode")
    req.note(submittedPIN=submitted)
    if submitted != STATE["pin"]:
        return _bad_request("Wrong PIN code")
    STATE["elevated"] = True
    return NO_CONTENT


@router.post("/api/auth/session/lock")
def lock(req):
    STATE["elevated"] = False
    return NO_CONTENT


if __name__ == "__main__":
    main(label="collections")
