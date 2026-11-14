"""Immich API stub for the adjust-date scenario (`AdjustDateUITests`, L-33).

Thin on purpose: boot, sign-in, the timeline, thumbnails and the base asset DTO
come from `immich_stub_base`. This file adds what the feature needs:

    python3 UITests/stubs/immich_stub_adjust_date.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/adjust-date.uitest.log \\
        UITests/stubs/immich_stub_adjust_date.py AdjustDateUITests

THE PHOTO
    The shell's first timeline asset, with `exifInfo.timeZone = "Europe/Paris"`
    and `exifInfo.dateTimeOriginal = "2024-07-14T08:00:00.000Z"`: 10:00 in Paris.

THE WRITE
    `PUT /api/assets/:id` is the feature. `req.note` records `dateTimeOriginalSent`
    (the exact string the app sent: `2024-07-14T10:00:00+09:00`) so the scenario
    reads it from `/__requests`. A string that reads as an ISO date is kept as
    the UTC instant it designates (`2024-07-14T01:00:00.000Z`) and answered to
    the next `GET`, with `timeZone` left at "Europe/Paris" — what a server from
    v2.0.0 to v2.4.0 does, which is why the app remembers the saved zone itself.
"""
from datetime import datetime, timezone

from immich_stub_base import Response, STATE, TIMELINE_ASSETS, asset, main, router

PHOTO = TIMELINE_ASSETS[0]
START_ZONE = "Europe/Paris"
START_DATE = "2024-07-14T08:00:00.000Z"


def photo_dto(aid):
    """The asset DTO with the instant this run last wrote (or the start one)."""
    dto = asset(aid)
    if aid == PHOTO:
        written = STATE.setdefault("dates", {}).get(aid, START_DATE)
        dto["exifInfo"]["timeZone"] = START_ZONE
        dto["exifInfo"]["dateTimeOriginal"] = written
        dto["fileCreatedAt"] = written
    return dto


def as_utc_instant(text):
    """`2024-07-14T10:00:00+09:00` -> `2024-07-14T01:00:00.000Z`; None if unreadable."""
    try:
        parsed = datetime.fromisoformat(text)
    except (TypeError, ValueError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


@router.prefix("GET", "/api/assets/")
def read_asset(req):
    """The photo's DTO; everything else (thumbnails, originals) falls through to the shell."""
    aid = req.rest
    if "/" in aid or aid != PHOTO:
        return None
    return Response(photo_dto(aid))


@router.prefix("PUT", "/api/assets/")
def write_date(req):
    """`PUT /api/assets/:id` — the only mutation this feature makes."""
    aid = req.rest
    if "/" in aid:
        return None
    sent = req.body.get("dateTimeOriginal")
    req.note(dateTimeOriginalSent=sent)
    instant = as_utc_instant(sent)
    if instant is not None:
        STATE.setdefault("dates", {})[aid] = instant
    return Response(photo_dto(aid))


@router.reset
def fresh():
    """`/__reset`: every run starts from the original date."""
    STATE["dates"] = {}


if __name__ == "__main__":
    main(label="adjust-date")
