"""Immich API stub for the "app utilities" scenario (`AppUtilitiesUITests`).

Thin on purpose: everything the app needs to boot, sign in and draw a grid comes
from `immich_stub_base` (the OAuth handshake, the server config, `/api/users/me`,
a day of timeline, real PNG thumbnails). This file adds the one route the
instruments under test read, and the two controls the scenario needs to make the
log prove something:

    python3 UITests/stubs/immich_stub_app_utilities.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/app-utilities.uitest.log \\
        UITests/stubs/immich_stub_app_utilities.py AppUtilitiesUITests/test_appUtilities

THREE ADDITIONS, EACH CARRYING ONE ASSERTION

* `POST /api/oauth/callback` hands the app a RECOGNISABLE access token. The
  scenario scans every line the log screen and its export render for that
  literal. The credential really is in flight — the app presents it as
  `Authorization: Bearer …`, and the boolean `bearerMatches` below is that proof
  noted on the wire, never the token itself, so the stub keeps no copy either.
  A diagnostic surface that showed it would be the leak the card's AC-5248
  forbids.
* `GET /api/assets/statistics` answers the account's counters, which exist nowhere
  else (4242 photos, 7317 videos): a Media Stats screen showing them read the
  wire rather than printing a plausible constant. (`/api/server/statistics`, the
  instance totals, belongs to the Administration screen and is not served here.)
* `GET /control/statistics?fail=1|0` arms a 500 on the route above, and that is
  the only way to get a second LEVEL into the log without inventing one: the
  transport maps a 5xx to `severe` (`entry(for:)`), so the level filter's
  assertion has a line that only that outcome can produce.

The control route is NOT under `/__`: the shell answers every `/__…` path itself
before the feature router is consulted (`StubHandler._dispatch`), so a feature
cannot register a control route there. It is logged like any other request and
lives outside `/api/`, where the shell's fallbacks cannot swallow it.
"""
from immich_stub_base import LOGIN, Response, STATE, main, router

# The credential the app is handed at the end of the handshake, recognisable on
# purpose. `AppUtilitiesUITests.token` is the other half of this contract:
# change both together.
TOKEN = "stub-apputilities-token-8f31c2d9"

# Armed by `/control/statistics?fail=1`, disarmed by `?fail=0`.
FAILING = "statistics_failing"

# Seeded at IMPORT, not only by the reset hook below: a scenario calls
# `/__reset` first, but the stub must also answer before anyone does — a run that
# skipped it raised `KeyError` here and closed the connection under a by-hand
# smoke pass.
STATE.setdefault(FAILING, False)

# Distinctive by construction: 4242 and 7317 come from this file and from
# nowhere else, so a screen showing them is a screen that read the wire.
# `total` exceeds the sum (audio and other media): it is never what is shown.
ASSET_STATS = {"images": 4242, "videos": 7317, "total": 11559}


@router.reset
def fresh():
    """Per-run state: a scenario must never inherit a previous run's 500."""
    STATE[FAILING] = False


@router.post("/api/oauth/callback")
def sign_in(req):
    """The shell's answer, with a token the scenario can look for."""
    return Response({**LOGIN, "accessToken": TOKEN})


@router.get("/control/statistics")
def control_statistics(req):
    """Arms (`fail=1`) or disarms (`fail=0`) the 500 on the statistics route."""
    STATE[FAILING] = req.params.get("fail") == "1"
    return Response({"statistics_failing": STATE[FAILING]})


@router.get("/api/assets/statistics")
def statistics(req):
    """The account's counters — or the failure that gives the log its second level."""
    if STATE[FAILING]:
        return Response(
            {"error": "Internal Server Error", "message": "stub: statistics are down"},
            status=500)
    req.note(bearerMatches=req.headers.get("Authorization") == f"Bearer {TOKEN}")
    return Response(ASSET_STATS)


if __name__ == "__main__":
    main(label="app-utilities")
