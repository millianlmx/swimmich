"""Immich API stub for the star-rating scenario (`StarRatingsUITests`).

Thin on purpose: everything the app needs to boot, sign in, draw the timeline
and open a photo comes from `immich_stub_base` (the OAuth handshake, the server
config, `/api/users/me`, one day of timeline, real PNG thumbnails, the asset
DTO the info panel reads). This file adds the ONE route the feature owns — the
rating write — plus the one control route that makes the write's ANSWER
observable:

    python3 UITests/stubs/immich_stub_star_ratings.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/star-ratings.uitest.log \\
        UITests/stubs/immich_stub_star_ratings.py StarRatingsUITests/test_starRatings

WHAT THE WIRE HAS TO SHOW, AND WHY EACH PART IS HERE
    `PUT /api/assets/:id` is the whole feature. Three things are asserted on
    its body and on its answer, and each one needs this stub to be able to fail:

    1. `rating` is the only field written. The DTO the panel sends is
       `UpdateAssetDto`-shaped to a naive reader (`isFavorite`/`visibility`/…),
       and an update DTO reused for the rating would still carry `rating`.

    2. CLEARING sends `{"rating": null}` — the key PRESENT with a null value,
       never an omitted one. The server has no `0` (invalid since v3), so an
       omitted key reads as "no change" and the star would stay on the server
       while the bar reads empty: a silent desync. The two bodies are
       indistinguishable after decoding (`{}` and `{"rating": null}` both give
       `body.get("rating") is None`), so the KEY's presence is recorded
       separately by `req.note` — `/__requests` is where the scenario reads it.

    3. The panel shows what the SERVER answered, not what was tapped. A stub
       that echoed every write could not tell `rating = response.exifInfo?.rating`
       from `rating = sent`; `POST /control/rating-response` arms the next
       answer, the scenario taps 4 and requires the panel to read 3.
"""
from immich_stub_base import Response, STATE, asset, main, router

# The photo the scenario rates: the shell's first timeline asset, so the walk
# (onboarding → SSO → Photos) stays the shared one.
RATED = "aaaaaaaa-1111-4111-8111-000000000001"


def answered_asset(aid, rating):
    """The asset DTO a rating write answers with.

    The full `AssetResponseDto`, not a patch: the app adopts this body as its
    new detail (that is how the panel refreshes without a second `getAsset`),
    so a body missing the ordinary fields would fail to decode and the write
    would be reported as an error the server never raised.
    """
    dto = asset(aid)
    dto["exifInfo"]["rating"] = rating
    return dto


@router.prefix("PUT", "/api/assets/")
def write_rating(req):
    """`PUT /api/assets/:id` — the only mutation this feature makes."""
    aid = req.rest
    if "/" in aid:
        # A sub-resource of an asset (`/thumbnail`, `/original`): not ours.
        return None
    sent = req.body.get("rating")
    req.note(ratingKeyPresent="rating" in req.body, ratingSent=sent)
    if STATE["armed"]:
        # One-shot: the answer the scenario asked for, consumed by the write it
        # was armed for, so the clear that follows is answered like any other.
        STATE["armed"] = False
        answered = STATE["armedRating"]
    else:
        answered = sent
    return Response(answered_asset(aid, answered))


@router.post("/control/rating-response")
def arm_answer(req):
    """Arm the NEXT rating write to be answered with `{"rating": <value>}`.

    `req.body` is `{"rating": 3}`; the value may be `null` (the server answering
    "unrated" to a starred write).
    """
    STATE["armed"] = True
    STATE["armedRating"] = req.body.get("rating")
    return Response({"armed": True, "rating": STATE["armedRating"]})


@router.reset
def fresh():
    """`/__reset`: no armed answer, so a run never inherits the previous one's."""
    STATE["armed"] = False
    STATE["armedRating"] = None


if __name__ == "__main__":
    main(label="star-ratings")
