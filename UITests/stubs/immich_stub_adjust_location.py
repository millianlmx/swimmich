"""Immich API stub for the adjust-location scenario (`AdjustLocationUITests`).

Thin on purpose: boot, sign-in, the timeline, thumbnails and the base asset DTO
come from `immich_stub_base`. This file adds what the feature needs to be
observable on the wire:

    python3 UITests/stubs/immich_stub_adjust_location.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/adjust-location.uitest.log \\
        UITests/stubs/immich_stub_adjust_location.py AdjustLocationUITests

TWO PHOTOS
    LOCATED   — the shell's first timeline asset, with `exifInfo` coordinates
                45.5 / 6.8 and a city. The info panel shows its map and the
                "Adjust Location" entry.
    UNLOCATED — the shell's second asset, left as the shell serves it (no
                coordinates): the info panel shows "Add Location" instead.

THE WRITE
    `PUT /api/assets/:id` is the feature. `req.note` records `latitudeSent` and
    `longitudeSent` so the scenario reads the exact numbers the app sent from
    `/__requests` (typed "48,8584" must arrive as 48.8584). A body that carries
    both keys is remembered, and the next `GET` of that asset answers with it,
    so the info panel can show the corrected place after the sheet closes.
"""
from immich_stub_base import Response, STATE, TIMELINE_ASSETS, asset, main, router

LOCATED = TIMELINE_ASSETS[0]
UNLOCATED = TIMELINE_ASSETS[1]
START = (45.5, 6.8)


def located_dto(aid):
    """The asset DTO with the coordinates this run last wrote (or the start)."""
    dto = asset(aid)
    written = STATE.setdefault("locations", {}).get(aid)
    coords = written if written else (START if aid == LOCATED else None)
    if coords is not None:
        lat, lon = coords
        dto["latitude"], dto["longitude"] = lat, lon
        dto["exifInfo"]["latitude"], dto["exifInfo"]["longitude"] = lat, lon
        dto["exifInfo"]["city"] = "Stubtown"
    return dto


@router.prefix("GET", "/api/assets/")
def read_asset(req):
    """The two photos' DTOs; everything else (thumbnails, originals) falls
    through to the shell, which serves the real PNG bytes."""
    aid = req.rest
    if "/" in aid or aid not in (LOCATED, UNLOCATED):
        return None
    return Response(located_dto(aid))


@router.prefix("PUT", "/api/assets/")
def write_location(req):
    """`PUT /api/assets/:id` — the only mutation this feature makes."""
    aid = req.rest
    if "/" in aid:
        return None
    req.note(latitudeSent=req.body.get("latitude"), longitudeSent=req.body.get("longitude"))
    if "latitude" in req.body and "longitude" in req.body:
        STATE.setdefault("locations", {})[aid] = (req.body["latitude"], req.body["longitude"])
    return Response(located_dto(aid))


@router.reset
def fresh():
    """`/__reset`: every run starts from the original coordinates."""
    STATE["locations"] = {}


if __name__ == "__main__":
    main(label="adjust-location")
