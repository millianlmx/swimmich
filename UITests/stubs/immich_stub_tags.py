"""Immich API stub for the tag hierarchy scenario (`TagsHierarchyUITests`, lot L-03).

    python3 UITests/stubs/immich_stub_tags.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/tags.uitest.log \\
        UITests/stubs/immich_stub_tags.py TagsHierarchyUITests --erase

WHAT IT SERVES, on top of `immich_stub_base`
* `GET /api/tags` — a flat list, as the server sends it: `name` is the short
  name and `value` the full path. Ten tags, ids `7a000000-0000-4000-8000-0000000000NN`
  (valid UUID v4: the real server validates `parentId` against that pattern).
* `POST /api/tags` — the creation. It logs `name`, `hasParentId` and `parentId`
  (`GET /__requests`), refuses a `/` in the name or an unknown parent with a 400
  (as v3.4.0 does), and answers 500 once `GET /api/__tags/fail-create` armed it.
  The control route lives under `/api/`: the base handler answers every `/__…`
  path itself and never consults a feature route there.
* `PUT|DELETE /api/tags/{id}/assets` — logs `tagId` and `ids`; `DELETE /api/tags/{id}`.
* `GET /api/timeline/buckets` and `/bucket` — the photos of a tag when the request
  carries `tagId`, the ordinary timeline otherwise.

THE DATA, chosen so a wrong screen is visible
* Japon (`…02`, under Voyages) holds `bbbb…1..3`. Voyages (`…01`) holds `cccc…1`
  AND its descendants' photos, as the real server does (`tag_closure`).
* The ordinary timeline holds the shell's six photos plus `cccc…1`: a tag screen
  that showed "everything" would show `aaaa…` tiles.
* Vide (`…08`): no bucket. Panne (`…09`): the first bucket list answers 500, the
  next ones succeed. Plage (`…0a`): two periods (60 photos, then 3) so reaching
  the second one takes scrolling.
"""
from immich_stub_base import STATE, TIMELINE_ASSETS, TIMELINE_DAY, Response, bucket_payload, bulk, main, router

STAMP = "2026-01-01T00:00:00.000Z"
UNKNOWN_PARENT = "7a000000-0000-4000-8000-000000000099"


def tid(n):
    return f"7a000000-0000-4000-8000-{n:012x}"


def created_id(n):
    return f"7a000000-0000-4000-8000-{0x100 + n:012x}"


def make_tag(n, name, value, parent=None):
    return {"id": tid(n), "name": name, "value": value, "color": None,
            "parentId": parent, "createdAt": STAMP, "updatedAt": STAMP}


def initial_tags():
    return [
        make_tag(0x01, "Voyages", "Voyages"),
        make_tag(0x02, "Japon", "Voyages/Japon", tid(0x01)),
        make_tag(0x03, "Tokyo", "Voyages/Japon/Tokyo", tid(0x02)),
        make_tag(0x04, "Famille", "Famille"),
        make_tag(0x05, "Orphelin", "Orphelin", UNKNOWN_PARENT),
        make_tag(0x06, "Cuisine", "Cuisine"),
        make_tag(0x07, "Japon", "Cuisine/Japon", tid(0x06)),
        make_tag(0x08, "Vide", "Vide"),
        make_tag(0x09, "Panne", "Panne"),
        make_tag(0x0A, "Plage", "Plage"),
    ]


JAPON_DAY = "2026-08-01"
JAPON = [f"bbbbbbbb-1111-4111-8111-{i:012d}" for i in range(1, 4)]
VOYAGES_ONLY = "cccccccc-1111-4111-8111-000000000001"
PANNE = [f"eeeeeeee-1111-4111-8111-{i:012d}" for i in range(1, 3)]
PLAGE_NEW = [f"ffffffff-1111-4111-8111-{i:012d}" for i in range(1, 61)]
PLAGE_OLD = [f"ffffffff-2222-4222-8222-{i:012d}" for i in range(1, 4)]


def periods(tag_id):
    """`[(day, ids)]` for a tag, newest first. Unknown tag: nothing."""
    if tag_id == tid(0x02):
        return [(JAPON_DAY, JAPON)]
    if tag_id == tid(0x01):
        return [(JAPON_DAY, [VOYAGES_ONLY] + JAPON)]
    if tag_id == tid(0x09):
        return [("2026-06-01", PANNE)]
    if tag_id == tid(0x0A):
        return [("2026-07-01", PLAGE_NEW), ("2025-07-01", PLAGE_OLD)]
    return []


@router.reset
def fresh():
    STATE["tags"] = initial_tags()
    STATE["created"] = 0
    STATE["fail_create"] = False
    STATE["panne_failed"] = False


fresh()  # a request before the first `/__reset` must not find an empty STATE


@router.get("/api/tags")
def list_tags(req):
    return Response(STATE["tags"])


@router.get("/api/__tags/fail-create")
def arm_fail_create(req):
    STATE["fail_create"] = True
    return Response({"fail_create": True})


@router.post("/api/tags")
def create_tag(req):
    body = req.body or {}
    name = body.get("name") or ""
    parent_id = body.get("parentId")
    req.note(name=name, hasParentId="parentId" in body, parentId=parent_id)
    if STATE["fail_create"]:
        return Response({"message": "Internal server error"}, status=500)
    if "/" in name:
        return Response({"message": "name must not contain /"}, status=400)
    parent = None
    if parent_id is not None:
        parent = next((t for t in STATE["tags"] if t["id"] == parent_id), None)
        if parent is None:
            return Response({"message": "Tag not found"}, status=400)
    STATE["created"] += 1
    value = f"{parent['value']}/{name}" if parent else name
    tag = {"id": created_id(STATE["created"]), "name": name, "value": value, "color": None,
           "parentId": parent_id, "createdAt": STAMP, "updatedAt": STAMP}
    STATE["tags"].append(tag)
    req.note(createdId=tag["id"])
    return Response(tag, status=201)


@router.prefix("PUT", "/api/tags/")
def tag_assets(req):
    ids = (req.body or {}).get("ids", [])
    req.note(tagId=req.rest.split("/")[0], ids=ids)
    return Response(bulk(ids))


@router.prefix("DELETE", "/api/tags/")
def untag_or_delete(req):
    parts = req.rest.split("/")
    if len(parts) > 1 and parts[1] == "assets":
        ids = (req.body or {}).get("ids", [])
        req.note(tagId=parts[0], ids=ids)
        return Response(bulk(ids))
    req.note(tagId=parts[0])
    return Response("", status=204, ctype="text/plain")


@router.get("/api/timeline/buckets")
def buckets(req):
    tag_id = req.params.get("tagId")
    if tag_id is None:
        return Response([{"timeBucket": TIMELINE_DAY, "count": len(TIMELINE_ASSETS) + 1}])
    if tag_id == tid(0x09) and not STATE["panne_failed"]:
        STATE["panne_failed"] = True
        return Response({"message": "Internal server error"}, status=500)
    return Response([{"timeBucket": day, "count": len(ids)} for day, ids in periods(tag_id)])


@router.get("/api/timeline/bucket")
def bucket(req):
    tag_id = req.params.get("tagId")
    day = req.params.get("timeBucket")
    if tag_id is None:
        return Response(bucket_payload(TIMELINE_ASSETS + [VOYAGES_ONLY]))
    ids = next((ids for d, ids in periods(tag_id) if d == day), [])
    return Response(bucket_payload(ids, day=day))


if __name__ == "__main__":
    main(label="tags")
