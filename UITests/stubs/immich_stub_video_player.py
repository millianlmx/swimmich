"""Immich API stub for the video-player layout scenario (`VideoPlayerLayoutUITests`).

Thin on purpose: the OAuth handshake, the server config, `/api/users/me`, the
day of timeline and the real PNG thumbnails come from `immich_stub_base`. This
file adds the three things a video page needs — an asset that IS a video, a
memory whose hero is that same video, and a route that serves real MP4 bytes:

    python3 UITests/stubs/immich_stub_video_player.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/video-player-layout.uitest.log \\
        UITests/stubs/immich_stub_video_player.py VideoPlayerLayoutUITests/test_videoPlayerLayout \\
        --erase

The three surfaces, and why each one is here:

* `GET /api/timeline/bucket` — the shell's day, with its FIRST tile swapped for
  a video asset (`VIDEO_ID`). Same id list, same length: the columnar payload is
  zipped by index, and a photo count that disagreed with `/api/timeline/buckets`
  would show up as a short day.
* `GET /api/memories` — one memory (`MEMORY_ID`) whose FIRST asset is that same
  video, so `MemoryMomentView.heroAsset` is the video (the hero plays, and the
  moment view's own controls stay absent — its `controlsVisible: false`).
* `GET /api/assets/{id}/video/playback` — the fixture
  `UITests/stubs/fixtures/media/green-16x9-12s.mp4`, regenerated with
  `UITests/stubs/tools/make_video_fixture.swift` (480x270, 12 s, one flat green
  frame — long enough that the transport is still on screen, and still PLAYING,
  while the scenario asserts its geometry). It answers `206` + `Content-Range`
  when a `Range` header is present — AVFoundation reads a progressive MP4 with
  `Range: bytes=0-1` first, and a server without Range support leaves the page
  stuck preparing. The scenario counts these requests: TWO per video actually
  read, which is why it asserts on the DELTA across the memory leg rather than on
  a total (see the scenario).

Additive like every feature stub: `/api/assets/*` requests that are not this
playback route (thumbnails, originals) fall through to the shell.
"""
import os
import re

from immich_stub_base import (ME, TIMELINE_ASSETS, Response, asset, bucket_payload, main,
                              router)

# The day the shell's timeline opens on (`TIMELINE_DAY` in immich_stub_base).
DAY = "2026-09-01"

# The one video of this stub. It replaces the FIRST tile of the day, so it is the
# easiest tile to reach — and the id is the address the scenario taps.
VIDEO_ID = "aaaaaaaa-1111-4111-8111-000000000001"

# The memory whose hero is the same video. Fixed id, addressed by the scenario.
MEMORY_ID = "dddddddd-4444-4444-8444-000000000001"

# Duration in MILLISECONDS (the Immich unit) — the real length of the fixture, so
# the tile badge and the transport agree.
VIDEO_MS = 12_000
VIDEO_SIZE = (480, 270)

FIXTURE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "fixtures", "media", "green-16x9-12s.mp4")

# Read once, at import: a stub whose fixture is missing must die at startup, not
# answer half a video later. `main()` prints the endpoints on the way up.
try:
    with open(FIXTURE, "rb") as handle:
        VIDEO_BYTES = handle.read()
except OSError as error:  # pragma: no cover - a broken checkout, not a scenario
    raise SystemExit(f"video-player stub: cannot read {FIXTURE}: {error}")

# `bytes=a-b`, `bytes=a-` and `bytes=-n` are all legal; AVFoundation sends the
# first two (0-1, then 0-<last>).
RANGE = re.compile(r"bytes=(\d*)-(\d*)")


def video_dto():
    """The video as a full `AssetResponseDto` — the shape `/api/memories` and
    `GET /api/assets/{id}` carry. Built from the shell's photo DTO so every
    required field is present, then overridden where a video differs; a missing
    required key would fail the WHOLE list decode, not just this row."""
    dto = asset(VIDEO_ID, day=DAY)
    width, height = VIDEO_SIZE
    dto.update({
        "type": "VIDEO",
        "duration": VIDEO_MS,
        "width": width,
        "height": height,
        "originalPath": f"/x/{VIDEO_ID}.mp4",
        "originalFileName": f"{VIDEO_ID[:4]}-{VIDEO_ID[-2:]}.mp4",
        "originalMimeType": "video/mp4",
    })
    return dto


def memory_dto():
    """One "on this day" memory whose FIRST asset is the video. Shape copied from
    `immich_stub_memories.memory_dto()`; the type is the server's only value and
    `data.year` is what the card's "N years ago" chip reads."""
    stamp = "2022-09-01T10:00:00.000Z"
    return {
        "id": MEMORY_ID,
        "createdAt": stamp, "updatedAt": stamp,
        "memoryAt": stamp, "ownerId": ME,
        "type": "on_this_day",
        "data": {"year": 2022},
        "assets": [video_dto()],
        "isSaved": False,
        "showAt": None, "hideAt": None, "seenAt": None, "deletedAt": None,
    }


@router.get("/api/timeline/bucket")
def one_day(req):
    """The shell's day with its first tile turned into the video. Returns `None`
    for any other day so the shell keeps answering its own timeline."""
    if req.params.get("timeBucket") != DAY:
        return None
    ids = [VIDEO_ID] + [aid for aid in TIMELINE_ASSETS if aid != VIDEO_ID]
    payload = bucket_payload(ids, day=DAY)
    payload["isImage"][0] = False
    payload["duration"][0] = VIDEO_MS
    # The real ratio of the 16:9 fixture: the tile must not claim a photo's shape.
    payload["ratio"][0] = VIDEO_SIZE[0] / VIDEO_SIZE[1]
    return Response(payload)


@router.get("/api/memories")
def memories(req):
    """The one memory of this stub — a video hero and nothing else, so the
    moment view never auto-advances away from it (its ticker stands down on a
    video hero anyway)."""
    return Response([memory_dto()])


@router.prefix("GET", "/api/assets/")
def asset_route(req):
    """Real MP4 bytes for the video's playback route; everything else under
    `/api/assets/` (thumbnails, originals, the detail route) is the shell's.

    `206` + `Content-Range` + `Accept-Ranges` is not politeness: AVFoundation
    probes a progressive MP4 with `Range: bytes=0-1` and stops there if the
    answer is a plain `200` with no range support. The `range` field lands in
    `/__requests`, which is how the scenario proves a video was actually read.
    """
    if not req.rest.endswith("/video/playback"):
        return None
    if req.rest[: -len("/video/playback")].strip("/") != VIDEO_ID:
        return None

    total = len(VIDEO_BYTES)
    header = (req.headers.get("Range") or "").strip()
    req.note(range=header or None, bytes=total)
    match = RANGE.fullmatch(header) if header else None
    headers = {"Accept-Ranges": "bytes", "Cache-Control": "no-store"}
    if match is None:
        return Response(VIDEO_BYTES, ctype="video/mp4", headers=headers)

    start = int(match.group(1)) if match.group(1) else 0
    end = int(match.group(2)) if match.group(2) else total - 1
    end = min(end, total - 1)
    if start > end or start >= total:
        return Response(b"", status=416, ctype="video/mp4",
                        headers={**headers, "Content-Range": f"bytes */{total}"})
    return Response(
        VIDEO_BYTES[start:end + 1],
        status=206,
        ctype="video/mp4",
        headers={**headers, "Content-Range": f"bytes {start}-{end}/{total}"},
    )


if __name__ == "__main__":
    main(label="video-player")
