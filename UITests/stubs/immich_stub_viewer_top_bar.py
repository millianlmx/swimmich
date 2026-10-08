"""Immich API stub for the viewer top-bar scenario (`ViewerTopBarUITests`).

Thin on purpose: the OAuth handshake, the server config, the user, one day of
timeline and the real PNG thumbnails come from `immich_stub_base`. This file
adds the two things the top bar's badge needs and the base does not carry:

  * a place (`city`) on every timeline asset, read from `STATE["place"]`, and a
    date (`fileCreatedAt` 2 May 2025, the narrowest long date in French), so the
    badge's width is the one the scenario measures;
  * `POST /control/place`, which arms the place the NEXT launch will show. The
    timeline is fetched at launch, so the scenario arms, then relaunches.

    python3 UITests/stubs/immich_stub_viewer_top_bar.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/viewer-topbar-<méthode>.log \\
        UITests/stubs/immich_stub_viewer_top_bar.py ViewerTopBarUITests/<méthode> --erase

The place is the only input the badge width depends on, so the scenario can
drive all three widths the layout decides on — two lines, a collapsed row, and
the single truncated line — from the same photo.
"""
from immich_stub_base import Response, STATE, TIMELINE_ASSETS, bucket_payload, main, router

DEFAULT_PLACE = "Ogre"
# The date the badge shows: `fileCreatedAt` on every asset → "2 mai 2025" in fr.
TAKEN_ON = "2025-05-02"


@router.get("/api/timeline/bucket")
def timeline_bucket(req):
    """Every asset carries the armed place; the country stays empty so the
    badge reads the city alone (`placeName` falls back to country only)."""
    payload = bucket_payload(TIMELINE_ASSETS, day=TAKEN_ON)
    payload["city"] = [STATE.get("place", DEFAULT_PLACE)] * len(TIMELINE_ASSETS)
    return Response(payload)


@router.post("/control/place")
def arm_place(req):
    """Arm the place the next launch shows: `{"place": "…"}`."""
    STATE["place"] = req.body.get("place") or DEFAULT_PLACE
    return Response({"armed": True, "place": STATE["place"]})


@router.reset
def fresh():
    """`/__reset`: back to the default place, so a run never inherits another's."""
    STATE["place"] = DEFAULT_PLACE


if __name__ == "__main__":
    main(label="viewer-top-bar")
