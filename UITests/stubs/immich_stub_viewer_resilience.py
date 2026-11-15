"""Immich API stub for the viewer scenarios of lot L-29 (`ViewerResilienceUITests`).

The OAuth handshake, the day of timeline and the real PNG thumbnails come from
`immich_stub_base`. This file adds what the four behaviours need, behind switches
the scenario flips over HTTP:

    python3 UITests/stubs/immich_stub_viewer_resilience.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/viewer-resilience.uitest.log \\
        UITests/stubs/immich_stub_viewer_resilience.py ViewerResilienceUITests --erase

THE THREE ASSETS AND WHAT FAILS ON THEM

* `RETRY_ID` (`TIMELINE_ASSETS[1]`): the grid thumbnail (`size=thumbnail`) always
  answers 200, so the tile is a real photo and the page already shows it as a
  provisional image. The preview (`size=preview`, what the page asks for) answers
  500 or a 32x32 PNG, and `GET /api/assets/{id}` (the info panel, and the pixel
  size the page reads on opening) answers 500, 200, or 200 after 3 s. Every one of
  these answers is `Cache-Control: no-store`: the app's image session is
  `returnCacheDataElseLoad`, so a cached failure would be replayed without a
  request and the retry would prove nothing.
* `BARE_ID` (`TIMELINE_ASSETS[3]`): thumbnail AND preview answer 500 while its
  switch says so — no provisional image under the failure card.
* `VIDEO_ID` (`TIMELINE_ASSETS[0]`): a video tile like `immich_stub_video_player.py`
  (not imported: importing it would register its routes). `/video/playback` serves
  `fixtures/media/green-16x9-12s.mp4` with `206` + `Content-Range`, or 500 while
  `playback=fail`. `/original` serves bytes that are not a movie: an offline copy
  made from it is present on disk and unreadable.

SWITCHES

    GET /stub/switch?preview=fail|ok&details=fail|ok|slow&bare=fail|ok&playback=fail|ok

A control route outside `/__*`, hence logged in `/__requests` like any other.
`/__reset` puts every switch back to `ok`. The scenario sets them BEFORE launching
the app where it can, and flips them mid-test where the test is the retry itself.

THE FOLDER SURFACE

`GET /api/view/folder/unique-paths` answers `["/stub"]` and `GET /api/view/folder`
two photos of the day: the Folders screen opens its viewer without any of the
callbacks the timeline hands over (AC-58.5).

`PUT /api/assets/{id}` answers the asset with the `isFavorite` of the body, which
is what a favorite toggle reads back.
"""
import os
import re
import time

from immich_stub_base import (STATE, TIMELINE_ASSETS, Response, asset, bucket_payload, main, png,
                              router)

DAY = "2026-09-01"

VIDEO_ID = TIMELINE_ASSETS[0]
RETRY_ID = TIMELINE_ASSETS[1]
BARE_ID = TIMELINE_ASSETS[3]
FOLDER_IDS = [TIMELINE_ASSETS[4], TIMELINE_ASSETS[5]]

VIDEO_MS = 12_000
VIDEO_SIZE = (480, 270)

DEFAULT_SWITCHES = {"preview": "ok", "details": "ok", "bare": "ok", "playback": "ok"}
ALLOWED = {
    "preview": {"ok", "fail"},
    "details": {"ok", "fail", "slow"},
    "bare": {"ok", "fail"},
    "playback": {"ok", "fail"},
}

NO_STORE = {"Cache-Control": "no-store"}

FIXTURE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "fixtures", "media", "green-16x9-12s.mp4")

# Read once, at import: a missing fixture must stop the stub at startup.
try:
    with open(FIXTURE, "rb") as handle:
        VIDEO_BYTES = handle.read()
except OSError as error:  # pragma: no cover - a broken checkout, not a scenario
    raise SystemExit(f"viewer-resilience stub: cannot read {FIXTURE}: {error}")

# Not a movie, and exactly the size `asset()` advertises (`fileSizeInByte`): the
# offline store checks that number, so a copy of this body is accepted as complete.
NOT_A_MOVIE = (b"not a movie" * 200)[:2048]

RANGE = re.compile(r"bytes=(\d*)-(\d*)")


@router.reset
def fresh():
    STATE["switch"] = dict(DEFAULT_SWITCHES)


def switches():
    return STATE.setdefault("switch", dict(DEFAULT_SWITCHES))


def failure():
    return Response({"message": "stub failure"}, status=500, headers=NO_STORE)


def video_dto():
    dto = asset(VIDEO_ID, day=DAY)
    width, height = VIDEO_SIZE
    dto.update({
        "type": "VIDEO", "duration": VIDEO_MS, "width": width, "height": height,
        "originalPath": f"/x/{VIDEO_ID}.mp4",
        "originalFileName": "clip.mp4",
        "originalMimeType": "video/mp4",
    })
    return dto


def folder_asset(aid, minute):
    dto = asset(aid)
    stamp = f"2025-04-01T10:{minute:02d}:00.000Z"
    dto.update({"originalPath": f"/stub/{aid[-2:]}.jpg", "localDateTime": stamp, "createdAt": stamp,
                "fileCreatedAt": stamp, "fileModifiedAt": stamp, "updatedAt": stamp})
    dto["exifInfo"] = {**dto["exifInfo"], "dateTimeOriginal": stamp, "modifyDate": stamp}
    return dto


@router.get("/stub/switch")
def set_switch(req):
    current = switches()
    for name, value in req.params.items():
        if name in ALLOWED and value in ALLOWED[name]:
            current[name] = value
    req.note(switches=dict(current))
    return Response(current)


@router.get("/api/timeline/bucket")
def one_day(req):
    """The shell's day with its first tile turned into the video."""
    if req.params.get("timeBucket") != DAY:
        return None
    payload = bucket_payload(TIMELINE_ASSETS, day=DAY)
    payload["isImage"][0] = False
    payload["duration"][0] = VIDEO_MS
    payload["ratio"][0] = VIDEO_SIZE[0] / VIDEO_SIZE[1]
    return Response(payload)


@router.get("/api/view/folder/unique-paths")
def unique_paths(req):
    return Response(["/stub"])


@router.get("/api/view/folder")
def folder_assets(req):
    if req.params.get("path") != "/stub":
        return Response([])
    return Response([folder_asset(aid, minute) for minute, aid in enumerate(FOLDER_IDS)])


@router.prefix("PUT", "/api/assets/")
def update_asset(req):
    aid = req.rest.strip("/").split("/")[0]
    favorite = bool(req.body.get("isFavorite", False))
    req.note(isFavorite=favorite)
    dto = asset(aid)
    dto["isFavorite"] = favorite
    return Response(dto, headers=NO_STORE)


@router.prefix("GET", "/api/assets/")
def assets(req):
    parts = req.rest.strip("/").split("/")
    aid, tail = parts[0], (parts[1] if len(parts) > 1 else "")
    state = switches()

    if aid == RETRY_ID:
        if tail == "thumbnail" and req.params.get("size") == "preview":
            if state["preview"] == "fail":
                return failure()
            return Response(png(aid, size=32), ctype="image/png", headers=NO_STORE)
        if tail == "":
            if state["details"] == "fail":
                return failure()
            if state["details"] == "slow":
                time.sleep(3)
            return Response(asset(aid), headers=NO_STORE)

    if aid == BARE_ID and tail == "thumbnail" and state["bare"] == "fail":
        return failure()

    if aid == VIDEO_ID:
        if tail == "":
            return Response(video_dto(), headers=NO_STORE)
        if tail == "original":
            return Response(NOT_A_MOVIE, ctype="video/mp4", headers=NO_STORE)
        if tail == "video" and len(parts) > 2 and parts[2] == "playback":
            return playback(req, state)
    return None


def playback(req, state):
    """Real MP4 bytes. `206` + `Content-Range` because AVFoundation probes with
    `Range: bytes=0-1` and stops if the answer is a plain 200."""
    if state["playback"] == "fail":
        return failure()
    total = len(VIDEO_BYTES)
    header = (req.headers.get("Range") or "").strip()
    req.note(range=header or None, bytes=total)
    match = RANGE.fullmatch(header) if header else None
    headers = {"Accept-Ranges": "bytes", **NO_STORE}
    if match is None:
        return Response(VIDEO_BYTES, ctype="video/mp4", headers=headers)
    start = int(match.group(1)) if match.group(1) else 0
    end = min(int(match.group(2)) if match.group(2) else total - 1, total - 1)
    if start > end or start >= total:
        return Response(b"", status=416, ctype="video/mp4",
                        headers={**headers, "Content-Range": f"bytes */{total}"})
    return Response(VIDEO_BYTES[start:end + 1], status=206, ctype="video/mp4",
                    headers={**headers, "Content-Range": f"bytes {start}-{end}/{total}"})


if __name__ == "__main__":
    main(label="viewer-resilience")
