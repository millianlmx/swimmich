"""Masked-metadata shared-link stub (UITests): links whose server hides the photos'
metadata, in the reduced forms every server version really sends.

    python3 UITests/stubs/immich_stub_shared_link_masked.py 8421

A link that hides metadata (`showMetadata: false`) hands the visitor photos
without `ownerId`, `createdAt`, `isFavorite`, `exifInfo`, …: the app must still
open it. The links below are addressed by slug (or by key, which is the slug here);
paste `http://127.0.0.1:8421/s/<slug>` in the Shared tab's link viewer.

    slug             type        shows  photos (grid order)
    masked-v3        INDIVIDUAL  no     p1 IMAGE 8000x6000, p2 IMAGE 4000x3000 (reduced v3.4.0)
    masked-badges    INDIVIDUAL  no     v1 VIDEO 65250 ms ("1:05"), l1 IMAGE live photo
    masked-locked    INDIVIDUAL  no     2 reduced v3 photos behind the password `hunter2`
                                        (cookie `immich_shared_link_token=stub-masked-token`)
    masked-album     ALBUM       no     6 reduced v3 photos over 2 search pages of 3
    masked-v2        INDIVIDUAL  no     v1 VIDEO "00:01:05.250", p1 IMAGE "0:00:00.00000"
                                        (reduced v2.0.0: string durations, no width/height)
    masked-v2-album  ALBUM       no     2 FULL v2.x records leaking SECRET-<n>.jpg, owner-secret,
                                        Lisbon, Portugal, 2019 dates, a favourite, a 360° projection
                                        (a v2.x search ignores the masking)
    exposed-hd       INDIVIDUAL  yes    1 full v3 record, EXIF 8000x6000, orientation "1", not edited

Any other slug answers 401 `Invalid share slug`.

Asset ids carry a nonce regenerated on every `/__reset` (the app caches thumbnails
on disk by URL); `GET /stub/masked-links` answers `{slug: [ids in grid order]}` so a
scenario can find the cells. The search records the requested `page` in `/__requests`
(`req.note(page=…)`). Thumbnails and previews are the shell's.
"""
import time

from immich_stub_base import Response, STATE, router, main, ME

PASSWORD = "hunter2"
TOKEN = "stub-masked-token"
ALBUM = "33333333-3333-4333-8333-000000000003"
PAGE_SIZE = 3
STAMP = "2024-07-01T10:00:00.000Z"
LEAK_STAMP = "2019-03-14T09:00:00.000Z"
DURATION_UNKNOWN_V2 = "0:00:00.00000"


# MARK: - Photo records, one function per form a server sends


def reduced_v3(aid, kind="IMAGE", duration=None, live=None, width=4000, height=3000):
    """Server v3.4.0 `mapAsset` under `isMetadataHidden`: exactly these ten keys."""
    return {
        "id": aid, "type": kind,
        "originalMimeType": "video/mp4" if kind == "VIDEO" else "image/jpeg",
        "thumbhash": STATE["thumbhash"], "localDateTime": STAMP,
        "duration": duration, "livePhotoVideoId": live, "hasMetadata": False,
        "width": width, "height": height,
    }


def reduced_v2(aid, kind="IMAGE", duration=DURATION_UNKNOWN_V2):
    """Server v2.0.0 `SanitizedAssetResponseDto`: a string duration, no width/height."""
    return {
        "id": aid, "type": kind, "thumbhash": STATE["thumbhash"],
        "originalMimeType": "video/mp4" if kind == "VIDEO" else "image/jpeg",
        "localDateTime": STAMP, "duration": duration,
        "livePhotoVideoId": None, "hasMetadata": False,
    }


def full_record(aid, stamp, name, owner, favorite, duration, exif):
    """Every required key of `AssetResponseDto`, plus the optional ones the stub fills."""
    return {
        "id": aid, "type": "IMAGE", "thumbhash": STATE["thumbhash"],
        "localDateTime": stamp, "duration": duration, "hasMetadata": True,
        "width": 8000, "height": 6000, "createdAt": stamp,
        "ownerId": owner, "originalPath": f"/x/{name}",
        "originalFileName": name,
        "fileCreatedAt": stamp, "fileModifiedAt": stamp,
        "updatedAt": stamp, "isFavorite": favorite, "isArchived": False,
        "isTrashed": False, "isOffline": False, "visibility": "timeline", "checksum": "abc",
        "isEdited": False, "originalMimeType": "image/jpeg", "livePhotoVideoId": None,
        "exifInfo": exif,
    }


def full_v2(aid, n):
    """What a v2.x search hands out for a link that hides metadata: the FULL record,
    every value of it a leak the app must not show."""
    return full_record(
        aid, LEAK_STAMP, f"SECRET-{n}.jpg", "owner-secret", True, DURATION_UNKNOWN_V2,
        {
            "make": "Secret", "model": "Secret", "exifImageWidth": 8000, "exifImageHeight": 6000,
            "fileSizeInByte": 2048, "orientation": "1", "dateTimeOriginal": LEAK_STAMP,
            "modifyDate": LEAK_STAMP, "timeZone": "UTC", "lensModel": None,
            "latitude": 38.7223, "longitude": -9.1393, "city": "Lisbon",
            "country": "Portugal", "projectionType": "equirectangular",
        },
    )


def full_v3(aid):
    """A full v3 record of a link that exposes its metadata: 8000x6000, not edited."""
    return full_record(
        aid, STAMP, f"{aid[-8:]}.jpg", ME, False, None,
        {
            "make": "Stub", "model": "Stub", "exifImageWidth": 8000, "exifImageHeight": 6000,
            "fileSizeInByte": 2048, "orientation": "1", "dateTimeOriginal": STAMP,
            "modifyDate": STAMP, "timeZone": "UTC", "lensModel": None,
        },
    )


# MARK: - The links


def make_link(number, slug, kind, shows, assets, password=None, upload=False):
    return {
        "id": f"44444444-4444-4444-8444-{number:012d}", "slug": slug, "type": kind,
        "showMetadata": shows, "password": password, "allowUpload": upload,
        "assets": assets,
    }


def build_links():
    """Every link, with asset ids carrying a nonce that changes on every `/__reset`.

    `AuthenticatedAsyncImage` caches thumbnails on disk by URL, so a fixed id
    would be served from that cache on a second run and the image request — the
    only place a link's credential appears in a URL — would never reach the stub."""
    run = "%08d" % (int(time.time() * 1000) % 10**8)

    def ids(prefix, count):
        return [f"{prefix}-{run}{i:04d}" for i in range(1, count + 1)]

    v3 = ids("mv3", 2)
    badges = ids("mbd", 3)
    locked = ids("mlk", 2)
    album = ids("mal", 6)
    v2 = ids("mv2", 2)
    v2_album = ids("mva", 2)
    hd = ids("mhd", 1)
    links = [
        make_link(1, "masked-v3", "INDIVIDUAL", False,
                  [reduced_v3(v3[0], width=8000, height=6000), reduced_v3(v3[1])]),
        make_link(2, "masked-badges", "INDIVIDUAL", False,
                  [reduced_v3(badges[0], kind="VIDEO", duration=65250),
                   reduced_v3(badges[1], live=badges[2])]),
        make_link(3, "masked-locked", "INDIVIDUAL", False,
                  [reduced_v3(a) for a in locked], password=PASSWORD),
        make_link(4, "masked-album", "ALBUM", False,
                  [reduced_v3(a) for a in album], upload=True),
        make_link(5, "masked-v2", "INDIVIDUAL", False,
                  [reduced_v2(v2[0], kind="VIDEO", duration="00:01:05.250"), reduced_v2(v2[1])]),
        make_link(6, "masked-v2-album", "ALBUM", False,
                  [full_v2(a, n) for n, a in enumerate(v2_album, start=1)]),
        make_link(7, "exposed-hd", "INDIVIDUAL", True, [full_v3(hd[0])]),
    ]
    return {link["slug"]: link for link in links}


@router.reset
def fresh():
    STATE["masked_links"] = build_links()


fresh()


@router.get("/stub/masked-links")
def masked_links(req):
    """`{slug: [asset ids in grid order]}` — the ids are per run."""
    return Response({slug: [a["id"] for a in link["assets"]]
                     for slug, link in STATE["masked_links"].items()})


# MARK: - The server's answers


def unauthorized(message):
    return Response({"message": message, "error": "Unauthorized", "statusCode": 401}, status=401)


def credential(req):
    """`(kind, value)` — `key` wins over `slug`, like the server's own validation."""
    if req.params.get("key"):
        return "key", req.params["key"]
    if req.params.get("slug"):
        return "slug", req.params["slug"]
    return None, None


def addressed(req):
    """The link a request addresses (a link's key is its slug), or the 401 to answer."""
    kind, value = credential(req)
    link = STATE["masked_links"].get(value) if kind else None
    if link is None:
        return None, unauthorized("Invalid share slug" if kind == "slug" else "Invalid share key")
    return link, None


def has_session_cookie(req):
    return f"immich_shared_link_token={TOKEN}" in (req.headers.get("Cookie") or "")


def album_dto(link):
    """`AlbumResponseDto` of an album link (no `assets` field, like the real one)."""
    count = len(link["assets"])
    return {
        "id": ALBUM, "albumName": "Masked Album", "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": link["assets"][0]["id"] if count else None,
        "shared": True, "hasSharedLink": True, "assetCount": count,
        "isActivityEnabled": False, "order": "desc", "albumUsers": [],
    }


def shared_link_dto(link):
    """`SharedLinkResponseDto`: `assets` inline for an individual link, empty for an
    album link (its photos come from the search); `album` only for an album link."""
    individual = link["type"] == "INDIVIDUAL"
    return {
        "id": link["id"], "description": None, "password": link["password"],
        "userId": ME, "key": link["slug"], "type": link["type"],
        "createdAt": "2026-01-01T00:00:00.000Z", "expiresAt": None,
        "assets": link["assets"] if individual else [],
        "album": None if individual else album_dto(link),
        "allowUpload": link["allowUpload"], "allowDownload": True,
        "showMetadata": link["showMetadata"], "slug": link["slug"],
    }


@router.get("/api/shared-links/me")
def me(req):
    link, refusal = addressed(req)
    if link is None:
        return refusal
    # The password is checked on the COOKIE: the key alone opens nothing.
    if link["password"] and not has_session_cookie(req):
        return unauthorized("Password required")
    return Response(shared_link_dto(link))


@router.post("/api/shared-links/login")
def login(req):
    link, refusal = addressed(req)
    if link is None:
        return refusal
    if not link["password"]:
        return Response({"message": "Shared link is not password protected",
                         "error": "Bad Request", "statusCode": 400}, status=400)
    if req.body.get("password") != link["password"]:
        return unauthorized("Invalid password")
    return Response(shared_link_dto(link), status=201, headers={
        "Set-Cookie": f"immich_shared_link_token={TOKEN}; Path=/; HttpOnly",
    })


@router.post("/api/search/metadata")
def search(req):
    """The album link's photos: only with an `albumIds` filter, `PAGE_SIZE` a page
    (`size` is ignored), `nextPage` the number of the next page or null."""
    req.note(page=req.body.get("page"))
    if not req.body.get("albumIds"):
        return Response({"message": "Shared link access is only allowed in "
                                    "combination with an albumIds filter",
                         "error": "Bad Request", "statusCode": 400}, status=400)
    link, refusal = addressed(req)
    if link is None:
        return refusal
    page = int(req.body.get("page") or 1)
    start = (page - 1) * PAGE_SIZE
    items = link["assets"][start:start + PAGE_SIZE]
    more = start + PAGE_SIZE < len(link["assets"])
    return Response({"assets": {
        "count": len(items), "total": len(link["assets"]), "items": items,
        "nextPage": str(page + 1) if more else None,
    }})


if __name__ == "__main__":
    main(label="shared-link-masked")
