"""Immich API stub for the "remaining to back up" scenario (`BackupRemainderUITests`).

Everything the app needs to boot, sign in and draw a timeline comes from
`immich_stub_base`. This file adds the two routes a backup run needs, and
nothing else: the server accepts EVERY asset it is asked about and stores every
upload, so a full pass sends the whole backup scope and the "remaining to back
up" list must end up empty.

    python3 UITests/stubs/immich_stub_backup_remainder.py 8421

WHAT IS LOGGED, AND WHY THE ASSERTIONS CAN BE EXACT
    Every route calls `req.note(...)`: a `/__requests` entry of a check carries
    `ids` (the Photos identifiers asked about), an entry of an upload carries
    `filename`, `deviceAssetId`, `fileCreatedAt` and `outcome` (`created`). The
    scenario asserts on those instead of re-parsing a multipart body in Swift.
"""
import re

from immich_stub_base import Response, STATE, main, router

# `MultipartBody.writeStreamed` writes the file field FIRST (with its filename
# in the disposition) and the text fields after it, so each pattern below sees
# an intact value even though the binary part in between decodes to U+FFFD.
FILE_FIELD = re.compile(r'name="assetData"; filename="([^"]*)"')
DEVICE_ASSET_ID_FIELD = re.compile(r'name="deviceAssetId"\r\n\r\n([^\r\n]*)')
FILE_CREATED_AT_FIELD = re.compile(r'name="fileCreatedAt"\r\n\r\n([^\r\n]*)')


def _field(pattern, raw):
    """The first captured value of `pattern` in `raw`, or `""`."""
    match = pattern.search(raw)
    return match.group(1) if match else ""


def _uploaded():
    """`deviceAssetId` → the server id the upload was stored under."""
    return STATE.setdefault("uploaded", {})


@router.post("/api/assets/bulk-upload-check")
def check(req):
    """The dedup question the engine asks before uploading: `accept` for all."""
    ids = [item.get("id") for item in ((req.body or {}).get("assets") or [])]
    req.note(ids=ids)
    return Response({"results": [{"action": "accept", "id": device_id} for device_id in ids]})


@router.post("/api/assets")
def upload(req):
    """`POST /api/assets` — the upload itself, one asset per request."""
    raw = (req.body or {}).get("raw", "")
    device_id = _field(DEVICE_ASSET_ID_FIELD, raw)
    req.note(filename=_field(FILE_FIELD, raw), deviceAssetId=device_id,
             fileCreatedAt=_field(FILE_CREATED_AT_FIELD, raw), outcome="created")
    server_id = "5d0cf1a2-2222-4222-8222-%012d" % (len(_uploaded()) + 1)
    _uploaded()[device_id] = server_id
    return Response({"id": server_id, "status": "created"}, status=201)


@router.reset
def fresh():
    """`/__reset` — a scenario must never inherit the previous run's uploads."""
    STATE["uploaded"] = {}


if __name__ == "__main__":
    main(label="backup-remainder")
