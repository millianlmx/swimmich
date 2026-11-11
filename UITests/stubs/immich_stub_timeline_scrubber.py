"""Immich API stub for the date-scrubber scenario (`TimelineScrubberUITests`).

Everything the app needs to boot, sign in and draw the timeline comes from
`immich_stub_base`. This file replaces the two timeline routes with a
three-year timeline the scrubber can travel:

    python3 UITests/stubs/immich_stub_timeline_scrubber.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/timeline-scrubber.uitest.log \\
        UITests/stubs/immich_stub_timeline_scrubber.py \\
        TimelineScrubberUITests/test_AC_14

WHAT THE WIRE SHOWS
    * "All": 36 months, `2025-12-01` (index 0, the newest) down to `2023-01-01`
      (index 35). Six photos per month, except `NEWEST_MONTH` (60 photos: more
      than one screen, so the last cell is off screen at launch and `loadMore`
      does not start — only that month is loaded) and `MID_MONTH` (21 photos
      taken the same day).
    * Every photo of a month has a distinct, strictly decreasing `fileCreatedAt`
      (rank r = the 15th at 12:00 UTC minus r-1 minutes), so the grid order and
      the rank encoded in the id agree.
    * Favorites: the rank-1 photo of 22 months (`2025-11-01` … `2024-02-01`).
    * Archive: three archived photos in `2025-10-01` and `2024-10-01`.
    * `FAIL_MONTH` answers 500 to its FIRST `GET /api/timeline/bucket` after
      `/__reset`; `SLOW_MONTH` answers after three seconds.
    * `GET /stub/timeline?mode=normal|empty|error` switches the month list.
"""
import time

from immich_stub_base import Response, STATE, bucket_payload, main, router

NEWEST_MONTH = "2025-12-01"
MID_MONTH = "2024-06-01"
FAIL_MONTH = "2024-03-01"
SLOW_MONTH = "2023-09-01"

# Index 0 = 2025-12-01 … index 35 = 2023-01-01.
MONTHS = [f"{2025 - i // 12}-{12 - i % 12:02d}-01" for i in range(36)]

# `2025-11-01` … `2024-02-01`: 22 months with one favorite each.
FAVORITE_MONTHS = MONTHS[1:23]
ARCHIVE_MONTHS = ["2025-10-01", "2024-10-01"]
ARCHIVE_COUNT = 3


def count_of(month):
    if month == NEWEST_MONTH:
        return 60
    if month == MID_MONTH:
        return 21
    return 6


def photo_id(month, rank, prefix="5c7ab000"):
    yyyy, mm = month[:4], int(month[5:7])
    return f"{prefix}-{yyyy}-4{mm:03d}-8111-{rank:012d}"


def stamp(month, rank):
    """The 15th at 12:00 UTC minus `rank - 1` minutes."""
    yyyy, mm = int(month[:4]), int(month[5:7])
    total = 12 * 60 - (rank - 1)
    return f"{yyyy}-{mm:02d}-15T{total // 60:02d}:{total % 60:02d}:00.000Z"


def payload_for(month, ranks, prefix="5c7ab000", favorite=False, visibility="timeline"):
    ids = [photo_id(month, r, prefix) for r in ranks]
    payload = bucket_payload(ids)
    stamps = [stamp(month, r) for r in ranks]
    payload["fileCreatedAt"] = stamps
    payload["createdAt"] = list(stamps)
    # Favorite months have their rank-1 photo as a favorite in the full grid too.
    payload["isFavorite"] = [favorite or (r == 1 and month in FAVORITE_MONTHS) for r in ranks]
    payload["visibility"] = [visibility] * len(ids)
    return payload


# Also set at import: a by-hand run that never calls `/__reset` must not crash.
STATE["mode"] = "normal"
STATE["failOnce"] = {FAIL_MONTH}


@router.get("/stub/timeline")
def control(req):
    mode = req.params.get("mode", "normal")
    STATE["mode"] = mode
    return Response({"mode": mode})


@router.get("/api/timeline/buckets")
def buckets(req):
    """The month list of the (filtered) timeline."""
    if STATE["mode"] == "error":
        return Response({"message": "stub error"}, status=500)
    if STATE["mode"] == "empty":
        return Response([])
    if req.params.get("isFavorite") == "true":
        return Response([{"timeBucket": m, "count": 1} for m in FAVORITE_MONTHS])
    if req.params.get("visibility") == "archive":
        return Response([{"timeBucket": m, "count": ARCHIVE_COUNT} for m in ARCHIVE_MONTHS])
    return Response([{"timeBucket": m, "count": count_of(m)} for m in MONTHS])


@router.get("/api/timeline/bucket")
def bucket(req):
    """The content of one month, under the same filters as `/buckets`."""
    month = req.params.get("timeBucket", "")
    req.note(month=month)
    if month == FAIL_MONTH and month in STATE["failOnce"]:
        STATE["failOnce"].discard(month)
        return Response({"message": "stub failure"}, status=500)
    if month == SLOW_MONTH:
        time.sleep(3)
    if STATE["mode"] == "empty" or month not in MONTHS:
        return Response(bucket_payload([]))
    if req.params.get("isFavorite") == "true":
        if month not in FAVORITE_MONTHS:
            return Response(bucket_payload([]))
        return Response(payload_for(month, [1], favorite=True))
    if req.params.get("visibility") == "archive":
        if month not in ARCHIVE_MONTHS:
            return Response(bucket_payload([]))
        return Response(payload_for(month, range(1, ARCHIVE_COUNT + 1), prefix="5c7ab0a0",
                                    visibility="archive"))
    return Response(payload_for(month, range(1, count_of(month) + 1)))


@router.reset
def fresh():
    """`/__reset`: normal mode, the failing month fails once more."""
    STATE["mode"] = "normal"
    STATE["failOnce"] = {FAIL_MONTH}


if __name__ == "__main__":
    main(label="timeline-scrubber")
