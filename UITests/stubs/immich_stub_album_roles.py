"""Immich API stub for the "album roles and order" scenarios (`AlbumRolesUITests`, lot L-02).

Three albums with distinct names (names are data, never matched as UI text by id):

  * "Our Trip"        owner ME, editor "Alice Editor", viewer "Bob Viewer"; three photos
                      dated 2020-03-01, 2022-03-01 and 2024-03-01.
  * "Carol Editable"  owner "Carol", ME is an editor; one photo.
  * "Carol Read Only" owner "Carol", ME is a viewer; one photo.

The album JSON follows the announced server version, like `album.dto.ts`:

  * major < 3  : `ownerId` + `owner`; `albumUsers` EXCLUDES the owner and is
                 sorted editors first, then viewers.
  * major >= 3 : neither `ownerId` nor `owner`; `albumUsers` = the owner
                 (`role: owner`) first, then ME when ME is not the owner, then the others.

Routes (the shell answers everything else):

  GET   /stub/version?v=X.Y.Z   control route (journaled): the announced version (default 3.4.0)
  GET   /api/server/version     the announced version
  GET   /api/albums             major < 3: no `shared` -> albums ME owns; `shared=true` -> albums
                                with at least one member where ME is owner or member;
                                `shared=false` -> owned albums without member. major >= 3: all three.
  GET   /api/albums/<id>        one album (404 otherwise)
  PATCH /api/albums/<id>        applies `albumName`, `description`, `order`; 400 when the caller
                                (ME) is neither owner nor an editor on a server >= 2.6.2,
                                like `access.ts` (`AlbumUpdate`)
  POST  /api/search/metadata    `albumIds = [<id>]` -> the album's photos sorted by date
                                according to the body's `order` (`asc` | `desc`, default `desc`)

`/__reset` restores version 3.4.0, the original names and descriptions and `order = desc`.
Assert on the wire through `/__requests` (path, params and body of every request).
"""
from immich_stub_base import ME, ME_USER, Response, asset, main, router

CAROL = "44444444-4444-4444-8444-000000ca401"
ALICE = "44444444-4444-4444-8444-0000000a11ce"
BOB = "44444444-4444-4444-8444-000000000b0b"

OUR_TRIP = "55555555-5555-4555-8555-000000000001"
CAROL_EDITABLE = "55555555-5555-4555-8555-000000000002"
CAROL_READ_ONLY = "55555555-5555-4555-8555-000000000003"

PHOTO_2020 = "bbbbbbbb-3333-4333-8333-000000002020"
PHOTO_2022 = "bbbbbbbb-3333-4333-8333-000000002022"
PHOTO_2024 = "bbbbbbbb-3333-4333-8333-000000002024"
PHOTO_CAROL_EDITABLE = "bbbbbbbb-3333-4333-8333-00000000ca01"
PHOTO_CAROL_READ_ONLY = "bbbbbbbb-3333-4333-8333-00000000ca02"

USERS = {
    ME: ME_USER,
    CAROL: {"id": CAROL, "name": "Carol", "email": "carol@example.com",
            "profileImagePath": "", "avatarColor": "blue",
            "profileChangedAt": "2026-01-01T00:00:00.000Z"},
    ALICE: {"id": ALICE, "name": "Alice Editor", "email": "alice@example.com",
            "profileImagePath": "", "avatarColor": "green",
            "profileChangedAt": "2026-01-01T00:00:00.000Z"},
    BOB: {"id": BOB, "name": "Bob Viewer", "email": "bob@example.com",
          "profileImagePath": "", "avatarColor": "red",
          "profileChangedAt": "2026-01-01T00:00:00.000Z"},
}

# (id, original name, original description, owner, [(member, role)], [(photo, day)])
CATALOG = {
    OUR_TRIP: ("Our Trip", "Three summers", ME,
               [(ALICE, "editor"), (BOB, "viewer")],
               [(PHOTO_2020, "2020-03-01"), (PHOTO_2022, "2022-03-01"), (PHOTO_2024, "2024-03-01")]),
    CAROL_EDITABLE: ("Carol Editable", "Carol's album", CAROL,
                     [(ME, "editor")], [(PHOTO_CAROL_EDITABLE, "2024-05-01")]),
    CAROL_READ_ONLY: ("Carol Read Only", "Read only", CAROL,
                      [(ME, "viewer")], [(PHOTO_CAROL_READ_ONLY, "2024-06-01")]),
}

S = {}


def _restore():
    S["version"] = (3, 4, 0)
    S["names"] = {aid: spec[0] for aid, spec in CATALOG.items()}
    S["descriptions"] = {aid: spec[1] for aid, spec in CATALOG.items()}
    S["orders"] = {aid: "desc" for aid in CATALOG}


_restore()
router.reset(lambda: _restore())


def _version_dto():
    major, minor, patch = S["version"]
    return {"major": major, "minor": minor, "patch": patch, "prerelease": None}


def _members(aid):
    return CATALOG[aid][3]


def _owner(aid):
    return CATALOG[aid][2]


def _role_of_me(aid):
    if _owner(aid) == ME:
        return "owner"
    return next((role for uid, role in _members(aid) if uid == ME), "viewer")


def album_dto(aid):
    """A fresh dict per call, in the shape of the announced server version."""
    owner = _owner(aid)
    members = sorted(_members(aid), key=lambda m: (m[1] != "editor", USERS[m[0]]["name"]))
    dto = {
        "id": aid,
        "albumName": S["names"][aid],
        "description": S["descriptions"][aid],
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": None,
        "shared": True,
        "hasSharedLink": False,
        "assetCount": len(CATALOG[aid][4]),
        "isActivityEnabled": True,
        "order": S["orders"][aid],
    }
    if S["version"][0] < 3:
        dto["ownerId"] = owner
        dto["owner"] = USERS[owner]
        dto["albumUsers"] = [{"user": USERS[uid], "role": role} for uid, role in members]
    else:
        entries = [{"user": USERS[owner], "role": "owner"}]
        me_entry = [(uid, role) for uid, role in members if uid == ME]
        others = [(uid, role) for uid, role in members if uid != ME]
        entries += [{"user": USERS[uid], "role": role} for uid, role in me_entry + others]
        dto["albumUsers"] = entries
    return dto


def _is_listed(aid, shared):
    """`GET /api/albums` on a server < 3, per `album.service.ts` (v2.6.2)."""
    owned = _owner(aid) == ME
    has_members = bool(_members(aid))
    if shared is True:
        return has_members and (owned or any(uid == ME for uid, _ in _members(aid)))
    if shared is False:
        return owned and not has_members
    return owned


# MARK: - The announced version


@router.get("/api/server/version")
def reported_version(req):
    return Response(_version_dto())


@router.get("/stub/version")
def set_version(req):
    raw = req.params.get("v", "3.4.0")
    major, minor, patch = (int(part) for part in raw.split("."))
    S["version"] = (major, minor, patch)
    return Response(_version_dto())


# MARK: - Albums


@router.get("/api/albums")
def albums(req):
    if S["version"][0] >= 3:
        return Response([album_dto(aid) for aid in CATALOG])
    raw = req.params.get("shared")
    shared = None if raw is None else raw == "true"
    return Response([album_dto(aid) for aid in CATALOG if _is_listed(aid, shared)])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if not req.rest or "/" in req.rest:
        return None  # a sub-resource: the shell's own answer
    if req.rest in CATALOG:
        return Response(album_dto(req.rest))
    return Response({"error": "not found", "path": req.path}, status=404)


@router.prefix("PATCH", "/api/albums/")
def album_update(req):
    if not req.rest or "/" in req.rest:
        return None
    aid = req.rest
    if aid not in CATALOG:
        return Response({"error": "not found", "path": req.path}, status=404)
    role = _role_of_me(aid)
    editor_ok = role == "editor" and S["version"] >= (2, 6, 2)
    if role != "owner" and not editor_ok:
        return Response({"message": "Not found or no album.update access",
                         "error": "Bad Request", "statusCode": 400}, status=400)
    body = req.body
    if "albumName" in body:
        S["names"][aid] = body["albumName"]
    if "description" in body:
        S["descriptions"][aid] = body["description"]
    if "order" in body:
        S["orders"][aid] = body["order"]
    return Response(album_dto(aid))


# MARK: - POST /api/search/metadata


def _page(aid, order):
    photos = sorted(CATALOG[aid][4], key=lambda p: p[1], reverse=(order != "asc"))
    items = [asset(pid, day=day) for pid, day in photos]
    return Response({"assets": {"count": len(items), "items": items,
                                "nextPage": None, "nextCursor": None}})


@router.post("/api/search/metadata")
def metadata_search(req):
    body = req.body
    ids = body.get("albumIds")
    if not ids or ids[0] not in CATALOG:
        # Without `albumIds` a real server answers the whole library; this stub has none to show.
        return Response({"assets": {"count": 0, "items": [], "nextPage": None, "nextCursor": None}})
    return _page(ids[0], body.get("order", "desc"))


if __name__ == "__main__":
    main(label="album-roles")
