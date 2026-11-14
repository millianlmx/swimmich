"""Immich API stub for the confirmations scenario (`ConfirmationsUITests`, lot L-31).

Everything the app needs to boot, sign in and draw the ordinary timeline comes
from `immich_stub_base`. This file adds what the lot's confirmations, haptic
probes and backup passes reach, and nothing else:

    python3 UITests/stubs/immich_stub_confirmations.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/confirmations.uitest.log \\
        UITests/stubs/immich_stub_confirmations.py ConfirmationsUITests/<test> [--media <file>] --erase

THE TIMELINE has ONE photo, `PHOTO` (the viewer's delete test opens it), and the
locked folder's (`visibility=locked`) is empty.

SHARED LINKS — `GET /api/shared-links` serves two links: `LINK_PHOTOS` (an
individual-photos link) and `LINK_ALBUM` (the link of `ALBUM`). With `albumId=`
(the album's "Shared Links" sheet) only the album's link is served.
`DELETE /api/shared-links/{id}` answers 204 and removes the link.

ALBUMS — `GET /api/albums` serves one album ME owns (and none for
`shared=true`, so the Albums tab draws it once); `GET /api/albums/{id}` serves
it; `POST /api/search/metadata` serves its one photo.

PARTNERS — `GET /api/partners?direction=shared-by` serves one partner
(`PARTNER`), `shared-with` none. `DELETE /api/partners/{id}` answers 204.

PIN — `GET /api/auth/status` (`pinCode: true`, `isElevated` follows the state),
`POST /api/auth/session/unlock` (`pinCode == PIN` -> 204 and the session is
elevated; anything else -> 400 `{"message": "Wrong PIN code"}`),
`POST /api/auth/session/lock` (204, drops the elevation), `GET /api/sessions`
(two sessions).

VIEWER — `DELETE /api/assets` (the trash and the permanent delete alike) answers
204. Like every request it is journaled, so a scenario asserts that a cancelled
alert sent no `DELETE /api/assets`.

BACKUP — `POST /api/assets/bulk-upload-check` accepts everything;
`POST /api/assets` answers 201 `{"id": <a fresh uuid per call>, "status":
"created"}` (a fresh id per call: the ledger records one entry per upload) after
`UPLOAD_DELAY` seconds, 0 by default.

CONTROL ROUTES — under `/api/`, NOT under `/__`: the base answers every `/__*`
path itself and never consults the router (a control route there would be a 404).
POST, logged like any other request:

    POST /api/__confirmations/fail?route=<revoke|albumRevoke|partner>&status=<code>
        Arms ONE error answer (default status 500) for the next request of the
        route. `revoke` and `albumRevoke` are the same request on the wire
        (`DELETE /api/shared-links/{id}` — the Shared tab and the album's sheet
        send it alike), so they arm the same slot; `partner` arms
        `DELETE /api/partners/{id}`. The armed answer is spent by that request.
    POST /api/__confirmations/upload-delay?seconds=<n>
        Delays every `POST /api/assets` answer by n seconds (a pass that lasts).

`/__reset` puts everything back (links, partner, PIN state, sessions, armed
failures, upload delay); the state is also initialised once at import, for a stub
run by hand that never receives a `/__reset`.
"""
import time
import uuid

from immich_stub_base import (
    ME, ME_USER, TIMELINE_ASSETS, TIMELINE_DAY, Response, asset, bucket_payload, main, router,
)

PHOTO = TIMELINE_ASSETS[0]
ALBUM = "22222222-2222-4222-8222-000000000002"
LINK_PHOTOS = "99999999-9999-4999-8999-000000000001"
LINK_ALBUM = "99999999-9999-4999-8999-000000000002"
LINK_KEY = "c3R1Yi1rZXk"  # base64url of "stub-key"
PARTNER = "bbbbbbbb-2222-4222-8222-000000000002"
PIN = "123456"
SELF_SESSION = "dddddddd-1111-4111-8111-000000000001"
OTHER_SESSION = "dddddddd-1111-4111-8111-000000000002"

NO_CONTENT = Response(b"", status=204)
FAIL_ROUTES = {"revoke": "shared-link", "albumRevoke": "shared-link", "partner": "partner"}

S = {}


def album_dto():
    return {
        "id": ALBUM, "albumName": "Confirmation Album", "description": "",
        "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
        "albumThumbnailAssetId": PHOTO, "shared": True, "hasSharedLink": True,
        "assetCount": 1, "isActivityEnabled": True, "order": "desc",
        "albumUsers": [], "ownerId": ME, "owner": ME_USER,
    }


def link_dto(link_id, link_type, album):
    return {
        "id": link_id, "description": None, "password": None,
        "userId": ME, "key": LINK_KEY, "type": link_type,
        "createdAt": "2026-01-01T00:00:00.000Z", "expiresAt": None,
        "assets": [], "album": album,
        "allowUpload": False, "allowDownload": True, "showMetadata": True,
        "slug": None,
    }


def partner_dto():
    return {
        "id": PARTNER, "name": "Outgoing Olive", "email": "olive@example.com",
        "profileImagePath": "", "avatarColor": "primary",
        "profileChangedAt": "2026-01-01T00:00:00.000Z", "inTimeline": False,
    }


def session(sid, current, updated):
    return {
        "id": sid, "createdAt": "2026-09-01T08:00:00.000Z", "updatedAt": updated,
        "expiresAt": None, "current": current, "deviceType": "iPhone", "deviceOS": "iOS",
        "appVersion": "2.1.0", "isPendingSyncReset": False,
    }


@router.reset
def fresh():
    S["links"] = [link_dto(LINK_PHOTOS, "INDIVIDUAL", None), link_dto(LINK_ALBUM, "ALBUM", album_dto())]
    S["partners"] = [partner_dto()]
    S["elevated"] = False
    S["sessions"] = [session(SELF_SESSION, True, "2026-09-15T09:00:00.000Z"),
                     session(OTHER_SESSION, False, "2026-09-14T18:30:00.000Z")]
    S["fail"] = {}
    S["upload_delay"] = 0.0


fresh()


def armed_failure(kind):
    """The error `Response` armed for `kind`, spent by this call, else `None`."""
    status = S["fail"].pop(kind, None)
    if status is None:
        return None
    return Response({"message": "Stubbed failure", "error": "Error", "statusCode": status},
                    status=status)


# MARK: - Control routes


@router.post("/api/__confirmations/fail")
def arm_failure(req):
    route = req.params.get("route")
    if route not in FAIL_ROUTES:
        return Response({"message": f"route must be one of {sorted(FAIL_ROUTES)}"}, status=400)
    status = int(req.params.get("status") or 500)
    S["fail"][FAIL_ROUTES[route]] = status
    return Response({"route": route, "status": status})


@router.post("/api/__confirmations/upload-delay")
def set_upload_delay(req):
    S["upload_delay"] = float(req.params.get("seconds") or 0)
    return Response({"seconds": S["upload_delay"]})


# MARK: - Timeline


@router.get("/api/timeline/buckets")
def buckets(req):
    if req.params.get("visibility") == "locked":
        return Response([])
    return Response([{"timeBucket": TIMELINE_DAY, "count": 1}])


@router.get("/api/timeline/bucket")
def bucket(req):
    if req.params.get("visibility") == "locked":
        payload = bucket_payload([])
        payload["visibility"] = []
        return Response(payload)
    return Response(bucket_payload([PHOTO]))


# MARK: - Shared links


@router.get("/api/shared-links")
def list_links(req):
    album_id = req.params.get("albumId")
    req.note(albumId=album_id)
    if album_id:
        return Response([link for link in S["links"]
                         if link["album"] and link["album"]["id"] == album_id])
    return Response(S["links"])


@router.prefix("DELETE", "/api/shared-links/")
def delete_link(req):
    link_id = req.rest.split("/")[0]
    req.note(linkId=link_id)
    failure = armed_failure("shared-link")
    if failure is not None:
        return failure
    before = len(S["links"])
    S["links"] = [link for link in S["links"] if link["id"] != link_id]
    if len(S["links"]) == before:
        return Response({"error": "Not Found", "message": "Shared link not found", "statusCode": 404},
                        status=404)
    return NO_CONTENT


# MARK: - Albums


@router.get("/api/albums")
def list_albums(req):
    # `shared=true` is the Albums tab's second read: nothing is shared WITH me.
    return Response([] if req.params.get("shared") == "true" else [album_dto()])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if req.rest != ALBUM:
        return None  # a sub-resource, or an unknown id: the shell's own answer
    return Response(album_dto())


@router.post("/api/search/metadata")
def album_photos(req):
    ids = req.body.get("albumIds") or []
    items = [asset(PHOTO)] if ids and ids[0] == ALBUM else []
    return Response({"assets": {"count": len(items), "items": items,
                                "nextPage": None, "nextCursor": None}})


# MARK: - Partners


@router.get("/api/partners")
def list_partners(req):
    direction = req.params.get("direction")
    req.note(direction=direction)
    if direction == "shared-by":
        return Response(S["partners"])
    if direction == "shared-with":
        return Response([])
    return Response({"error": "Bad Request",
                     "message": ["direction must be one of: shared-by, shared-with"]}, status=400)


@router.prefix("DELETE", "/api/partners/")
def delete_partner(req):
    partner_id = req.rest.split("/")[0]
    req.note(partnerId=partner_id)
    failure = armed_failure("partner")
    if failure is not None:
        return failure
    before = len(S["partners"])
    S["partners"] = [p for p in S["partners"] if p["id"] != partner_id]
    if len(S["partners"]) == before:
        return Response({"error": "Bad Request", "message": "Partner not found"}, status=400)
    return NO_CONTENT


# MARK: - PIN and sessions


@router.get("/api/auth/status")
def auth_status(req):
    return Response({
        "expiresAt": None,
        "isElevated": S["elevated"],
        "password": True,
        "pinCode": True,
        "pinExpiresAt": None,
    })


@router.post("/api/auth/session/unlock")
def unlock_session(req):
    submitted = req.body.get("pinCode")
    req.note(submittedPIN=submitted)
    if submitted != PIN:
        return Response({"message": "Wrong PIN code", "error": "Bad Request", "statusCode": 400},
                        status=400)
    S["elevated"] = True
    return NO_CONTENT


@router.post("/api/auth/session/lock")
def lock_session(req):
    S["elevated"] = False
    return NO_CONTENT


@router.get("/api/sessions")
def list_sessions(req):
    return Response(S["sessions"])


# MARK: - Viewer


@router.delete("/api/assets")
def delete_assets(req):
    """The viewer's delete (trash, or permanent with `force`). Journaled."""
    req.note(ids=req.body.get("ids"), force=req.body.get("force"))
    return NO_CONTENT


# MARK: - Backup


@router.post("/api/assets/bulk-upload-check")
def bulk_upload_check(req):
    items = req.body.get("assets") or []
    req.note(ids=[item.get("id") for item in items])
    return Response({"results": [{"id": item["id"], "action": "accept"} for item in items]})


@router.post("/api/assets")
def upload(req):
    """The upload (multipart), answered with the `AssetMediaResponseDto` the client
    decodes, after the armed delay. A fresh id per call, so the ledger records one
    entry per upload."""
    req.note(uploaded=True)
    if S["upload_delay"] > 0:
        time.sleep(S["upload_delay"])
    return Response({"id": str(uuid.uuid4()), "status": "created"}, status=201)


if __name__ == "__main__":
    main(label="confirmations")
