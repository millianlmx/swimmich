"""Immich API stub for the "plurals" scenarios (`PluralsUITests`).

This stub puts two albums in front of the app: one of ONE photo and one of TWO,
so the counters and the selection title of an album can be read in the
singular and in the plural, in every language the app ships. The server keeps
the shell's version (2.0.0, so older than 3.2.0): the Filters sheet of the
search then shows its "requires Immich 3.2 or later" notice.

Routes (everything else — OAuth handshake, config, user, the one-day timeline,
the real PNG thumbnails of ANY asset id — comes from `immich_stub_base`):

* `GET /api/albums` — `ONE` ("Uno", `assetCount` 1) and `TWO` ("Duo",
  `assetCount` 2).
* `GET /api/albums/<id>` — that album; the shell answers `[]` on this path,
  which does not decode as an album. Any other id is a 404.
* `POST /api/search/metadata` — the flat album listing (`albumIds`, `page`):
  `[ONE]` answers its single asset, `[TWO]` its two, `nextPage` null; any other
  body gets an empty page.

The request bodies are journaled by the shell (`GET /__requests`), untouched.

    python3 UITests/stubs/immich_stub_plurals.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/plurals.uitest.log \
        UITests/stubs/immich_stub_plurals.py \
        PluralsUITests/test_AC_32_albumCountsAndSelectionInFourLanguages --erase
"""
from immich_stub_base import Response, asset, main, router

ONE = "33333333-3333-4333-8333-000000000001"
TWO = "33333333-3333-4333-8333-000000000002"
NAMES = {ONE: "Uno", TWO: "Duo"}

# Disjoint from each other and from the shell's six timeline assets
# (`aaaaaaaa-1111-…`).
ASSETS = {
    ONE: ["a1a1a1a1-3333-4333-8333-000000000001"],
    TWO: [
        "a1a1a1a1-3333-4333-8333-000000000002",
        "a1a1a1a1-3333-4333-8333-000000000003",
    ],
}


def album_dto(album_id):
    """A fresh dict per call (the app and the scenario must never share one)."""
    return {
        "id": album_id,
        "albumName": NAMES[album_id],
        "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": None,
        "shared": False,
        "hasSharedLink": False,
        "assetCount": len(ASSETS[album_id]),
        "isActivityEnabled": False,
        "order": "desc",
        "albumUsers": [],
    }


# MARK: - Albums


@router.get("/api/albums")
def albums(req):
    return Response([album_dto(ONE), album_dto(TWO)])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if not req.rest or "/" in req.rest:
        return None  # a sub-resource: the shell's own answer
    if req.rest in NAMES:
        return Response(album_dto(req.rest))
    return Response({"error": "not found", "path": req.path}, status=404)


# MARK: - POST /api/search/metadata


def _page(ids):
    # Built per request: `asset()` reads the current thumbhash.
    return Response({"assets": {
        "count": len(ids),
        "items": [asset(aid) for aid in ids],
        "nextPage": None,
        "nextCursor": None,
    }})


@router.post("/api/search/metadata")
def metadata_search(req):
    album_ids = req.body.get("albumIds")
    if isinstance(album_ids, list) and len(album_ids) == 1 and album_ids[0] in ASSETS:
        return _page(ASSETS[album_ids[0]])
    return _page([])


if __name__ == "__main__":
    main(label="plurals")
