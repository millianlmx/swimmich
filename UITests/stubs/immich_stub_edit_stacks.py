"""Immich API stub for the "Also back up edits" scenario (`EditStacksUITests`, L-22).

Thin on purpose: the OAuth handshake, the server configuration, `/api/users/me`,
the thumbnails and `GET /api/assets/{id}` all come from `immich_stub_base`. This
file adds what the feature needs the server to REMEMBER — unlike the other stubs,
it holds a small ledger, because the scenario's last assertion is about the
timeline the server would build after the backup stacked an edit on its original:

    python3 UITests/stubs/immich_stub_edit_stacks.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/edit-stacks.uitest.log \\
        UITests/stubs/immich_stub_edit_stacks.py EditStacksUITests/test_AC_41_editStackedOnOriginal \\
        --erase --media L22-edit-on.png

    `POST /api/assets/bulk-upload-check` — `reject` (with the `assetId` that holds
    it) when the checksum is one an earlier upload carried, `accept` otherwise. The
    app's second pass asks about the edited rendering: a rendering whose checksum
    is unknown is accepted, which is what makes it upload.

    `POST /api/assets` — the upload, as multipart. The checksum comes from the
    `x-immich-checksum` header (the server dedups on it): a known one answers 200
    `{id, status: "duplicate"}`, a new one 201 `{id, status: "created"}` with a
    fresh UUID. `deviceAssetId`, the file name, `visibility` and `livePhotoVideoId`
    are read from the multipart body; the first two (and the checksum, the new id)
    are noted on `/__requests` so the scenario names the upload from the WIRE.

    `POST /api/stacks` — `assetIds` (at least two, else 400). The server's rule:
    every existing stack whose PRIMARY is in the list is merged into the new one,
    whose primary is the FIRST id. Answers 201 `StackResponseDto`.

    `GET /api/timeline/buckets` + `/api/timeline/bucket` — built from the uploaded
    assets whose visibility is `timeline`, one day (`TIMELINE_DAY`). With
    `withStacked=true` only the non-stacked assets and the stack heads are served,
    the head carrying `stack: [stackId, "<member count>"]` — what makes the app
    draw the stack badge on it and nothing on the original beneath. The base's six
    placeholder photos are NOT served: this timeline is the upload ledger.

    Deliberately NOT here: any checksum computed by the stub (it takes the one the
    app sends), persistence across `/__reset`, and the stack's other routes.
"""
import re
import uuid

from immich_stub_base import (Response, STATE, TIMELINE_DAY, bucket_payload, main,
                              router)

CHECK = "/api/assets/bulk-upload-check"
UPLOAD = "/api/assets"
STACKS = "/api/stacks"

# `MultipartBody.writeStreamed` writes CRLF-terminated parts; every field read here
# is plain ASCII, so it survives the stub's text decoding of the raw body.
DEVICE_ASSET_ID = re.compile(r'name="deviceAssetId"\r\n\r\n([^\r\n]+)')
FILENAME = re.compile(r'name="assetData"; filename="([^"]*)"')
VISIBILITY = re.compile(r'name="visibility"\r\n\r\n([^\r\n]+)')
LIVE_PHOTO_VIDEO_ID = re.compile(r'name="livePhotoVideoId"\r\n\r\n([^\r\n]+)')


@router.reset
def initial():
    # id -> {checksum, filename, deviceAssetId, visibility, stackId}
    STATE["assets"] = {}
    # id -> {primary, members}
    STATE["stacks"] = {}


# `/__reset` is not the only way in: a by-hand run has to find the state.
initial()


def _id_for_checksum(checksum):
    for aid, held in STATE["assets"].items():
        if checksum and held["checksum"] == checksum:
            return aid
    return None


@router.post(CHECK)
def bulk_upload_check(req):
    items = req.body.get("assets") or []
    ids = [item.get("id") for item in items]
    checksums = [item.get("checksum") or "" for item in items]
    results, rejected, accepted = [], [], []
    for item_id, checksum in zip(ids, checksums):
        held = _id_for_checksum(checksum)
        if held is not None:
            rejected.append(item_id)
            results.append({"id": item_id, "action": "reject", "reason": "duplicate",
                            "assetId": held})
        else:
            accepted.append(item_id)
            results.append({"id": item_id, "action": "accept"})
    req.note(checked=ids, checksums=checksums, rejected=rejected, accepted=accepted)
    return Response({"results": results})


@router.post(UPLOAD)
def upload(req):
    raw = req.body.get("raw", "") if isinstance(req.body, dict) else ""
    device = DEVICE_ASSET_ID.search(raw)
    name = FILENAME.search(raw)
    visibility = VISIBILITY.search(raw)
    live = LIVE_PHOTO_VIDEO_ID.search(raw)
    checksum = req.headers.get("x-immich-checksum") or ""

    held = _id_for_checksum(checksum)
    if held is not None:
        req.note(checksum=checksum, filename=name.group(1) if name else None,
                 deviceAssetId=device.group(1) if device else None, assetId=held)
        return Response({"id": held, "status": "duplicate"}, status=200)

    aid = str(uuid.uuid4())
    STATE["assets"][aid] = {
        "checksum": checksum,
        "filename": name.group(1) if name else None,
        "deviceAssetId": device.group(1) if device else None,
        "visibility": visibility.group(1) if visibility else "timeline",
        "livePhotoVideoId": live.group(1) if live else None,
        "stackId": None,
    }
    req.note(checksum=checksum, filename=name.group(1) if name else None,
             deviceAssetId=device.group(1) if device else None, assetId=aid)
    return Response({"id": aid, "status": "created"}, status=201)


@router.post(STACKS)
def create_stack(req):
    ids = req.body.get("assetIds") if isinstance(req.body, dict) else None
    ids = ids or []
    req.note(assetIds=ids)
    if len(ids) < 2:
        return Response({"message": "A stack needs at least two assets", "statusCode": 400,
                         "error": "Bad Request"}, status=400)

    members = list(ids)
    # The server's rule: a stack whose primary is among the ids is absorbed.
    for stack_id, stack in list(STATE["stacks"].items()):
        if stack["primary"] in ids:
            for member in stack["members"]:
                if member not in members:
                    members.append(member)
            del STATE["stacks"][stack_id]

    stack_id = str(uuid.uuid4())
    STATE["stacks"][stack_id] = {"primary": ids[0], "members": members}
    for member in members:
        if member in STATE["assets"]:
            STATE["assets"][member]["stackId"] = stack_id
    return Response({"id": stack_id, "primaryAssetId": ids[0], "assets": []}, status=201)


def _served(req):
    """Ids of the timeline, in upload order. Stacked: the heads and the loose ones."""
    stacked = req.params.get("withStacked") == "true"
    ids = []
    for aid, held in STATE["assets"].items():
        if held["visibility"] != "timeline":
            continue
        stack = STATE["stacks"].get(held["stackId"]) if held["stackId"] else None
        if stacked and stack is not None and stack["primary"] != aid:
            continue
        ids.append(aid)
    return ids, stacked


@router.get("/api/timeline/buckets")
def timeline_buckets(req):
    ids, _ = _served(req)
    if not ids:
        return Response([])
    return Response([{"timeBucket": TIMELINE_DAY, "count": len(ids)}])


@router.get("/api/timeline/bucket")
def timeline_bucket(req):
    ids, stacked = _served(req)
    payload = bucket_payload(ids)
    stack_column = []
    for aid in ids:
        held = STATE["assets"][aid]
        stack = STATE["stacks"].get(held["stackId"]) if held["stackId"] else None
        if stacked and stack is not None and stack["primary"] == aid:
            stack_column.append([held["stackId"], str(len(stack["members"]))])
        else:
            stack_column.append(None)
    payload["stack"] = stack_column
    return Response(payload)


if __name__ == "__main__":
    main(label="edit-stacks")
