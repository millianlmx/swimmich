"""Immich API stub for the "account storage" scenario (`AccountStorageUITests`).

Thin on purpose: everything the app needs to boot, sign in and draw a grid comes
from `immich_stub_base`. This file adds what the three storage screens (Me hub,
Media Stats, "On this device") and the Administration screen read, shaped like
the real server so a screen reading the wrong route shows it:

    python3 UITests/stubs/immich_stub_account_storage.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/account-storage.uitest.log \\
        UITests/stubs/immich_stub_account_storage.py AccountStorageUITests

WHAT EACH ROUTE PROVES

* `GET /api/users/me` carries the account's usage and quota (the control route
  sets them); a `null` quota is the "unlimited" account.
* `GET /api/assets/statistics` answers the account's own counts, with a `total`
  that exceeds `images + videos` (audio and other media): a screen showing it
  gives itself away.
* `GET /api/server/statistics` answers the INSTANCE totals (900 photos, 90
  videos, another user owning 772 + 83) and a 403 to a non-admin, like the real
  server (`server.statistics` permission). A screen of the account reading it
  would show 900, or an error.
* `POST /api/search/statistics` counts partners too (a partner is served with
  `inTimeline: true`) and must never be called: it answers 9999.
* `GET /api/admin/users`, `/api/jobs` and `/api/libraries` never depend on a
  failure flag: they show that a failing instance-statistics read leaves the
  other Administration sections alone.

Controls (GET, outside `/__` and `/api/` — the shell answers `/__…` itself and
falls back on `/api/…`; they are logged like any request):

    /control/account?admin=0|1&quota=<int>|null&usage=<int>
    /control/counts?images=<int>&videos=<int>
    /control/fail?me=0|1&counts=0|1&instance=0|1    (absent = unchanged)
    /control/version?v=2.0.0|3.4.0

Sign-in: `POST /api/oauth/callback` answers `isAdmin` from the `admin` control.
"""
from immich_stub_base import LOGIN, ME, ME_USER, Response, STATE, main, router

DEFAULTS = {
    "admin": False,
    "quota": 107374182400,
    "usage": 21474836480,
    "images": 128,
    "videos": 7,
    "fail_me": False,
    "fail_counts": False,
    "fail_instance": False,
    "version": "3.4.0",
}

OTHER_USER = {
    "id": "other-user", "name": "Other User", "email": "other@example.com",
    "profileImagePath": "", "avatarColor": "primary",
    "profileChangedAt": "2026-01-01T00:00:00.000Z",
    "isAdmin": False, "shouldChangePassword": False,
    "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
    "deletedAt": None, "status": "active",
    "quotaSizeInBytes": None, "quotaUsageInBytes": 0,
    "storageLabel": None, "oauthId": "",
}

# Seeded at IMPORT and by the reset hook: a scenario calls `/__reset` first, but
# the stub must also answer before anyone does.
STATE.update({k: v for k, v in DEFAULTS.items() if k not in STATE})


@router.reset
def fresh():
    """Per-run state: a scenario must never inherit a previous run's account."""
    STATE.update(DEFAULTS)


def _snapshot():
    return {k: STATE[k] for k in DEFAULTS}


def _flag(value):
    return value == "1"


@router.get("/control/account")
def control_account(req):
    if "admin" in req.params:
        STATE["admin"] = _flag(req.params["admin"])
    if "quota" in req.params:
        STATE["quota"] = None if req.params["quota"] == "null" else int(req.params["quota"])
    if "usage" in req.params:
        STATE["usage"] = int(req.params["usage"])
    return Response(_snapshot())


@router.get("/control/counts")
def control_counts(req):
    if "images" in req.params:
        STATE["images"] = int(req.params["images"])
    if "videos" in req.params:
        STATE["videos"] = int(req.params["videos"])
    return Response(_snapshot())


@router.get("/control/fail")
def control_fail(req):
    for param, key in (("me", "fail_me"), ("counts", "fail_counts"), ("instance", "fail_instance")):
        if param in req.params:
            STATE[key] = _flag(req.params[param])
    return Response(_snapshot())


@router.get("/control/version")
def control_version(req):
    STATE["version"] = req.params.get("v", STATE["version"])
    return Response(_snapshot())


def _down(what):
    return Response({"error": "Internal Server Error", "message": f"stub: {what} is down"}, status=500)


@router.post("/api/oauth/callback")
def sign_in(req):
    return Response({**LOGIN, "isAdmin": STATE["admin"]})


@router.get("/api/users/me")
def me(req):
    if STATE["fail_me"]:
        return _down("users/me")
    return Response(dict(ME_USER, isAdmin=STATE["admin"],
                         quotaSizeInBytes=STATE["quota"], quotaUsageInBytes=STATE["usage"]))


@router.get("/api/assets/statistics")
def asset_statistics(req):
    if STATE["fail_counts"]:
        return _down("assets/statistics")
    images, videos = STATE["images"], STATE["videos"]
    return Response({"images": images, "videos": videos, "total": images + videos + 2})


@router.get("/api/server/statistics")
def server_statistics(req):
    if not STATE["admin"]:
        return Response({"message": "Missing required permission: server.statistics",
                         "error": "Forbidden", "statusCode": 403}, status=403)
    if STATE["fail_instance"]:
        return _down("server/statistics")
    return Response({
        "photos": 900, "videos": 90,
        "usage": 999000000000, "usagePhotos": 800000000000, "usageVideos": 199000000000,
        "usageByUser": [
            {"userId": ME, "userName": ME_USER["name"], "photos": 128, "videos": 7,
             "usage": 21474836480, "usagePhotos": 20000000000, "usageVideos": 1474836480,
             "quotaSizeInBytes": STATE["quota"]},
            {"userId": OTHER_USER["id"], "userName": OTHER_USER["name"], "photos": 772, "videos": 83,
             "usage": 977525163520, "usagePhotos": 780000000000, "usageVideos": 197525163520,
             "quotaSizeInBytes": None},
        ],
    })


@router.get("/api/server/version")
def server_version(req):
    major, minor, patch = (int(part) for part in STATE["version"].split("."))
    return Response({"major": major, "minor": minor, "patch": patch, "prerelease": None})


@router.get("/api/partners")
def partners(req):
    return Response([{
        "id": "partner-1", "name": "Partner User", "email": "partner@example.com",
        "profileImagePath": "", "avatarColor": "primary",
        "profileChangedAt": "2026-01-01T00:00:00.000Z", "inTimeline": True,
    }])


@router.post("/api/search/statistics")
def search_statistics(req):
    """Counts the partners' photos too. The app must never call it."""
    return Response({"total": 9999})


@router.get("/api/admin/users")
def admin_users(req):
    return Response([dict(ME_USER, isAdmin=True), OTHER_USER])


@router.get("/api/jobs")
def jobs(req):
    return Response({"thumbnailGeneration": {
        "queueStatus": {"isActive": False, "isPaused": False},
        "jobCounts": {"active": 0, "completed": 12, "failed": 0,
                      "delayed": 0, "waiting": 3, "paused": 0},
    }})


@router.get("/api/libraries")
def libraries(req):
    return Response([{"id": "lib-1", "ownerId": ME, "name": "Stub Library", "assetCount": 42}])


if __name__ == "__main__":
    main(label="account-storage")
