"""Immich API stub for the "routes by server version" scenarios (`RouteCompatUITests`, lot L-20).

Thin on purpose: booting, signing in and the version filter come from
`immich_stub_base`. That shell announces `IMMICH_STUB_VERSION` and answers 404
`Cannot <METHOD> <path>` (journaled) to a replacement route its version does not
have (`ROUTE_TABLE`: `/api/queues*` from 2.4.0, `/api/public/config` and
`/api/config` from 3.2.0, `POST /api/people/merge` from 3.2.1), so a scenario
proves "never a route this server does not serve" by reading `/__requests`.

THE VERSION. A scenario picks it at run time, without restarting the stub:

    GET /stub/version?v=X.Y.Z                 every request announces X.Y.Z
    GET /stub/version?v=X.Y.Z&host=localhost  only the requests whose `Host` header is
                                              that host (the port is ignored)
    GET /stub/version?v=broken                `GET /api/server/version` answers 500
    GET /stub/version?v=garbage               ... answers 200 with a body that is not a version

The route is journaled (the scenario can read back what it set). `/__reset` goes
back to `SERVER_VERSION` (`IMMICH_STUB_VERSION`, 1.119.0 by default) for every host.

WHAT IT SERVES
    * An ADMINISTRATOR signs in by SSO (`/api/oauth/callback`, `/api/users/me`).
    * The server configuration carries an external domain
      (`https://photos.public.example`), which a shared link's public URL uses.
    * Three people, Ada, Ben and Cleo, with their paged list, their counts and a
      faces grid. Both merge routes remove the sources from the list and note
      `target` and `sources` in the journal entry:
        POST /api/people/{id}/merge   (prefix)  target = {id}, sources = body `ids`
        POST /api/people/merge        (exact)   target = ids[0], sources = ids[1:]
    * One shared link, so a public URL can be read.
    * The jobs and queues, the three configs and the version come from the shell,
      with the effects of the upstream server (`pause`, `empty`, `clear-failed` ...).

    python3 -u UITests/stubs/immich_stub_route_compat.py 8421
"""
import immich_stub_base as base
from immich_stub_base import (CONFIG, LOGIN, ME, ME_USER, STATE, TIMELINE_ASSETS, Response,
                              asset, main, png, router)

EXTERNAL_DOMAIN = "https://photos.public.example"
# Set on the shell's own dict, in place: the shell serves `CONFIG` for both the
# legacy `/api/server/config` and the 3.2+ `/api/public/config` and `/api/config`.
CONFIG["externalDomain"] = EXTERNAL_DOMAIN

# Keep these in step with `RouteCompatUITests` (it recopies the ids).
ADA = "cccccccc-4444-4444-8444-000000000001"
BEN = "cccccccc-4444-4444-8444-000000000002"
CLEO = "cccccccc-4444-4444-8444-000000000003"
NAMES = {ADA: "Ada", BEN: "Ben", CLEO: "Cleo"}
COUNTS = {ADA: 5, BEN: 3, CLEO: 7}

LINK_KEY = "c3R1Yi1rZXk"  # base64url of "stub-key"


def person(pid):
    """One `PersonResponseDto` — every non-optional field the app decodes."""
    return {
        "id": pid, "name": NAMES[pid], "birthDate": None, "thumbnailPath": "",
        "isHidden": False, "color": "#4a5aef", "isFavorite": False,
        "updatedAt": "2026-09-01T10:00:00.000Z",
    }


def seed():
    """(Re)install the state — at import and on every `/__reset`."""
    STATE["compat"] = {"all": None, "hosts": {}, "people": [ADA, BEN, CLEO]}


router.reset(seed)
seed()


# MARK: - The announced version


def _host(req):
    return (req.headers.get("Host") or "").split(":")[0]


def _announced(req):
    """What this request's host is told: "X.Y.Z", "broken", "garbage" or None (the shell's own)."""
    compat = STATE["compat"]
    return compat["hosts"].get(_host(req), compat["all"])


@router.get("/api/server/version")
def server_version(req):
    value = _announced(req)
    if value == "broken":
        return Response({"message": "stub: the version route is down", "statusCode": 500}, status=500)
    if value == "garbage":
        return Response([])
    parsed = base.parse_version(value) if value else None
    if parsed is None:
        return Response(base.version_payload())
    major, minor, patch = parsed
    return Response({"major": major, "minor": minor, "patch": patch, "prerelease": None})


@router.get("/stub/people")
def restore_people(req):
    """Brings Ada, Ben and Cleo back (a scenario merges them more than once)."""
    STATE["compat"]["people"] = [ADA, BEN, CLEO]
    return Response({"people": STATE["compat"]["people"]})


@router.get("/stub/version")
def set_version(req):
    value = req.params.get("v", "")
    if value not in ("broken", "garbage") and base.parse_version(value) is None:
        return Response({"message": "v must be X.Y.Z, broken or garbage"}, status=400)
    host = req.params.get("host")
    if host:
        STATE["compat"]["hosts"][host] = value
    else:
        STATE["compat"]["all"] = value
    return Response({"v": value, "host": host})


# MARK: - An administrator


@router.post("/api/oauth/callback")
def sign_in(req):
    return Response({**LOGIN, "isAdmin": True})


@router.get("/api/users/me")
def me(req):
    return Response(dict(ME_USER, isAdmin=True))


@router.get("/api/admin/users")
def admin_users(req):
    return Response([dict(ME_USER, isAdmin=True)])


# MARK: - People


def _listed():
    return [person(pid) for pid in STATE["compat"]["people"]]


@router.get("/api/people")
def people(req):
    listed = _listed()
    return Response({"people": listed, "hidden": 0, "total": len(listed), "hasNextPage": False})


@router.prefix("GET", "/api/people/")
def one_person(req):
    pid, _, tail = req.rest.partition("/")
    if pid not in NAMES:
        return None
    if tail == "statistics":
        return Response({"assets": COUNTS[pid]})
    if tail == "thumbnail":
        return Response(png(pid), ctype="image/png", headers={"Cache-Control": "no-store"})
    return None


@router.post("/api/search/metadata")
def person_faces(req):
    """The faces grid of a person: the shell's own timeline assets, so their
    thumbnails resolve through `/api/assets/{id}/thumbnail`."""
    items = [asset(aid) for aid in TIMELINE_ASSETS[:3]]
    return Response({"assets": {"count": len(items), "items": items, "nextPage": None}})


def _merge(req, target, sources):
    req.note(target=target, sources=sources)
    STATE["compat"]["people"] = [pid for pid in STATE["compat"]["people"] if pid not in sources]
    return Response([{"id": source, "success": True} for source in sources])


@router.post("/api/people/merge")
def merge(req):
    ids = req.body.get("ids") or []
    return _merge(req, ids[0] if ids else None, ids[1:])


@router.prefix("POST", "/api/people/")
def merge_legacy(req):
    pid, _, tail = req.rest.partition("/")
    if tail != "merge":
        return None
    return _merge(req, pid, req.body.get("ids") or [])


# MARK: - A shared link (its public URL is built from the external domain)


@router.get("/api/shared-links")
def shared_links(req):
    return Response([{
        "id": "dddddddd-5555-4555-8555-000000000001", "description": "Stub link", "password": None,
        "userId": ME, "key": LINK_KEY, "type": "ALBUM",
        "createdAt": "2026-01-01T00:00:00.000Z", "expiresAt": None,
        "assets": [], "album": None,
        "allowUpload": False, "allowDownload": True, "showMetadata": True,
        "slug": None,
    }])


if __name__ == "__main__":
    main(label="route-compat")
