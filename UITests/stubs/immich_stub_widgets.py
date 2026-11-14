"""Widgets stub (L-30 / B-35): a server whose previews are as large as a real
Immich preview, so a widget archives — or fails to archive — an entry the size
of a real one.

    python3 UITests/stubs/immich_stub_widgets.py 8421

Why a dedicated stub: the shell serves 8×8 PNGs. WidgetKit refuses to archive an
entry whose images are too large for the widget, and a widget whose entry was
never archived keeps showing its waiting state — invisibly with 8×8 images,
which is how that bug hid for two days. The scenarios that pose a widget on the
Home Screen (`WidgetDisplaySizeUITests`) need previews that cover the largest
tile (1092×1146 px at 3×):

* `GET /api/assets/{id}/thumbnail?size=preview` serves a 1440×1920 PNG for the
  even-numbered ids and a 1920×1440 one for the odd ones (the size of a real
  Immich preview), a vertical gradient whose tint derives from the id. They are
  generated once, at startup, in pure Python (zlib; no dependency). No heavy
  noise on purpose: what decides archiving is the AREA in pixels; the bytes are
  proved by the unit tests (AC-61.6).
* `size=thumbnail` keeps the shell's 8×8 PNG (the grids of the app).
* the timeline serves the shell's 6 assets of `TIMELINE_DAY` for the Photos
  widget, and ONE favourite when the request carries `isFavorite=true`, so the
  Favorites widget draws its biggest tile (a single favourite fills the whole
  large widget).

Everything is served `Cache-Control: no-store`. `GET /__requests` is the wire
the scenarios assert on: which ids were asked at `size=preview&edited=true`.
"""
from immich_stub_base import (
    PALETTE, Response, TIMELINE_ASSETS, TIMELINE_DAY, bucket_payload, main, png, router,
)
import zlib

NO_STORE = {"Cache-Control": "no-store"}
FAVORITE = TIMELINE_ASSETS[0]


def _gradient_png(width, height, tint):
    """A `width`×`height` RGB PNG: the green channel runs top to bottom, red and
    blue are the tint. One repeated pixel per row keeps it fast to build."""
    red, _, blue = tint
    raw = b"".join(
        b"\x00" + bytes((red, row * 255 // (height - 1), blue)) * width
        for row in range(height)
    )

    def chunk(kind, data):
        payload = kind + data
        return (len(data).to_bytes(4, "big") + payload
                + (zlib.crc32(payload) & 0xFFFFFFFF).to_bytes(4, "big"))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", width.to_bytes(4, "big") + height.to_bytes(4, "big")
                    + bytes((8, 2, 0, 0, 0)))
            + chunk(b"IDAT", zlib.compress(raw, 1))
            + chunk(b"IEND", b""))


# (orientation, palette index) → bytes. Built at startup: a first request must
# not spend the widget's refresh budget on generating its own answer.
PREVIEWS = {
    (portrait, index): _gradient_png(*((1440, 1920) if portrait else (1920, 1440)), tint)
    for portrait in (True, False)
    for index, tint in enumerate(PALETTE)
}


def preview(aid):
    """Even-numbered ids (last hex digit) are portrait, odd ones landscape."""
    portrait = int(aid[-1], 16) % 2 == 0
    return PREVIEWS[(portrait, sum(aid.encode()) % len(PALETTE))]


@router.get("/api/timeline/buckets")
def buckets(req):
    count = 1 if req.params.get("isFavorite") == "true" else len(TIMELINE_ASSETS)
    return Response([{"timeBucket": TIMELINE_DAY, "count": count}])


@router.get("/api/timeline/bucket")
def bucket(req):
    if req.params.get("isFavorite") == "true":
        payload = bucket_payload([FAVORITE])
        payload["isFavorite"] = [True]
        return Response(payload)
    return Response(bucket_payload(TIMELINE_ASSETS))


@router.prefix("GET", "/api/assets/")
def thumbnails(req):
    parts = req.rest.split("/")
    if len(parts) != 2 or parts[1] != "thumbnail":
        return None  # the shell's asset DTOs and statistics
    if req.params.get("size") != "preview":
        return Response(png(parts[0]), ctype="image/png", headers=NO_STORE)
    return Response(preview(parts[0]), ctype="image/png", headers=NO_STORE)


if __name__ == "__main__":
    main(label="widgets")
