"""Immich API stub for the partner scenarios (`test_06_partners` and, since lot
L-08, `PartnerLibraryUITests`).

    python3 UITests/stubs/immich_stub_partners.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/partners.uitest.log \\
        UITests/stubs/immich_stub_partners.py PartnerLibraryUITests --erase

Built on `immich_stub_base` (OAuth shell, request journal `/__requests`, asset
thumbnails). What it adds:

PARTNERS
* `GET /api/partners` **requires** `direction` and answers **400** without it.
  The app once shipped a direction-less call (`getPartners()`); a hard failure
  here beats a silently empty list.
* the rows of a direction are the *other* user of the pair, and `PUT`
  (`sharedById = id, sharedWithId = me`) and `DELETE` (`sharedById = me,
  sharedWithId = id`) each only match one direction: a mutation sent on the
  wrong collection is a 400, not a silent no-op.
* "Incoming Ivan" (A) and "Second Sam" (B) share with me; I share with "Outgoing
  Olive". "Invitable Iris" is only in the directory.

THE TIMELINE, replaying `timeline.service.ts` of Immich v3.4.0
* `GET /api/timeline/buckets` and `/bucket` serve the photos below. Other
  accounts' photos need the right to read them: a `userId` that is not a
  `shared_with` partner is a 400 (`Not found or no timeline.read access`).
* "other accounts" = `withPartners=true` or a `userId` that is not me. There
  `visibility` defaults to `timeline`, and any other visibility, `isTrashed=true`
  or any `isFavorite` is a 400.
* owners: `[userId]` when `userId` is another account, else `[me]`; with
  `withPartners=true` the `shared_with` partners whose `inTimeline` is true at
  THAT instant are added (so a `PUT /api/partners/<id>` is followed at once).
* no `visibility` and not "other": timeline and archive of `[me]`.
* every month is `YYYY-MM-01`, newest first; `/bucket` returns the month of
  `timeBucket[:7]`, newest photo first, with the real `ownerId`.

THE PHOTOS (all UTC, hours decreasing: the smallest index is the newest)
* me: the six `TIMELINE_ASSETS`, 2026-09-01.
* A: 30 `A_SEPT` photos on 2026-09-12 (10:00 minus NN minutes), one archived
  photo that day, two on 2026-07-04, two on 2026-05-20.
* B: one photo on 2026-09-12.
Each photo of A or B has a unique `city` (`A-sept-01`, …, `B-1`): the viewer
shows it in `viewerBadgePlace`, which identifies the photo without localized text.
`GET /api/assets/<id>` for those photos carries the real owner and visibility.

CONTROL ROUTES (under `/api/`: the base answers every `/__…` path itself)
* `GET /api/__partners/in-timeline?id=<id>&value=true|false` — sets `inTimeline`
  of a `shared_with` row (400 for an unknown id).
* `GET /api/__partners/script?steps=500,empty,ok&delay=<seconds>` — arms a queue
  consumed by the `GET /api/timeline/buckets` requests whose `userId` is another
  account, one step per request: `500` answers 500, `empty` answers `[]`, `ok`
  the normal answer; each step waits `delay` seconds first. An empty queue
  answers normally, with no delay.
"""
import time

from immich_stub_base import (
    CONFIG, ME, STATE, TIMELINE_ASSETS, TIMELINE_DAY, Response, asset, bucket_payload, main, router,
)

# Shares their library with me → "Shared with me", `inTimeline` true at the start.
INCOMING = "aaaaaaaa-1111-4111-8111-111111111111"
# I share my library with them → "Sharing".
OUTGOING = "bbbbbbbb-2222-4222-8222-000000000002"
# Nobody has invited them yet → offered by the invite sheet.
INVITABLE = "cccccccc-3333-4333-8333-000000000003"
# Shares with me, hidden from my timeline at the start.
SECOND = "dddddddd-4444-4444-8444-000000000004"

FORBIDDEN_COMBINATION = (
    "Only non-archived, non-trashed, non-favorited, non-locked assets "
    "can be requested for other users"
)


def user(uid, name, email):
    return {
        "id": uid, "name": name, "email": email, "profileImagePath": "",
        "avatarColor": "primary", "profileChangedAt": "2026-01-01T00:00:00.000Z",
    }


def partner(uid, name, email, in_timeline):
    return {**user(uid, name, email), "inTimeline": in_timeline}


# MARK: - Photos


def stamp(day, minute_of_day):
    return f"{day}T{minute_of_day // 60:02d}:{minute_of_day % 60:02d}:00.000Z"


def photo(pid, owner, day, minute_of_day, visibility="timeline", city=None):
    return {"id": pid, "owner": owner, "day": day, "stamp": stamp(day, minute_of_day),
            "visibility": visibility, "city": city}


A_SEPT = [photo(f"a5a5a5a5-1111-4111-8111-{n:012d}", INCOMING, "2026-09-12", 600 - n,
                city=f"A-sept-{n:02d}") for n in range(1, 31)]
A_ARCHIVED = photo("a5a5a5a5-9999-4999-8999-000000000001", INCOMING, "2026-09-12", 720,
                   visibility="archive", city="A-archived")
A_JULY = [photo(f"a5a5a5a5-2222-4222-8222-{n:012d}", INCOMING, "2026-07-04", 600 - n,
                city=f"A-july-{n}") for n in (1, 2)]
A_MAY = [photo(f"a5a5a5a5-3333-4333-8333-{n:012d}", INCOMING, "2026-05-20", 600 - n,
               city=f"A-may-{n}") for n in (1, 2)]
B_PHOTOS = [photo("d4d4d4d4-1111-4111-8111-000000000001", SECOND, "2026-09-12", 600, city="B-1")]
MINE = [photo(pid, ME, TIMELINE_DAY, 600) for pid in TIMELINE_ASSETS]

PHOTOS = MINE + A_SEPT + [A_ARCHIVED] + A_JULY + A_MAY + B_PHOTOS
BY_ID = {p["id"]: p for p in PHOTOS}


# MARK: - State


@router.reset
def fresh():
    # direction=shared-by rows: people I added.
    STATE["shared_by"] = [partner(OUTGOING, "Outgoing Olive", "olive@example.com", False)]
    # direction=shared-with rows: people who share with me.
    STATE["shared_with"] = [
        partner(INCOMING, "Incoming Ivan", "ivan@example.com", True),
        partner(SECOND, "Second Sam", "sam@example.com", False),
    ]
    # The queue armed by `/api/__partners/script`.
    STATE["script"] = {"steps": [], "delay": 0.0}


fresh()  # a request before the first `/__reset` must not find an empty STATE

DIRECTIONS = {"shared-by": "shared_by", "shared-with": "shared_with"}


# MARK: - Partners


@router.get("/api/partners")
def list_partners(req):
    direction = req.params.get("direction")
    req.note(direction=direction)
    if direction not in DIRECTIONS:
        # Exactly what the real server does (ZodValidationPipe on a required
        # enum). No silent empty list.
        return Response(
            {"error": "Bad Request", "message": ["direction must be one of: shared-by, shared-with"]},
            status=400,
        )
    return Response(STATE[DIRECTIONS[direction]])


@router.get("/api/users")
def list_users(req):
    return Response([
        user(ME, "Stub User", "stub@example.com"),
        user(INCOMING, "Incoming Ivan", "ivan@example.com"),
        user(OUTGOING, "Outgoing Olive", "olive@example.com"),
        user(INVITABLE, "Invitable Iris", "iris@example.com"),
        user(SECOND, "Second Sam", "sam@example.com"),
    ])


@router.get("/api/server/config")
def server_config(req):
    return Response({**CONFIG, "publicUsers": True})


@router.post("/api/partners")
def create_partner(req):
    shared_with_id = (req.body or {}).get("sharedWithId")
    req.note(sharedWithId=shared_with_id)
    if not shared_with_id:
        return Response({"error": "Bad Request", "message": ["sharedWithId must be a uuid"]}, status=400)
    if any(p["id"] == shared_with_id for p in STATE["shared_by"]):
        return Response({"error": "Bad Request", "message": "Partner already exists"}, status=400)
    created = partner(shared_with_id, f"User {shared_with_id[:4]}", f"{shared_with_id[:4]}@example.com", False)
    STATE["shared_by"].append(created)
    return Response(created, status=201)


@router.prefix("PUT", "/api/partners/")
def update_partner(req):
    body = req.body or {}
    req.note(inTimeline=body.get("inTimeline"))
    # The server pairs {sharedById: id, sharedWithId: me}: only a row from
    # `direction=shared-with` can be updated.
    for row in STATE["shared_with"]:
        if row["id"] == req.rest:
            row["inTimeline"] = bool(body.get("inTimeline"))
            return Response(row)
    return Response({"error": "Bad Request", "message": "Partner not found"}, status=400)


@router.prefix("DELETE", "/api/partners/")
def delete_partner(req):
    # The server pairs {sharedById: me, sharedWithId: id}: only a row from
    # `direction=shared-by` can be removed.
    before = len(STATE["shared_by"])
    STATE["shared_by"] = [p for p in STATE["shared_by"] if p["id"] != req.rest]
    if len(STATE["shared_by"]) == before:
        return Response({"error": "Bad Request", "message": "Partner not found"}, status=400)
    return Response(b"", status=204, ctype="application/octet-stream")


# MARK: - Timeline


def in_timeline_partners():
    return [row["id"] for row in STATE["shared_with"] if row["inTimeline"]]


def timeline_photos(params):
    """The photos the server would serve for these query parameters, or a
    `Response` carrying the 400 it would answer."""
    user_id = params.get("userId")
    with_partners = params.get("withPartners") == "true"
    other_account = user_id not in (None, ME)

    if other_account and not any(row["id"] == user_id for row in STATE["shared_with"]):
        return Response({"message": "Not found or no timeline.read access"}, status=400)

    others = with_partners or other_account
    visibility = params.get("visibility")
    if others:
        visibility = visibility or "timeline"
        if visibility != "timeline" or params.get("isTrashed") == "true" or "isFavorite" in params:
            return Response({"message": FORBIDDEN_COMBINATION}, status=400)

    owners = [user_id] if other_account else [ME]
    if with_partners:
        owners += in_timeline_partners()

    if params.get("isFavorite") == "true" or params.get("isTrashed") == "true":
        return []  # no photo is favorite or trashed
    allowed = {visibility} if visibility else {"timeline", "archive"}
    return [p for p in PHOTOS if p["owner"] in owners and p["visibility"] in allowed]


def newest_first(photos):
    # `sorted` is stable and `reverse=True` keeps ties in order: my six photos
    # share one stamp and stay in `TIMELINE_ASSETS` order.
    return sorted(photos, key=lambda p: p["stamp"], reverse=True)


@router.get("/api/timeline/buckets")
def timeline_buckets(req):
    user_id = req.params.get("userId")
    script = STATE["script"]
    if user_id not in (None, ME) and script["steps"]:
        step = script["steps"].pop(0)
        if script["delay"]:
            time.sleep(script["delay"])
        if step == "500":
            return Response({"message": "stub failure"}, status=500)
        if step == "empty":
            return Response([])
    photos = timeline_photos(req.params)
    if isinstance(photos, Response):
        return photos
    counts = {}
    for p in photos:
        counts[p["stamp"][:7]] = counts.get(p["stamp"][:7], 0) + 1
    return Response([{"timeBucket": f"{month}-01", "count": counts[month]}
                     for month in sorted(counts, reverse=True)])


@router.get("/api/timeline/bucket")
def timeline_bucket(req):
    photos = timeline_photos(req.params)
    if isinstance(photos, Response):
        return photos
    month = (req.params.get("timeBucket") or "")[:7]
    rows = newest_first([p for p in photos if p["stamp"][:7] == month])
    payload = bucket_payload([p["id"] for p in rows])
    payload["ownerId"] = [p["owner"] for p in rows]
    payload["createdAt"] = [p["stamp"] for p in rows]
    payload["fileCreatedAt"] = [p["stamp"] for p in rows]
    payload["visibility"] = [p["visibility"] for p in rows]
    payload["city"] = [p["city"] for p in rows]
    return Response(payload)


@router.prefix("GET", "/api/assets/")
def partner_asset(req):
    """The detail of a photo of A or B, with its real owner. Anything else
    (my photos, `/thumbnail`, `/original`) falls through to the shell."""
    p = BY_ID.get(req.rest)
    if p is None or p["owner"] == ME:
        return None
    return Response({**asset(p["id"], p["day"]), "ownerId": p["owner"], "visibility": p["visibility"],
                     "isArchived": p["visibility"] == "archive"})


# MARK: - Control routes


@router.get("/api/__partners/in-timeline")
def set_in_timeline(req):
    partner_id = req.params.get("id")
    value = req.params.get("value") == "true"
    for row in STATE["shared_with"]:
        if row["id"] == partner_id:
            row["inTimeline"] = value
            return Response({"id": partner_id, "inTimeline": value})
    return Response({"message": "unknown partner"}, status=400)


@router.get("/api/__partners/script")
def arm_script(req):
    steps = [s for s in (req.params.get("steps") or "").split(",") if s]
    STATE["script"] = {"steps": steps, "delay": float(req.params.get("delay") or 0)}
    return Response({"steps": steps, "delay": STATE["script"]["delay"]})


if __name__ == "__main__":
    main(label="partners")
