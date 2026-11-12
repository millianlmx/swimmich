"""Immich API stub for the list-state scenarios (`ListStatesUITests`, lot L-16).

    python3 UITests/stubs/immich_stub_list_states.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/list-states.uitest.log \\
        UITests/stubs/immich_stub_list_states.py ListStatesUITests --erase

Built on `immich_stub_base` (OAuth shell, request journal `/__requests`, asset
thumbnails and originals). What it adds is ONE scripted sequence per screen:
the server answers 500, then an empty list, then data, in that order, which is
what AC-31 asks the app to render as "error with Try Again", "empty state with a
title and an explanation", then "the data".

THE SCRIPT
    `GET /control/script?route=<route>&steps=500,empty,ok&delay=<seconds>` arms the
    queue of one route. The route is NOT under `/__` (the shell answers every
    `/__*` itself, before the router) and NOT under `/api/` (the shell's
    fallbacks would swallow it). A step is consumed by one TARGETED request, and
    only by it (a request that is not targeted is answered normally and leaves
    the queue alone): `500` answers 500, `empty` answers an empty list (or zero
    counts), `ok` answers data. Each step waits `delay` seconds first, so the
    loading indicator is on screen long enough to be asserted. An empty queue
    answers `ok` with no delay. `/__reset` empties every queue.

THE TARGETED REQUESTS (decision #16: one request per read, never two)
    `partners`          `GET /api/partners?direction=shared-with`. The
                        `direction=shared-by` read always answers `[]`, so a read
                        of the Partners screen (two GETs) consumes exactly one
                        step: a 500 makes the read fail, an empty `shared-with`
                        is an empty screen, and the data is one partner.
    `search`            `POST /api/search/smart` and `POST /api/search/metadata`
                        whose body carries the text `liststates`. Any other
                        search is answered normally.
    `apiKeys`           `GET /api/api-keys` (not `/api/api-keys/me`).
    `assetStatistics`   `GET /api/assets/statistics`. The Me hub reads it in its
                        `.task`, so the scenario arms this queue only after that
                        read ended, just before opening Media Stats.

THE DATA
    `ok` gives one partner who shares with me ("Incoming Ivan"), three search
    results (the base timeline photos), one API key and non-zero counts.
    `empty` gives `[]` for the lists and 0 photos / 0 videos for the counts.
"""
import time

from immich_stub_base import STATE, TIMELINE_ASSETS, Response, asset, main, router

INCOMING = "aaaaaaaa-1111-4111-8111-111111111111"
KEY_ID = "44444444-4444-4444-8444-000000000001"
MY_KEY_ID = "44444444-4444-4444-8444-000000000002"
STAMP = "2026-09-01T10:00:00.000Z"

# The text the scenario types in the search field; the only search the script
# targets.
SEARCH_TEXT = "liststates"

ROUTES = ("partners", "search", "apiKeys", "assetStatistics")


@router.reset
def fresh():
    STATE["scripts"] = {route: {"steps": [], "delay": 0.0} for route in ROUTES}


fresh()  # a request before the first `/__reset` must not find an empty STATE


def step_for(route):
    """The next scripted step of `route` (after its delay), `ok` when none."""
    script = STATE["scripts"][route]
    if not script["steps"]:
        return "ok"
    step = script["steps"].pop(0)
    if script["delay"]:
        time.sleep(script["delay"])
    return step


def failure():
    return Response({"message": "stub failure", "error": "Internal Server Error", "statusCode": 500},
                    status=500)


def user(uid, name, email):
    return {
        "id": uid, "name": name, "email": email, "profileImagePath": "",
        "avatarColor": "primary", "profileChangedAt": "2026-01-01T00:00:00.000Z",
    }


# MARK: - Partners


@router.get("/api/partners")
def list_partners(req):
    direction = req.params.get("direction")
    req.note(direction=direction)
    if direction == "shared-by":
        return Response([])
    if direction != "shared-with":
        return Response({"error": "Bad Request", "message": ["direction must be one of: shared-by, shared-with"]},
                        status=400)
    step = step_for("partners")
    if step == "500":
        return failure()
    if step == "empty":
        return Response([])
    return Response([{**user(INCOMING, "Incoming Ivan", "ivan@example.com"), "inTimeline": True}])


# MARK: - Search


def _is_scripted_search(req):
    return SEARCH_TEXT in str(req.body or "")


def _search(req):
    if not _is_scripted_search(req):
        return None
    step = step_for("search")
    if step == "500":
        return failure()
    items = [] if step == "empty" else [asset(aid) for aid in TIMELINE_ASSETS[:3]]
    return Response({"assets": {"count": len(items), "items": items, "nextPage": None, "nextCursor": None}})


@router.post("/api/search/smart")
def search_smart(req):
    return _search(req)


@router.post("/api/search/metadata")
def search_metadata(req):
    return _search(req)


# MARK: - API keys


def _key(kid, name):
    return {"id": kid, "name": name, "createdAt": STAMP, "updatedAt": STAMP, "permissions": ["all"]}


@router.get("/api/api-keys")
def list_keys(req):
    step = step_for("apiKeys")
    if step == "500":
        return failure()
    if step == "empty":
        return Response([])
    return Response([_key(KEY_ID, "stub-laptop")])


@router.get("/api/api-keys/me")
def my_key(req):
    return Response(_key(MY_KEY_ID, "stub-phone-session"))


# MARK: - Media Stats counts


@router.get("/api/assets/statistics")
def asset_statistics(req):
    step = step_for("assetStatistics")
    if step == "500":
        return failure()
    if step == "empty":
        return Response({"images": 0, "videos": 0, "total": 0})
    return Response({"images": 4242, "videos": 7317, "total": 11559})


# MARK: - Control route


@router.get("/control/script")
def arm_script(req):
    route = req.params.get("route")
    if route not in ROUTES:
        return Response({"message": f"route must be one of {', '.join(ROUTES)}"}, status=400)
    steps = [s for s in (req.params.get("steps") or "").split(",") if s]
    if any(s not in ("500", "empty", "ok") for s in steps):
        return Response({"message": "steps are 500, empty or ok"}, status=400)
    STATE["scripts"][route] = {"steps": steps, "delay": float(req.params.get("delay") or 0)}
    return Response({"route": route, "steps": steps, "delay": STATE["scripts"][route]["delay"]})


if __name__ == "__main__":
    main(label="list-states")
