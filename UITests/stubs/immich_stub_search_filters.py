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
  asserts on the wire is also the rule the stub enforces.

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
    `/__reset` puts it back to the generation the shell serves (`2.0.0`).
"""
from urllib.parse import parse_qsl

import immich_stub_base as base
from immich_stub_base import STATE, TIMELINE_ASSETS, Response, asset, main, router

# What the shell answers for `/api/server/version` — the generation a scenario
# gets unless it asks for another one. Pre-v3.2.0 on purpose: a stub that
# defaulted to 3.2.0 would hide the flat route from any other scenario that
# happens to reuse this file.
DEFAULT_VERSION = (2, 0, 0)

# The opaque token the structured route hands out for page 2. Opaque on purpose,
# like the real one: a scenario asserts it travels back VERBATIM, and a token
# that looked like a page number would make the two paginations confusable.
CURSOR = "stub-cursor-0001"

# The deprecated flat fields of `MetadataSearchDto` this stub knows about: the
# ones the sheet writes plus the two pagination/order fields. `query`, `size`
# and `withExif` are NOT in the list — the structured shape sends those too, and
# they are the fields both shapes legitimately share.
FLAT_FIELDS = (
    "page", "rating", "ocr", "city", "state", "country", "make", "model",
    "lensModel", "type", "isFavorite", "takenAfter", "takenBefore", "order",
)
NEW_FIELDS = ("filter", "orderBy", "cursor")


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
    if body.get("cursor") is not None or (body.get("page") or 1) > 1:
        # Second page of either language: the fixture has no more rows, so the
        # pagination stops here (no token of either kind).
        return Response({"assets": {"count": 0, "items": [], "nextPage": None, "nextCursor": None}})

    items = [asset(aid) for aid in TIMELINE_ASSETS]
    token = {"nextPage": None, "nextCursor": CURSOR} if structured else {"nextPage": "2", "nextCursor": None}
    return Response({"assets": {"count": len(items), "items": items, **token}})


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
    return _shell_control(self, path, query)


base.StubHandler._control = _control


if __name__ == "__main__":
    main(label="search-filters")
