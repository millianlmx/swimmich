"""Immich API stub for the "album pagination" scenario (`AlbumPaginationUITests`).

This stub exists to put ONE album in front of the app whose photos come in two
pages, against a server that announces v3.2.0 — the generation that ACCEPTS the
structured search body (`filter` / `orderBy` / `cursor`). The album detail must
nevertheless paginate in the FLAT shape (`albumIds`, `page`, `size`, `order`),
because the structured shape does not carry `albumIds` (a real server would
answer the whole library). A server that announces 3.2.0 and refuses a mixed
body is what catches a pagination that picks its shape from the version.

Routes (everything else — OAuth handshake, config, user, timeline, the real PNG
thumbnails of ANY asset id — comes from `immich_stub_base`):

* `GET /api/server/version` — always 3.2.0 (the shell says 1.119.0).
* `GET /api/albums` — the one album, `order` "asc", `assetCount` = both pages.
* `GET /api/albums/<id>` — that same album; the shell answers `[]` on this path,
  which does not decode as an album. Any other id is a 404.
* `POST /api/search/metadata` — flat pagination: page 1 (or no `page`) is
  `PAGE_1` with `nextPage` "2", page 2 is `PAGE_2` with `nextPage` null, any
  other page is empty. A body mixing a flat field with `filter`/`orderBy`/
  `cursor` is the server's own 400; a structured body, or one that does not
  target the album, gets an empty page.

The request bodies are journaled by the shell (`GET /__requests`), untouched.

    python3 UITests/stubs/immich_stub_album_pagination.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/album-pagination.uitest.log \\
        UITests/stubs/immich_stub_album_pagination.py \\
        AlbumPaginationUITests/test_AC6_albumDetailLoadsPageTwoOnScroll --erase
"""
from immich_stub_base import Response, asset, main, router

ALBUM = "22222222-2222-4222-8222-000000000101"
# Contained in neither "Albums" nor any other label of the tab bar.
ALBUM_NAME = "Paged Album"

# 60 photos: the last cell of page 1 is far below the first screen, so the
# request for page 2 can only come from scrolling. Ids are disjoint from each
# other and from the shell's six timeline assets (`aaaaaaaa-1111-…`).
PAGE_1 = [f"bbbbbbbb-1111-4111-8111-{i:012d}" for i in range(1, 61)]
PAGE_2 = [f"bbbbbbbb-2222-4222-8222-{i:012d}" for i in range(1, 7)]

# The deprecated flat fields of `MetadataSearchDto` and the structured ones: one
# body carries one group, never a mix (v3.2.0 `withShapeExclusivity` → 400).
# `size` and `withExif` are shared by both shapes and absent from the list.
FLAT_FIELDS = (
    "page", "rating", "ocr", "city", "state", "country", "make", "model",
    "lensModel", "type", "isFavorite", "takenAfter", "takenBefore", "order",
)
NEW_FIELDS = ("filter", "orderBy", "cursor")


def album_dto():
    """A fresh dict per call (the app and the scenario must never share one)."""
    return {
        "id": ALBUM,
        "albumName": ALBUM_NAME,
        "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": None,
        "shared": False,
        "hasSharedLink": False,
        "assetCount": len(PAGE_1) + len(PAGE_2),
        "isActivityEnabled": False,
        "order": "asc",
        "albumUsers": [],
    }


# MARK: - The server generation


@router.get("/api/server/version")
def reported_version(req):
    """Fixed v3.2.0: nothing to restore on `/__reset`."""
    return Response({"major": 3, "minor": 2, "patch": 0, "prerelease": None})


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


# MARK: - POST /api/search/metadata


def _clash(body):
    """The clashing deprecated field of a body that mixes the two languages, or
    `None` — the server's `withShapeExclusivity` rule, which is a 400."""
    if not any(key in body for key in NEW_FIELDS):
        return None
    return next((key for key in FLAT_FIELDS if key in body), None)


def _page(ids, next_page):
    # Built per request: `asset()` reads the current thumbhash.
    return Response({"assets": {
        "count": len(ids),
        "items": [asset(aid) for aid in ids],
        "nextPage": next_page,
        "nextCursor": None,
    }})


@router.post("/api/search/metadata")
def metadata_search(req):
    body = req.body
    clash = _clash(body)
    if clash is not None:
        return Response({
            "message": f"Deprecated field {clash} cannot be combined with orderBy/filter",
            "error": "Bad Request",
            "statusCode": 400,
        }, status=400)

    # Out of contract: a structured body, or one that does not target the album
    # (without `albumIds` a real server answers the whole library).
    if any(key in body for key in NEW_FIELDS) or body.get("albumIds") != [ALBUM]:
        return _page([], None)

    page = body.get("page")
    if page is None or (type(page) is int and page == 1):
        return _page(PAGE_1, "2")
    if type(page) is int and page == 2:
        return _page(PAGE_2, None)
    return _page([], None)


if __name__ == "__main__":
    main(label="album-pagination")
