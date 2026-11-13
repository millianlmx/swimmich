"""Immich API stub for the "photo details" scenarios (`PhotoDetailsUITests`, lot L-24).

The info panel of a photo shows, under each recognised person's name, their age
on the photo's day, and for a photo of another account a "Shared by <name>" row
with that account's avatar. Booting, signing in, thumbnails and `/api/users/me`
come from `immich_stub_base`; this file adds the people, the owners and the
album that feature needs.

Accounts: ME (the signed-in user); `P1` "Alice Partner" (a profile photo is
published); `P2` "Bob Partner" (no profile photo: initials); `M1` "Carla Member"
(a member of the shared album, not a partner).

The main timeline (one bucket, 2020-06) holds seven photos, every one with a real
`GET /api/assets/{id}` detail:

  MINE          ME, taken 2020-06-14T10:00Z, face of Nina (born 2000-06-15)
  MINE_NOBIRTH  ME, same day, face of Omar (no birthday)
  TOKYO         ME, taken 2020-06-14T22:00Z (2020-06-15 07:00 in Tokyo), face of Nina
  P1_PHOTO      P1, detail with a complete `owner`
  P2_PHOTO      P2, detail with a complete `owner` (no profile photo)
  P_NO_OWNER    P1, detail WITHOUT the `owner` key
  P_FAIL        P1, detail answers 500
  NO_EXIF       ME, file date 2020-06-14T22:00Z, NO EXIF capture date, face of Nina

The shared album "Shared Trip" holds one photo of M1 (`ALB_M1`) and one of ME
(`ALB_ME`); its photos come from `POST /api/search/metadata` with `albumIds`.

Routes beyond the shell:

  GET /api/server/version        3.4.0
  GET /api/assets/{id}           the detail of a photo above (anything else: the shell)
  GET /api/faces?id=             the faces of one photo, with the person and `birthDate`
  PUT /api/faces/{personId}      body `{"id": <faceId>}`: attaches the face to that person
                                 (a later `GET /api/faces` returns it); journaled `faceId`, `personId`
  GET /api/people                Nina and Omar, for the re-assignment picker
  GET /api/users/{id}/profile-image   a real PNG for P1; the journal entry carries
                                 `bearer` (the `Authorization` header starts with "Bearer ")
  GET /api/albums, /api/albums/{id}   the shared album (server v3 shape)
  POST /api/search/metadata      `albumIds = [<id>]` -> the album's photos

`/__reset` restores the faces. Assert on the wire through `/__requests`.
"""
from immich_stub_base import ME, ME_USER, Response, asset, bucket_payload, main, png, router

P1 = "22222222-2222-4222-8222-000000000001"
P2 = "22222222-2222-4222-8222-000000000002"
M1 = "22222222-2222-4222-8222-0000000000a1"

NINA = "33333333-3333-4333-8333-00000000a001"
OMAR = "33333333-3333-4333-8333-00000000a002"

MINE = "24000000-0000-4000-8000-000000000001"
MINE_NOBIRTH = "24000000-0000-4000-8000-000000000002"
TOKYO = "24000000-0000-4000-8000-000000000003"
P1_PHOTO = "24000000-0000-4000-8000-000000000004"
P2_PHOTO = "24000000-0000-4000-8000-000000000005"
P_NO_OWNER = "24000000-0000-4000-8000-000000000006"
P_FAIL = "24000000-0000-4000-8000-000000000007"
NO_EXIF = "24000000-0000-4000-8000-000000000008"
ALB_M1 = "24000000-0000-4000-8000-0000000000a1"
ALB_ME = "24000000-0000-4000-8000-0000000000a2"

ALBUM = "55555555-5555-4555-8555-0000000000a1"

AT_TEN = "2020-06-14T10:00:00.000Z"
AT_TEN_PM = "2020-06-14T22:00:00.000Z"

USERS = {
    ME: ME_USER,
    P1: {"id": P1, "name": "Alice Partner", "email": "alice@example.com",
         "profileImagePath": "/upload/profile/p1.png", "avatarColor": "blue",
         "profileChangedAt": "2026-01-01T00:00:00.000Z"},
    P2: {"id": P2, "name": "Bob Partner", "email": "bob@example.com",
         "profileImagePath": "", "avatarColor": "red",
         "profileChangedAt": "2026-01-01T00:00:00.000Z"},
    M1: {"id": M1, "name": "Carla Member", "email": "carla@example.com",
         "profileImagePath": "", "avatarColor": "green",
         "profileChangedAt": "2026-01-01T00:00:00.000Z"},
}

PEOPLE = {
    NINA: {"id": NINA, "name": "Nina", "birthDate": "2000-06-15", "isHidden": False},
    OMAR: {"id": OMAR, "name": "Omar", "birthDate": None, "isHidden": False},
}

# id -> (owner, stamp, dateTimeOriginal, [(face id, person id)])
PHOTOS = {
    MINE: (ME, AT_TEN, AT_TEN, [("f0000000-0000-4000-8000-000000000001", NINA)]),
    MINE_NOBIRTH: (ME, AT_TEN, AT_TEN, [("f0000000-0000-4000-8000-000000000002", OMAR)]),
    TOKYO: (ME, AT_TEN_PM, AT_TEN_PM, [("f0000000-0000-4000-8000-000000000003", NINA)]),
    P1_PHOTO: (P1, AT_TEN, AT_TEN, []),
    P2_PHOTO: (P2, AT_TEN, AT_TEN, []),
    P_NO_OWNER: (P1, AT_TEN, AT_TEN, []),
    P_FAIL: (P1, AT_TEN, AT_TEN, []),
    NO_EXIF: (ME, AT_TEN_PM, None, [("f0000000-0000-4000-8000-000000000004", NINA)]),
    ALB_M1: (M1, AT_TEN, AT_TEN, []),
    ALB_ME: (ME, AT_TEN, AT_TEN, []),
}
TIMELINE = [MINE, MINE_NOBIRTH, TOKYO, NO_EXIF, P1_PHOTO, P2_PHOTO, P_NO_OWNER, P_FAIL]
ALBUM_PHOTOS = [ALB_M1, ALB_ME]

S = {}


def _restore():
    S["faces"] = {pid: list(spec[3]) for pid, spec in PHOTOS.items()}


_restore()
router.reset(_restore)


# MARK: - Version


@router.get("/api/server/version")
def reported_version(req):
    return Response({"major": 3, "minor": 4, "patch": 0, "prerelease": None})


# MARK: - Timeline


@router.get("/api/timeline/buckets")
def timeline_buckets(req):
    return Response([{"timeBucket": "2020-06-01", "count": len(TIMELINE)}])


def _columns(ids):
    payload = bucket_payload(ids)
    payload["ownerId"] = [PHOTOS[pid][0] for pid in ids]
    payload["createdAt"] = [PHOTOS[pid][1] for pid in ids]
    payload["fileCreatedAt"] = [PHOTOS[pid][1] for pid in ids]
    return payload


@router.get("/api/timeline/bucket")
def timeline_bucket(req):
    return Response(_columns(TIMELINE))


# MARK: - Asset detail


@router.prefix("GET", "/api/assets/")
def photo_detail(req):
    pid = req.rest
    if pid not in PHOTOS:
        return None  # `/thumbnail`, `/original`, anything else: the shell
    if pid == P_FAIL:
        return Response({"message": "stub failure", "statusCode": 500}, status=500)
    owner, stamp, taken, _ = PHOTOS[pid]
    detail = asset(pid)
    detail.update({"ownerId": owner, "localDateTime": stamp, "createdAt": stamp, "fileCreatedAt": stamp})
    detail["exifInfo"] = {**detail["exifInfo"], "dateTimeOriginal": taken}
    if pid != P_NO_OWNER:
        detail["owner"] = USERS[owner]
    return Response(detail)


# MARK: - Faces and people


def _face(face_id, person_id):
    return {"id": face_id, "person": PEOPLE[person_id],
            "boundingBoxX1": 100, "boundingBoxY1": 100, "boundingBoxX2": 600, "boundingBoxY2": 600,
            "imageWidth": 4000, "imageHeight": 3000, "sourceType": "machine-learning"}


@router.get("/api/faces")
def faces(req):
    pid = req.params.get("id")
    return Response([_face(face_id, person_id) for face_id, person_id in S["faces"].get(pid, [])])


@router.prefix("PUT", "/api/faces/")
def reassign_face(req):
    person_id = req.rest
    face_id = (req.body or {}).get("id")
    req.note(faceId=face_id, personId=person_id)
    if person_id not in PEOPLE:
        return Response({"message": "unknown person", "statusCode": 400}, status=400)
    for rows in S["faces"].values():
        for index, (fid, _) in enumerate(rows):
            if fid == face_id:
                rows[index] = (fid, person_id)
                return Response(PEOPLE[person_id])
    return Response({"message": "unknown face", "statusCode": 400}, status=400)


@router.get("/api/people")
def people(req):
    rows = list(PEOPLE.values())
    return Response({"people": rows, "hidden": 0, "total": len(rows), "hasNextPage": False})


# MARK: - Avatars


@router.prefix("GET", "/api/users/")
def profile_image(req):
    if not req.rest.endswith("/profile-image"):
        return None
    uid = req.rest[: -len("/profile-image")]
    user = USERS.get(uid)
    if user is None or not user["profileImagePath"]:
        return Response({"message": "no profile image", "statusCode": 404}, status=404)
    req.note(bearer=(req.headers.get("Authorization") or "").startswith("Bearer "))
    return Response(png(uid, size=32), ctype="image/png", headers={"Cache-Control": "no-store"})


# MARK: - The shared album


def album_dto():
    return {
        "id": ALBUM, "albumName": "Shared Trip", "description": "", "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z", "albumThumbnailAssetId": ALB_M1, "shared": True,
        "hasSharedLink": False, "assetCount": len(ALBUM_PHOTOS), "isActivityEnabled": True, "order": "desc",
        "albumUsers": [{"user": USERS[M1], "role": "owner"}, {"user": ME_USER, "role": "editor"}],
    }


@router.get("/api/albums")
def albums(req):
    return Response([album_dto()])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if req.rest != ALBUM:
        return None
    return Response(album_dto())


@router.post("/api/search/metadata")
def metadata_search(req):
    ids = (req.body or {}).get("albumIds")
    if not ids or ids[0] != ALBUM:
        return Response({"assets": {"count": 0, "items": [], "nextPage": None, "nextCursor": None}})
    items = []
    for pid in ALBUM_PHOTOS:
        owner, stamp, taken, _ = PHOTOS[pid]
        item = asset(pid)
        item.update({"ownerId": owner, "localDateTime": stamp, "createdAt": stamp, "fileCreatedAt": stamp})
        items.append(item)
    return Response({"assets": {"count": len(items), "items": items, "nextPage": None, "nextCursor": None}})


if __name__ == "__main__":
    main(label="photo_details")
