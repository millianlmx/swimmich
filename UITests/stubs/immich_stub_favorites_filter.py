"""Immich API stub for the Favorites-filter scenario (`FavoritesFilterUITests`).

Everything the app needs to boot, sign in and draw the timeline comes from
`immich_stub_base`. This file adds what the feature owns: a server-side set of
favorites that the two timeline routes FILTER on, and the favorite write that
changes it:

    python3 UITests/stubs/immich_stub_favorites_filter.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/favorites-filter.uitest.log \\
        UITests/stubs/immich_stub_favorites_filter.py \\
        FavoritesFilterUITests/test_AC21_viewerUnfavoriteThenRefavorite

WHAT THE WIRE HAS TO SHOW
    0. Every asset is a favorite EXCEPT the witness (`WITNESS`, the last one of
       the timeline): it shows on the All grid and not on the Favorites grid.
       It is the proof that the grid on screen is the filtered grid, reloaded
       from the server — with six favorites out of six, the tile left by the
       All grid would pass for the Favorites one.
    1. `GET /api/timeline/bucket` carries `isFavorite=true` like `/buckets`
       does. A stub that answered `/bucket` with the same favorites whatever the
       query could not tell the two apart: this one answers the whole timeline
       (favorites and non-favorites) when the filter is missing.
    2. The viewer's two heart taps write `PATCH /api/assets/:id` with
       `isFavorite` false, then true. The value sent is recorded by `req.note`
       (`isFavoriteSent`), and the favorites set follows it, so a refresh of the
       filtered grid shows the re-favorited asset again — the proof the second
       write reached the server.
"""
from immich_stub_base import (
    Response, STATE, TIMELINE_ASSETS, TIMELINE_DAY, asset, bucket_payload, main, router,
)

# The non-favorite asset: the scenario's `witness` (FavoritesFilterUITests) is this id.
WITNESS = TIMELINE_ASSETS[-1]

# Also set at import: a by-hand run that never calls `/__reset` must not crash.
STATE["favorites"] = [a for a in TIMELINE_ASSETS if a != WITNESS]


@router.get("/api/timeline/buckets")
def buckets(req):
    """The months of the (filtered) timeline: one day, counting what matches."""
    if req.params.get("isFavorite") == "true":
        favorites = STATE["favorites"]
        return Response([{"timeBucket": TIMELINE_DAY, "count": len(favorites)}] if favorites else [])
    return Response([{"timeBucket": TIMELINE_DAY, "count": len(TIMELINE_ASSETS)}])


@router.get("/api/timeline/bucket")
def bucket(req):
    """The content of the day: favorites only when `isFavorite=true` came along."""
    favorites = STATE["favorites"]
    if req.params.get("isFavorite") == "true":
        payload = bucket_payload(favorites)
        payload["isFavorite"] = [True] * len(favorites)
    else:
        payload = bucket_payload(TIMELINE_ASSETS)
        payload["isFavorite"] = [aid in favorites for aid in TIMELINE_ASSETS]
    return Response(payload)


@router.prefix("PATCH", "/api/assets/")
def write_favorite(req):
    """`PATCH /api/assets/:id` — the favorite write of the viewer's heart."""
    aid = req.rest
    if "/" in aid:
        # A sub-resource of an asset (`/thumbnail`, `/original`): not ours.
        return None
    sent = req.body.get("isFavorite")
    req.note(isFavoriteSent=sent)
    if sent is False and aid in STATE["favorites"]:
        STATE["favorites"].remove(aid)
    elif sent is True and aid not in STATE["favorites"]:
        # Keep the timeline's own order, whatever the order of the writes.
        STATE["favorites"] = [a for a in TIMELINE_ASSETS if a in STATE["favorites"] or a == aid]
    dto = asset(aid)
    dto["isFavorite"] = bool(sent)
    return Response(dto)


@router.reset
def fresh():
    """`/__reset`: every asset is a favorite again, except the witness."""
    STATE["favorites"] = [a for a in TIMELINE_ASSETS if a != WITNESS]


if __name__ == "__main__":
    main(label="favorites-filter")
