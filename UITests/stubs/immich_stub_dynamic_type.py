"""Dynamic Type stub (L-13 / AC-26): every screen the scenario reads at the largest
text size carries a LONG label and a SHORT one, so "shown whole" can be measured as
"the long one is at least 1.8 times as tall as the short one".

    python3 UITests/stubs/immich_stub_dynamic_type.py 8421

    xcodebuild test -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \\
        -destination 'platform=iOS Simulator,name=iPhone 17' \\
        -only-testing:ImmichSwiftUIUITests/DynamicTypeUITests/<test>

Built on `immich_stub_base` (OAuth shell, request journal `/__requests`, asset
thumbnails). What it adds:

* `GET /api/server/config`: the SSO button text is a very long sentence.
* albums `dt-album-long` ("Summer holidays in the Gorges du Verdon with the whole
  family") and `dt-album-short` ("Paris"), cover on the first timeline photo;
  `GET /api/albums/{id}` answers the album, and any `POST /api/search/metadata`
  answers the six timeline photos (the album's photos, the person's photos, the
  favourites filter).
* partners: `shared-with` = `dt-partner-long` (in the timeline) and `dt-partner-short`;
  `shared-by` = the long one; no `direction` is a 400, like the real server.
  `GET /api/users` also offers `dt-user-long` and `dt-user-short` to invite.
* shared links `dt-link-long` and `dt-link-short`.
* people `dt-person-long` (42 characters) and `dt-person-short` ("Bo").
* memories `dt-memory-long` (a birthday: long name, long camera chip), `dt-memory-short`
  ("Bo", two photos) and `dt-memory-place` (on this day: long place chip, the shell's
  short "Stub Stub" camera chip).
* the timeline: six photos, #2 a favourite, #3 a video (0:01:05), #4 a Live Photo;
  `GET /api/assets/{id}` carries a long place, camera and lens.
* Search: one long place in `explore` and `cities`.

CONTROL
    GET /stub/dt-empty?on=1   `/api/albums` and `/api/shared-links` answer `[]`
    GET /stub/dt-empty?on=0   (or `/__reset`) the data comes back
"""
from immich_stub_base import (
    CONFIG, ME, ME_USER, STATE, Response, TIMELINE_ASSETS, asset, bucket_payload, main, png, router,
)

LONG_ALBUM = "dt-album-long"
SHORT_ALBUM = "dt-album-short"
LONG_ALBUM_NAME = "Summer holidays in the Gorges du Verdon with the whole family"
SHORT_ALBUM_NAME = "Paris"

LONG_PARTNER = "dt-partner-long"
SHORT_PARTNER = "dt-partner-short"
LONG_PARTNER_NAME = "Maximiliana Wilhelmina Konstantinopoulou-Featherstonehaugh"

LONG_USER = "dt-user-long"
SHORT_USER = "dt-user-short"

LONG_LINK = "dt-link-long"
SHORT_LINK = "dt-link-short"
LONG_LINK_DESCRIPTION = "Weekend photos for the grandparents and the cousins abroad"

LONG_PERSON = "dt-person-long"
SHORT_PERSON = "dt-person-short"
LONG_PERSON_NAME = "Wilhelmina Konstantinopoulou-Featherstone"  # 42 characters

LONG_MEMORY = "dt-memory-long"
SHORT_MEMORY = "dt-memory-short"
PLACE_MEMORY = "dt-memory-place"

LONG_PLACE = "Saint-Rémy-de-Provence-sur-la-Mer-Lointaine"  # 43 characters
LONG_MAKE = "Hasselblad Photographic Instruments"
LONG_MODEL = "X2D 100C Medium Format Edition"
LONG_LENS = "XCD 2,5/55V Ultra-Wide Long Name Edition"

LIVE_VIDEO = "aaaaaaaa-2222-4222-8222-000000000004"
STAMP = "2026-01-01T00:00:00.000Z"


# MARK: - State


@router.reset
def fresh():
    STATE["dt_empty"] = False


fresh()  # a request before the first `/__reset` must not find an empty STATE


@router.get("/stub/dt-empty")
def dt_empty(req):
    """`?on=1`: albums and shared links come back empty; `?on=0`: they come back."""
    STATE["dt_empty"] = req.params.get("on") == "1"
    return Response({"empty": STATE["dt_empty"]})


# MARK: - Config


@router.get("/api/auth/status")
def auth_status(req):
    """The locked folder has no PIN yet: its creation screen is the one measured."""
    return Response({
        "expiresAt": None, "isElevated": False, "password": True,
        "pinCode": False, "pinExpiresAt": None,
    })


@router.get("/api/server/config")
def server_config(req):
    return Response({
        **CONFIG,
        "oauthButtonText": "Continue with Example Corporation Single Sign-On Portal",
        "publicUsers": True,
    })


# MARK: - Albums


def album_dto(album_id, name):
    return {
        "id": album_id, "albumName": name, "description": "",
        "createdAt": STAMP, "updatedAt": STAMP,
        "albumThumbnailAssetId": TIMELINE_ASSETS[0], "shared": False, "hasSharedLink": False,
        "assetCount": len(TIMELINE_ASSETS), "isActivityEnabled": True, "order": "desc",
        "ownerId": ME, "albumUsers": [],
    }


ALBUMS = {
    LONG_ALBUM: LONG_ALBUM_NAME,
    SHORT_ALBUM: SHORT_ALBUM_NAME,
}


@router.get("/api/albums")
def albums(req):
    if STATE["dt_empty"]:
        return Response([])
    return Response([album_dto(album_id, name) for album_id, name in ALBUMS.items()])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if req.rest not in ALBUMS:
        return None
    return Response(album_dto(req.rest, ALBUMS[req.rest]))


# MARK: - Partners and users


def user(uid, name, email):
    return {
        "id": uid, "name": name, "email": email, "profileImagePath": "",
        "avatarColor": "primary", "profileChangedAt": STAMP,
    }


def partner(uid, name, email, in_timeline):
    return {**user(uid, name, email), "inTimeline": in_timeline}


LONG_PARTNER_ROW = partner(LONG_PARTNER, LONG_PARTNER_NAME, "maximiliana@example.org", True)
SHORT_PARTNER_ROW = partner(SHORT_PARTNER, "Bo", "bo@example.org", True)


@router.get("/api/partners")
def partners(req):
    direction = req.params.get("direction")
    req.note(direction=direction)
    if direction == "shared-with":
        return Response([LONG_PARTNER_ROW, SHORT_PARTNER_ROW])
    if direction == "shared-by":
        return Response([LONG_PARTNER_ROW])
    return Response(
        {"error": "Bad Request", "message": ["direction must be one of: shared-by, shared-with"]},
        status=400,
    )


@router.get("/api/users")
def users(req):
    return Response([
        ME_USER,
        user(LONG_USER, "Maximiliana Konstantinopoulou", "maximiliana.konstantinopoulou@long-domain-example.org"),
        user(SHORT_USER, "Bo", "bo@x.io"),
    ])


# MARK: - Shared links


def link_dto(link_id, description, album):
    return {
        "id": link_id, "description": description, "password": None,
        "userId": ME, "key": f"key-{link_id}", "type": "ALBUM",
        "createdAt": STAMP, "expiresAt": None,
        "assets": [], "album": album,
        "allowUpload": False, "allowDownload": True, "showMetadata": True,
        "slug": None,
    }


@router.get("/api/shared-links")
def shared_links(req):
    if STATE["dt_empty"]:
        return Response([])
    return Response([
        link_dto(LONG_LINK, LONG_LINK_DESCRIPTION, album_dto(LONG_ALBUM, LONG_ALBUM_NAME)),
        link_dto(SHORT_LINK, "Bo", None),
    ])


# MARK: - People


def person(pid, name):
    """One `PersonResponseDto` — every non-optional field the app decodes."""
    return {
        "id": pid, "name": name, "birthDate": None, "thumbnailPath": "",
        "isHidden": False, "color": "#4a5aef", "isFavorite": False,
        "updatedAt": "2026-09-01T10:00:00.000Z",
    }


PEOPLE = {LONG_PERSON: LONG_PERSON_NAME, SHORT_PERSON: "Bo"}


@router.get("/api/people")
def people(req):
    listed = [person(pid, name) for pid, name in PEOPLE.items()]
    return Response({"people": listed, "hidden": 0, "total": len(listed), "hasNextPage": False})


@router.prefix("GET", "/api/people/")
def one_person(req):
    pid, _, tail = req.rest.partition("/")
    if pid not in PEOPLE:
        return None
    if tail == "":
        return Response(person(pid, PEOPLE[pid]))
    if tail == "statistics":
        return Response({"assets": len(TIMELINE_ASSETS)})
    if tail == "thumbnail":
        return Response(png(pid), ctype="image/png", headers={"Cache-Control": "no-store"})
    return None


# MARK: - Memories


def memory_asset(aid, city=None, country=None, make="Stub", model="Stub"):
    dto = asset(aid)
    dto["exifInfo"] = {**dto["exifInfo"], "make": make, "model": model, "city": city, "country": country}
    return dto


def memory_dto(memory_id, mtype, data, assets, memory_at):
    return {
        "id": memory_id, "createdAt": memory_at, "updatedAt": memory_at,
        "memoryAt": memory_at, "ownerId": ME, "type": mtype, "data": data,
        "assets": assets, "isSaved": False,
        "showAt": None, "hideAt": None, "seenAt": None, "deletedAt": None,
    }


@router.get("/api/memories")
def memories(req):
    return Response([
        memory_dto(
            LONG_MEMORY, "birthday",
            {"year": 1996, "personId": LONG_PERSON, "personName": LONG_PARTNER_NAME},
            [memory_asset(aid, make=LONG_MAKE, model=LONG_MODEL) for aid in TIMELINE_ASSETS],
            "2026-09-01T00:00:00.000Z",
        ),
        memory_dto(
            SHORT_MEMORY, "birthday",
            {"year": 1996, "personId": SHORT_PERSON, "personName": "Bo"},
            [memory_asset(aid) for aid in TIMELINE_ASSETS[:2]],
            "2026-09-01T00:00:00.000Z",
        ),
        memory_dto(
            PLACE_MEMORY, "on_this_day", {"year": 2022},
            [memory_asset(aid, city=LONG_PLACE, country="France") for aid in TIMELINE_ASSETS[:3]],
            "2026-09-01T00:00:00.000Z",
        ),
    ])


# MARK: - Timeline and photos


@router.get("/api/timeline/bucket")
def timeline_bucket(req):
    """The shell's day: #2 favourite, #3 video of 0:01:05, #4 Live Photo."""
    payload = bucket_payload(TIMELINE_ASSETS)
    payload["isFavorite"][1] = True
    payload["isImage"][2] = False
    payload["duration"][2] = "0:01:05.000"
    payload["livePhotoVideoId"][3] = LIVE_VIDEO
    return Response(payload)


def detailed_asset(aid):
    """`asset(aid)` with a long place, camera and lens (the info panel's grid)."""
    dto = asset(aid)
    dto["exifInfo"] = {
        **dto["exifInfo"], "city": LONG_PLACE, "country": "France",
        "make": LONG_MAKE, "model": LONG_MODEL, "lensModel": LONG_LENS,
    }
    if aid == TIMELINE_ASSETS[1]:
        dto["isFavorite"] = True
    if aid == TIMELINE_ASSETS[2]:
        dto["type"] = "VIDEO"
        dto["duration"] = "0:01:05.000"
    if aid == TIMELINE_ASSETS[3]:
        dto["livePhotoVideoId"] = LIVE_VIDEO
    return dto


@router.prefix("GET", "/api/assets/")
def asset_detail(req):
    if not req.rest or "/" in req.rest:
        return None  # thumbnails and originals are the shell's
    return Response(detailed_asset(req.rest))


# MARK: - Search


@router.get("/api/search/explore")
def explore(req):
    place = detailed_asset(TIMELINE_ASSETS[0])
    return Response([{"fieldName": "exifInfo.city", "items": [{"value": LONG_PLACE, "data": place}]}])


@router.get("/api/search/cities")
def cities(req):
    return Response([detailed_asset(TIMELINE_ASSETS[0])])


@router.post("/api/search/metadata")
def metadata_search(req):
    """The six photos (album, person, favourites filter): `assets.items`, one page."""
    items = [detailed_asset(aid) for aid in TIMELINE_ASSETS]
    return Response({"assets": {"count": len(items), "items": items,
                                "nextPage": None, "nextCursor": None}})


if __name__ == "__main__":
    main(label="dynamic-type")
