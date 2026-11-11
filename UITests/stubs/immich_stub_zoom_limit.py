"""Zoom-limit stub (L-06 / B-10): photos whose recorded resolution differs from
the few pixels the stub actually serves.

    python3 UITests/stubs/immich_stub_zoom_limit.py 8421

The viewer bounds its maximum zoom by the EXIF pixel size of `GET /api/assets/{id}`
(native scale: one photo pixel per screen pixel), so each timeline photo below
carries a different record, while the bytes stay small. The bytes keep the
ASPECT of the photo as displayed, because the viewer fits its pan bounds to the
decoded image — never paste bytes, they are generated (THE THUMBNAIL TRAP, see
`immich_stub_base.png`).

    role      EXIF (w×h, orientation)   served image   expected ceiling
    HD        8000×6000  "1"            80×60          native (≈ 6.79 on a 393 pt, 3x screen)
    SMALL     400×300    "1"            80×60          2.00 (floor)
    PORTRAIT  6000×8000  "1"            60×80          native (6000 / (width × scale))
    ROTATED   8000×6000  "6"            60×80          same as PORTRAIT (the server serves
                                                       an already-rotated preview)
    UNKNOWN   no dimensions             80×60          4.00 (default)
    LATE      400×300    "1"            80×60          4.00, then 2.00 once the record
                                                       arrives (delayed 6 s)

Everything is served `Cache-Control: no-store`: the app's image caches key on the
URL. The other photos stay the shell's.
"""
import time
import zlib

from immich_stub_base import PALETTE, Response, TIMELINE_ASSETS, asset, main, router

HD, SMALL, PORTRAIT, ROTATED, UNKNOWN, LATE = TIMELINE_ASSETS

LATE_DELAY_SECONDS = 6

# id → (exif width, exif height, orientation, served width, served height)
PHOTOS = {
    HD: (8000, 6000, "1", 80, 60),
    SMALL: (400, 300, "1", 80, 60),
    PORTRAIT: (6000, 8000, "1", 60, 80),
    ROTATED: (8000, 6000, "6", 60, 80),
    UNKNOWN: (None, None, "1", 80, 60),
    LATE: (400, 300, "1", 80, 60),
}

NO_STORE = {"Cache-Control": "no-store"}


def png_rect(fingerprint, width, height):
    """A real, decodable `width`×`height` PNG whose colour derives from `fingerprint`."""
    r, g, b = PALETTE[sum(fingerprint.encode()) % len(PALETTE)]
    raw = b"".join(b"\x00" + bytes((r, g, b)) * width for _ in range(height))

    def chunk(kind, data):
        payload = kind + data
        return (len(data).to_bytes(4, "big") + payload
                + (zlib.crc32(payload) & 0xFFFFFFFF).to_bytes(4, "big"))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", width.to_bytes(4, "big") + height.to_bytes(4, "big")
                    + bytes((8, 2, 0, 0, 0)))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


def photo_asset(aid):
    """The shell's `AssetResponseDto` with this photo's recorded resolution."""
    exif_w, exif_h, orientation, _, _ = PHOTOS[aid]
    dto = asset(aid)
    exif = dto["exifInfo"]
    exif["orientation"] = orientation
    if exif_w is None:
        exif.pop("exifImageWidth", None)
        exif.pop("exifImageHeight", None)
    else:
        exif["exifImageWidth"] = exif_w
        exif["exifImageHeight"] = exif_h
    return dto


@router.prefix("GET", "/api/assets/")
def asset_routes(req):
    parts = req.rest.split("/")
    aid = parts[0]
    if aid not in PHOTOS:
        return None  # the shell serves the other photos
    tail = parts[1] if len(parts) > 1 else ""
    if tail == "":
        if aid == LATE:
            # Held in this handler: the shell's server is threaded, so only this
            # request waits. The viewer shows the image first and gets the size late.
            time.sleep(LATE_DELAY_SECONDS)
        return Response(photo_asset(aid))
    if tail in ("thumbnail", "original"):
        _, _, _, width, height = PHOTOS[aid]
        return Response(png_rect(aid, width, height), ctype="image/png", headers=NO_STORE)
    return None


if __name__ == "__main__":
    main(label="zoom-limit")
