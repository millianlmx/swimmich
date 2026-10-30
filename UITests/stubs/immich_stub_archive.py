"""Immich API stub for archive / unarchive (`ArchiveUITests`).

Everything the app needs to boot, sign in and draw a grid comes from
`immich_stub_base`. This file owns the one thing the feature under test reads
and writes: **which of the six shell assets are archived**.

    python3 UITests/stubs/immich_stub_archive.py 8421

    xcodebuild test -scheme ImmichSwiftUI \\
        -only-testing:ImmichSwiftUIUITests/ArchiveUITests/<test>

STATE
* `STATE["archived"]` — ordered ids (among `TIMELINE_ASSETS`) the server
  considers archived. Defaults to all six, so the Archived filter is populated.
* `STATE["refuse"]` — when true, `PUT /api/assets` answers 500 and changes
  nothing (never 401: the app reads a 401 as a dead session and signs out).

ROUTES
* `GET /api/timeline/buckets` and `/bucket` are filtered by `visibility`:
  `archive` serves the archived ids, `timeline` the others, anything else falls
  through to the shell (Favorites sends no visibility).
* `PUT /api/assets` is logged (ids + visibility) BEFORE the refusal is decided,
  so a refused request is as legible in `/__requests` as an accepted one.
* `POST /api/search/metadata` answers the archived assets (the search viewer
  has no archive callback: the standalone path).
* `GET /api/map/markers` answers one marker per archived asset; the map
  knows no visibility, so its viewer must read `GET /api/assets/{id}`.
* `GET /api/__archive/configure?archived=<ids,comma>&refuse=0|1` replaces the
  state (journalled: filter it by path).
"""
from immich_stub_base import (
    Response, STATE, TIMELINE_ASSETS, TIMELINE_DAY, asset, bucket_payload, main, router,
)

# Recopied from immich_stub_map_settings.py: every marker sits in the same
# small box so the map fits itself around them.
CENTRE = (48.8584, 2.2945)


def fresh_state():
    return {"archived": list(TIMELINE_ASSETS), "refuse": False}


@router.reset
def fresh():
    STATE.update(fresh_state())


# The shell's `initial_state()` knows nothing of these keys: a stub run by hand
# (no `/__reset` ever sent) must answer its first request.
fresh()


def _active():
    return [aid for aid in TIMELINE_ASSETS if aid not in STATE["archived"]]


def _buckets(ids):
    return Response([{"timeBucket": TIMELINE_DAY, "count": len(ids)}] if ids else [])


@router.get("/api/timeline/buckets")
def buckets(req):
    visibility = req.params.get("visibility")
    if visibility == "archive":
        return _buckets(STATE["archived"])
    if visibility == "timeline":
        return _buckets(_active())
    return None


@router.get("/api/timeline/bucket")
def bucket(req):
    visibility = req.params.get("visibility")
    if visibility == "archive":
        ids = list(STATE["archived"])
        payload = bucket_payload(ids)
        payload["visibility"] = ["archive"] * len(ids)
        return Response(payload)
    if visibility == "timeline":
        return Response(bucket_payload(_active()))
    return None


@router.put("/api/assets")
def bulk_update(req):
    ids = req.body.get("ids", [])
    visibility = req.body.get("visibility")
    req.note(ids=ids, visibility=visibility)
    if STATE["refuse"]:
        return Response({"message": "boom", "error": "Internal Server Error", "statusCode": 500},
                        status=500)
    if visibility == "archive":
        STATE["archived"].extend(aid for aid in ids if aid not in STATE["archived"])
    elif visibility == "timeline":
        STATE["archived"] = [aid for aid in STATE["archived"] if aid not in ids]
    return Response(b"", status=204)


def asset_of(aid):
    payload = asset(aid)
    if aid in STATE["archived"]:
        payload["visibility"] = "archive"
        payload["isArchived"] = True
    return payload


@router.post("/api/search/metadata")
def search_metadata(req):
    items = [asset_of(aid) for aid in STATE["archived"]]
    return Response({"assets": {"count": len(items), "items": items,
                                "nextPage": None, "nextCursor": None}})


@router.get("/api/map/markers")
def map_markers(req):
    return Response([
        {"id": aid, "lat": CENTRE[0] + i * 0.005, "lon": CENTRE[1] + i * 0.005,
         "city": "Arch-" + aid[-1], "state": None, "country": "Stubland"}
        for i, aid in enumerate(STATE["archived"])
    ])


@router.prefix("GET", "/api/assets/")
def single_asset(req):
    # Thumbnails and originals (`<id>/thumbnail`, `<id>/original`) stay the shell's.
    if "/" in req.rest:
        return None
    return Response(asset_of(req.rest))


@router.get("/api/__archive/configure")
def configure(req):
    raw = req.params.get("archived", "")
    STATE["archived"] = [aid for aid in raw.split(",") if aid]
    STATE["refuse"] = req.params.get("refuse") == "1"
    return Response({"archived": STATE["archived"], "refuse": STATE["refuse"]})


if __name__ == "__main__":
    main(label="archive")
