"""Immich API stub for the "album pagination, three pages" scenarios
(`AlbumPaginationUITests`: AC-254, AC-255, AC-258, AC-259).

The two-page stub (`immich_stub_album_pagination.py`) cannot tell a grid that
asks for the next page when its LAST CELL is on screen from one that chains the
pages off-screen: with two pages there is no "page after the next". This stub
serves three albums of three pages each, against a server that announces v3.2.0
(the flat search shape is the app's choice, as in the two-page stub):

* `TALL_ALBUM`    « Three Tall Pages »        — 60 + 60 + 60 photos, every page
  taller than a screen. After page 2 arrives the last cell is far below the
  screen, so page 3 must wait for the next scroll to the bottom.
* `SHORT_ALBUM`   « Short Middle Page »       — 60 + 3 + 6 photos. Page 2 is one
  row: its last cell is on screen as soon as it arrives, page 3 follows without
  any gesture.
* `OVERLAP_ALBUM` « Overlapping Middle Page » — 60 + 3 + 3 photos, page 2 being
  the LAST 3 ids of page 1 (no new cell) and answered after
  `OVERLAP_PAGE_2_DELAY_S` seconds. No cell appears when it arrives, so only the
  grid footer coming back on screen can ask for page 3; the delay keeps the
  footer still on screen while page 2 is in flight.

Routes (everything else comes from `immich_stub_base`):

* `GET /api/server/version` — always 3.2.0 (the shell says 1.119.0).
* `GET /api/albums` — the three albums, `order` "asc".
* `GET /api/albums/<id>` — that album; the shell answers `[]` on this path,
  which does not decode as an album. Any other id is a 404.
* `POST /api/search/metadata` — flat pagination: page 1 (or no `page`) with
  `nextPage` "2", page 2 with `nextPage` "3", page 3 with `nextPage` null, any
  other page empty. A body mixing a flat field with `filter`/`orderBy`/`cursor`
  is the server's own 400; a structured body, or one that does not target one of
  the three albums, gets an empty page.

The request bodies are journaled by the shell (`GET /__requests`), untouched.

    python3 UITests/stubs/immich_stub_album_pagination_three_pages.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/album-three-pages.uitest.log \\
        UITests/stubs/immich_stub_album_pagination_three_pages.py \\
        AlbumPaginationUITests/test_AC_254_noThirdPageWithoutReachingEnd --erase
"""
import time

from immich_stub_base import Response, asset, main, router

TALL_ALBUM = "22222222-2222-4222-8222-000000000201"
SHORT_ALBUM = "22222222-2222-4222-8222-000000000202"
OVERLAP_ALBUM = "22222222-2222-4222-8222-000000000203"
# Contained in neither "Albums", nor any other label of the tab bar, nor in each
# other (a card is found by a `label CONTAINS` predicate).
TALL_NAME = "Three Tall Pages"
SHORT_NAME = "Short Middle Page"
OVERLAP_NAME = "Overlapping Middle Page"

# Ids are disjoint from each other, from the two-page stub's and from the shell's
# six timeline assets (`aaaaaaaa-1111-…`). 60 photos = 20 rows: far taller than
# a screen. 3 photos = one row.
TALL_1 = [f"cccccccc-1111-4111-8111-{i:012d}" for i in range(1, 61)]
TALL_2 = [f"cccccccc-2222-4222-8222-{i:012d}" for i in range(1, 61)]
TALL_3 = [f"cccccccc-3333-4333-8333-{i:012d}" for i in range(1, 61)]

SHORT_1 = [f"dddddddd-1111-4111-8111-{i:012d}" for i in range(1, 61)]
SHORT_2 = [f"dddddddd-2222-4222-8222-{i:012d}" for i in range(1, 4)]
SHORT_3 = [f"dddddddd-3333-4333-8333-{i:012d}" for i in range(1, 7)]

OVERLAP_1 = [f"ffffffff-1111-4111-8111-{i:012d}" for i in range(1, 61)]
OVERLAP_2 = OVERLAP_1[-3:]  # already served: the page adds no cell
OVERLAP_3 = [f"ffffffff-3333-4333-8333-{i:012d}" for i in range(1, 4)]
# Stays under the app's `timeoutIntervalForRequest` (20 s).
OVERLAP_PAGE_2_DELAY_S = 5

# album id -> (name, [page 1, page 2, page 3])
ALBUMS = {
    TALL_ALBUM: (TALL_NAME, [TALL_1, TALL_2, TALL_3]),
    SHORT_ALBUM: (SHORT_NAME, [SHORT_1, SHORT_2, SHORT_3]),
    OVERLAP_ALBUM: (OVERLAP_NAME, [OVERLAP_1, OVERLAP_2, OVERLAP_3]),
}

# The deprecated flat fields of `MetadataSearchDto` and the structured ones: one
# body carries one group, never a mix (v3.2.0 `withShapeExclusivity` → 400).
# `size` and `withExif` are shared by both shapes and absent from the list.
FLAT_FIELDS = (
    "page", "rating", "ocr", "city", "state", "country", "make", "model",
    "lensModel", "type", "isFavorite", "takenAfter", "takenBefore", "order",
)
NEW_FIELDS = ("filter", "orderBy", "cursor")


def album_dto(album_id):
    """A fresh dict per call (the app and the scenario must never share one)."""
    name, pages = ALBUMS[album_id]
    return {
        "id": album_id,
        "albumName": name,
        "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": None,
        "shared": False,
        "hasSharedLink": False,
        "assetCount": len({aid for page in pages for aid in page}),
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
    return Response([album_dto(album_id) for album_id in (TALL_ALBUM, SHORT_ALBUM, OVERLAP_ALBUM)])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if not req.rest or "/" in req.rest:
        return None  # a sub-resource: the shell's own answer
    if req.rest in ALBUMS:
        return Response(album_dto(req.rest))
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

    # Out of contract: a structured body, or one that does not target one of the
    # albums (without `albumIds` a real server answers the whole library).
    album_ids = body.get("albumIds")
    if (any(key in body for key in NEW_FIELDS)
            or not isinstance(album_ids, list) or len(album_ids) != 1
            or album_ids[0] not in ALBUMS):
        return _page([], None)
    album_id = album_ids[0]
    pages = ALBUMS[album_id][1]

    page = body.get("page")
    if page is None or (type(page) is int and page == 1):
        return _page(pages[0], "2")
    if type(page) is int and page == 2:
        if album_id == OVERLAP_ALBUM:
            # The shell journaled the request before this handler runs, and the
            # server is threaded: the log is readable while this sleeps.
            time.sleep(OVERLAP_PAGE_2_DELAY_S)
        return _page(pages[1], "3")
    if type(page) is int and page == 3:
        return _page(pages[2], None)
    return _page([], None)


if __name__ == "__main__":
    main(label="album-pagination-three-pages")
