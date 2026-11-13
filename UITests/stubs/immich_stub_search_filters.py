"""Immich API stub for the "search-filters" scenario (`SearchFiltersUITests`).

This stub exists for ONE reason: `POST /api/search/metadata` speaks two
languages, and which one the app must use depends on the SERVER GENERATION —
a fact only a stub can control. The app asks `/api/server/version` and then
sends either the v3.2.0 structured body (`filter` / `orderBy` / `cursor`) or the
deprecated flat one (`city`, `rating`, `page`, …). The two are mutually
exclusive: one body carries one of the two groups, never a mix (v3.2.0's
`withShapeExclusivity` answers 400). So this stub:

* serves `/api/server/version` from a value the scenario sets
  (`/__version?major=3&minor=2`), because the whole scenario is "the same filter,
  two generations, two bodies";
* ANSWERS the body the way the body asked to be answered: the structured shape
  gets `nextCursor` and never `nextPage`, the flat one gets `nextPage` and never
  a cursor. A stub that answered both would let a scenario pass while the app
  mixed the two languages;
* REFUSES a mixed body with the server's own 400, so the rule the scenario
  asserts on the wire is also the rule the stub enforces;
* serves a small LIBRARY behind the search (people Alice, Bob and the hidden
  Carla, the tags `Voyages` and `Voyages/Japon`, archived / out-of-album /
  tagged / named photos) and FILTERS it on the criteria the body carries, in
  both languages, with the server's semantics — so a scenario asserts which
  tiles appear, not only what was sent;
* serves `POST /api/search/smart` (flat criteria, `page`, a 400 on `filter` /
  `orderBy` / `cursor`), `GET /api/people` and `GET /api/tags`.
* serves the writes of the selection bar (`SearchCriteriaUITests` L-23b) and applies
  them to the library, so the next search shows them: `PUT /api/assets` (bulk
  visibility), `DELETE /api/assets` (the bin), `PUT /api/assets/{id}` (favourite),
  `POST /api/stacks`, `POST /api/download/info`, `GET /api/albums` and
  `PUT /api/albums/{id}/assets`;
* pages the results on demand: `GET /__paging?size=2&delay=6` serves `size`
  results per page, every page after the first `delay` seconds late.

    python3 UITests/stubs/immich_stub_search_filters.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/search-filters.uitest.log \\
        UITests/stubs/immich_stub_search_filters.py SearchFiltersUITests/test_searchFilters

Everything else — the OAuth handshake, the server config, the user, the
timeline day, the real PNG thumbnails — comes from `immich_stub_base`.

WHY `/__version` IS GRAFTED RATHER THAN REGISTERED
    The shell answers every `/__…` path itself, before the router is consulted
    (`StubHandler._control`), so a feature route on `/__version` would never be
    reached — and the shell is a committed file shared by every scenario of the
    wave, which a feature stub must not edit. The one control route this feature
    owns is therefore wrapped around the shell's own, below. Consequence: a
    scenario sets the generation with `GET /__version?major=3&minor=2`, and
    `/__reset` puts it back to the generation the shell serves (`1.119.0`).
"""
import time
from urllib.parse import parse_qsl

import immich_stub_base as base
from immich_stub_base import ME_USER, STATE, TIMELINE_ASSETS, Response, asset, main, png, router

# What the shell answers for `/api/server/version` — the generation a scenario
# gets unless it asks for another one. Pre-v3.2.0 on purpose: a stub that
# defaulted to 3.2.0 would hide the flat route from any other scenario that
# happens to reuse this file.
DEFAULT_VERSION = (1, 119, 0)

# The opaque token the structured route hands out for page 2. Opaque on purpose,
# like the real one: a scenario asserts it travels back VERBATIM, and a token
# that looked like a page number would make the two paginations confusable.
CURSOR = "stub-cursor-0001"

# The deprecated flat fields of `MetadataSearchDto` this stub knows about: the
# ones the sheet writes, the criteria of the people / tags / display / text
# pickers, plus the two pagination/order fields. `query`, `size` and `withExif`
# are NOT in the list — the structured shape sends those too, and they are the
# fields both shapes legitimately share.
FLAT_FIELDS = (
    "page", "rating", "ocr", "city", "state", "country", "make", "model",
    "lensModel", "type", "isFavorite", "takenAfter", "takenBefore", "order",
    "personIds", "tagIds", "isNotInAlbum", "visibility", "originalFileName", "description",
)
NEW_FIELDS = ("filter", "orderBy", "cursor")


# MARK: - The library behind the search
#
# Fixed UUID v4s, so a scenario names a photo by its id. Each fixture says what
# the criteria of the search match on: who is on it, its tags, its visibility,
# whether it sits in an album, its file name and description — and the words a
# smart (CLIP) search would find it by.

ALICE = "a11ce000-0000-4000-8000-000000000001"
BOB = "b0b00000-0000-4000-8000-000000000002"
CARLA = "ca41a000-0000-4000-8000-000000000003"
PEOPLE = [
    {"id": ALICE, "name": "Alice", "isHidden": False},
    {"id": BOB, "name": "Bob", "isHidden": False},
    {"id": CARLA, "name": "Carla", "isHidden": True},
]

TAG_VOYAGES = "7a9e5000-0000-4000-8000-000000000001"
TAG_JAPON = "7a9e5000-0000-4000-8000-000000000002"
TAGS = [
    {"id": TAG_VOYAGES, "name": "Voyages", "value": "Voyages", "parentId": None},
    {"id": TAG_JAPON, "name": "Japon", "value": "Voyages/Japon", "parentId": TAG_VOYAGES},
]
# A tag also matches the photos of its descendants, like the server's
# `tag_closure`: asking for `Voyages` finds a photo tagged `Voyages/Japon`.
TAG_PARENT = {TAG_JAPON: TAG_VOYAGES}

P1 = "f1000000-0000-4000-8000-000000000001"
P2 = "f1000000-0000-4000-8000-000000000002"
P3 = "f1000000-0000-4000-8000-000000000003"
P4 = "f1000000-0000-4000-8000-000000000004"
J1 = "f1000000-0000-4000-8000-000000000005"
A1 = "f1000000-0000-4000-8000-000000000006"
N1 = "f1000000-0000-4000-8000-000000000007"
Z1 = "f1000000-0000-4000-8000-000000000008"
IMG = "f1000000-0000-4000-8000-000000000009"
DSC = "f1000000-0000-4000-8000-00000000000a"


def _fixture(aid, name, people=(), tags=(), visibility="timeline", in_album=True,
             description="", keywords=()):
    return {"id": aid, "name": name, "people": list(people), "tags": list(tags),
            "visibility": visibility, "inAlbum": in_album, "description": description,
            "keywords": list(keywords)}


FIXTURES = [
    _fixture(P1, "p1.jpg", people=[ALICE]),
    _fixture(P2, "p2.jpg", people=[ALICE, BOB]),
    _fixture(P3, "p3.jpg", people=[ALICE], keywords=["plage"]),
    _fixture(P4, "p4.jpg", keywords=["plage"]),
    _fixture(J1, "j1.jpg", tags=[TAG_JAPON]),
    _fixture(A1, "a1.jpg", visibility="archive"),
    _fixture(N1, "n1.jpg", in_album=False),
    # Z1 meets every criterion of the cumulative scenario: archived, not in an
    # album, tagged `Voyages/Japon`, named and described after Kyoto — and shot
    # with Alice and Bob, so a search on every criterion at once still has a hit
    # (archived, it never shows in a search where "Archive" is unticked).
    _fixture(Z1, "KYOTO_0042.JPG", people=[ALICE, BOB], tags=[TAG_JAPON], visibility="archive",
             in_album=False, description="Temple de Kyoto"),
    _fixture(IMG, "IMG_1234.HEIC", description="Plage de Biarritz"),
    _fixture(DSC, "DSC_0001.JPG"),
]


def _edited(fixture):
    """The fixture as the batch actions left it (favourite, visibility, bin)."""
    edit = STATE.get("edits", {}).get(fixture["id"])
    return {**fixture, **edit} if edit else fixture


def _library():
    """The six photos of the shell's timeline, then the fixtures above."""
    base = [_fixture(aid, f"{aid[:4]}-{aid[-2:]}.jpg") for aid in TIMELINE_ASSETS]
    return [_edited(fixture) for fixture in base + FIXTURES]


def _asset(fixture):
    item = asset(fixture["id"])
    item["originalFileName"] = fixture["name"]
    item["visibility"] = fixture["visibility"]
    item["isArchived"] = fixture["visibility"] == "archive"
    item["isFavorite"] = bool(fixture.get("favorite"))
    if fixture["description"]:
        item["exifInfo"]["description"] = fixture["description"]
    return item


def _with_ancestors(tag_ids):
    closure = set(tag_ids)
    for tag in tag_ids:
        while tag in TAG_PARENT:
            tag = TAG_PARENT[tag]
            closure.add(tag)
    return closure


def _criteria(body):
    """The criteria of a search body, read from whichever language it speaks."""
    flt = body.get("filter") or {}

    def ids(key):
        group = flt.get(key)
        return (group or {}).get("all") if group is not None else body.get(key)

    def like(key):
        pattern = flt.get(key)
        return (pattern or {}).get("like") if pattern is not None else body.get(key)

    has_albums = flt.get("hasAlbums")
    not_in_album = (has_albums.get("eq") is False) if has_albums is not None else bool(body.get("isNotInAlbum"))
    visibility = flt.get("visibility")
    visibility = (visibility or {}).get("eq") if visibility is not None else body.get("visibility")
    return {"people": ids("personIds") or [], "tags": ids("tagIds") or [],
            "notInAlbum": not_in_album, "visibility": visibility,
            "name": like("originalFileName"), "description": like("description")}


def _matches(fixture, crit):
    """The server's semantics: people and tags are "all of them" (tags
    descendants included), visibility absent means timeline and archive, text
    is "contains" without regard to case."""
    if fixture.get("trashed"):
        return False
    if not set(crit["people"]) <= set(fixture["people"]):
        return False
    if not set(crit["tags"]) <= _with_ancestors(fixture["tags"]):
        return False
    if crit["notInAlbum"] and fixture["inAlbum"]:
        return False
    if crit["visibility"] is not None and fixture["visibility"] != crit["visibility"]:
        return False
    if crit["visibility"] is None and fixture["visibility"] not in ("timeline", "archive"):
        return False
    if crit["name"] and crit["name"].lower() not in fixture["name"].lower():
        return False
    if crit["description"] and crit["description"].lower() not in fixture["description"].lower():
        return False
    return True


def _results(body):
    crit = _criteria(body)
    return [_asset(fixture) for fixture in _library() if _matches(fixture, crit)]


# MARK: - Selection and batch actions (L-23b)
#
# The writes of the selection bar, applied to the library so the next search
# shows them: a favourite, a visibility (`archive`, `timeline`, `locked`) and
# the bin. Every write is in `/__requests` (method, path, body), which is what a
# scenario asserts on.

ALBUM = "a1b2c3d4-0000-4000-8000-000000000001"


def _edit(ids, **changes):
    for aid in ids:
        STATE.setdefault("edits", {}).setdefault(aid, {}).update(changes)


def _find(aid):
    return next((fixture for fixture in _library() if fixture["id"] == aid), None)


@router.put("/api/assets")
def bulk_update(req):
    """`PUT /api/assets`: the bulk visibility the archive, unarchive and locked
    folder actions send."""
    visibility = req.body.get("visibility")
    if visibility:
        _edit(req.body.get("ids", []), visibility=visibility)
    return Response(b"", status=204)


@router.delete("/api/assets")
def bulk_delete(req):
    """`DELETE /api/assets`: `force: false` is the bin."""
    _edit(req.body.get("ids", []), trashed=True)
    return Response(b"", status=204)


@router.prefix("PUT", "/api/assets/")
def update_asset(req):
    """`PUT /api/assets/{id}`: the favourite of one photo."""
    if "/" in req.rest or _find(req.rest) is None:
        return None
    if "isFavorite" in req.body:
        _edit([req.rest], favorite=bool(req.body["isFavorite"]))
    return Response(_asset(_find(req.rest)))


@router.post("/api/stacks")
def create_stack(req):
    ids = req.body.get("assetIds", [])
    return Response({"id": "stack-new", "primaryAssetId": ids[0] if ids else "",
                     "assets": [_asset(_find(aid)) for aid in ids if _find(aid)]}, status=201)


@router.post("/api/download/info")
def download_info(req):
    ids = req.body.get("assetIds", [])
    return Response({"totalSize": 2048 * len(ids), "archives": [{"assetIds": ids, "size": 2048 * len(ids)}]})


@router.get("/api/albums")
def albums(req):
    """The one album a selection can be added to (none shared with the user)."""
    if req.params.get("shared") == "true":
        return Response([])
    return Response([{
        "id": ALBUM, "albumName": "Stub Album", "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": None, "shared": False, "hasSharedLink": False,
        "assetCount": 0, "isActivityEnabled": True, "order": "desc",
        "ownerId": ME_USER["id"], "albumUsers": [],
        "owner": {k: ME_USER[k] for k in ("id", "name", "email", "profileImagePath",
                                          "avatarColor", "profileChangedAt")},
    }])


@router.prefix("PUT", "/api/albums/")
def add_to_album(req):
    """`PUT /api/albums/{id}/assets`: one answer per id, as the server's."""
    if not req.rest.endswith("/assets"):
        return None
    return Response([{"id": aid, "success": True} for aid in req.body.get("ids", [])])


def _paged_answer(items, body):
    """One page of `items` when a scenario asked for a page size (`/__paging`):
    the slice and the token of the next page, `None` on the last. A delay slows
    every page after the first, so the grid is usable while it loads."""
    page = body.get("page") or 1
    if page > 1 and STATE.get("page_delay"):
        time.sleep(STATE["page_delay"])
    size = STATE["page_size"]
    start = (page - 1) * size
    chunk = items[start:start + size]
    token = str(page + 1) if start + size < len(items) else None
    return Response({"assets": {"count": len(chunk), "items": chunk, "nextPage": token, "nextCursor": None}})


# MARK: - People and tags


@router.get("/api/people")
def people(req):
    """The named people; the hidden one only when asked for."""
    with_hidden = req.params.get("withHidden") == "true"
    listed = [person for person in PEOPLE if with_hidden or not person["isHidden"]]
    return Response({"people": listed, "hidden": sum(1 for p in PEOPLE if p["isHidden"]),
                     "total": len(listed), "hasNextPage": False})


@router.prefix("GET", "/api/people/")
def person_thumbnail(req):
    """`/api/people/{id}/thumbnail`: a real PNG whose colour follows the id."""
    if not req.rest.endswith("/thumbnail"):
        return None
    return Response(png(req.rest.split("/")[0]), ctype="image/png",
                    headers={"Cache-Control": "no-store"})


@router.get("/api/tags")
def tags(req):
    return Response(TAGS)


# MARK: - The server generation


@router.get("/api/server/version")
def reported_version(req):
    """The generation the scenario asked for — never hard-coded here.

    Registered on the router so it wins over the shell's own route: the router
    is consulted first, exact paths before prefixes.
    """
    major, minor, patch = STATE.get("version", DEFAULT_VERSION)
    return Response({"major": major, "minor": minor, "patch": patch, "prerelease": None})


@router.reset
def fresh_version():
    """`/__reset` puts the generation back to what the shell serves, so no run
    inherits the previous one's server."""
    STATE["version"] = DEFAULT_VERSION
    STATE["edits"] = {}
    STATE["page_size"] = 0
    STATE["page_delay"] = 0


# MARK: - The two shapes of `POST /api/search/metadata`


def _clash(body):
    """The clashing deprecated field of a body that mixes the two languages, or
    `None` — the server's `withShapeExclusivity` rule, which is a 400."""
    if not any(key in body for key in NEW_FIELDS):
        return None
    return next((key for key in FLAT_FIELDS if key in body), None)


@router.post("/api/search/metadata")
def metadata_search(req):
    """Answers the shape the request was written in, pagination included.

    `nextPage` is a STRING (`SearchAssetResponseDto.nextPage` is `String?` in
    this app), so the flat page 2 keeps its flat pagination and stops there: a
    server that handed the same token to both routes would let the app paginate
    a structured search with a page number and never be caught.
    """
    body = req.body
    clash = _clash(body)
    if clash is not None:
        return Response({
            "message": f"Deprecated field {clash} cannot be combined with orderBy/filter",
            "error": "Bad Request",
            "statusCode": 400,
        }, status=400)

    structured = any(key in body for key in NEW_FIELDS)
    if not structured and STATE.get("page_size"):
        return _paged_answer(_results(body), body)
    if body.get("cursor") is not None or (body.get("page") or 1) > 1:
        # Second page of either language: the fixture has no more rows, so the
        # pagination stops here (no token of either kind).
        return Response({"assets": {"count": 0, "items": [], "nextPage": None, "nextCursor": None}})

    items = _results(body)
    token = {"nextPage": None, "nextCursor": CURSOR} if structured else {"nextPage": "2", "nextCursor": None}
    return Response({"assets": {"count": len(items), "items": items, **token}})


@router.post("/api/search/smart")
def smart_search(req):
    """The smart (CLIP) route: flat criteria only, paginated by `page`.

    v3.4.0 refuses `filter`, `orderBy` and `cursor` here with the same 400 as a
    mixed Metadata body, so a Smart request that reached for the structured
    language is caught on every generation. The photos found are the ones whose
    keywords contain the query, narrowed by the same criteria as Metadata.
    """
    body = req.body
    clash = next((key for key in NEW_FIELDS if key in body), None)
    if clash is not None:
        return Response({
            "message": f"Unrecognized key {clash} on the smart search",
            "error": "Bad Request",
            "statusCode": 400,
        }, status=400)

    if (body.get("page") or 1) > 1 and not STATE.get("page_size"):
        return Response({"assets": {"count": 0, "items": [], "nextPage": None, "nextCursor": None}})

    query = (body.get("query") or "").strip().lower()
    crit = _criteria(body)
    found = [_asset(fixture) for fixture in _library()
             if _matches(fixture, crit)
             and (not query or any(query in word for word in fixture["keywords"]))]
    if STATE.get("page_size"):
        return _paged_answer(found, body)
    return Response({"assets": {"count": len(found), "items": found, "nextPage": "2", "nextCursor": None}})


# MARK: - `/__version`, grafted onto the shell's control routes


_shell_control = base.StubHandler._control


def _control(self, path, query):
    if path == "/__version":
        params = dict(parse_qsl(query, keep_blank_values=True))
        try:
            STATE["version"] = (int(params["major"]), int(params["minor"]), int(params.get("patch", 0)))
        except (KeyError, ValueError):
            return Response({"error": "major and minor are required"}, status=400)
        major, minor, patch = STATE["version"]
        return Response({"version": f"{major}.{minor}.{patch}"})
    if path == "/__paging":
        params = dict(parse_qsl(query, keep_blank_values=True))
        STATE["page_size"] = int(params.get("size", 0))
        STATE["page_delay"] = float(params.get("delay", 0))
        return Response({"size": STATE["page_size"], "delay": STATE["page_delay"]})
    return _shell_control(self, path, query)


base.StubHandler._control = _control


if __name__ == "__main__":
    main(label="search-filters")
