"""Immich API stub for the floating-controls scenario (`FloatingControlsUITests`).

Everything the app needs to boot, sign in and draw the ordinary timeline comes
from `immich_stub_base`. This file adds what the contrast capture needs, and
nothing else:

    python3 UITests/stubs/immich_stub_floating_controls.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/floating.uitest.log \\
        UITests/stubs/immich_stub_floating_controls.py FloatingControlsUITests/<test>

`WHITE_ASSET` — the first asset of the timeline — is served as a PURE WHITE
PNG, thumbnail and original alike. It is the worst background a floating
control can sit on (the dark glass is measured against it in
`FloatingControlStyleTests`), so the scenario opens the viewer on it and
attaches a capture of the controls over that photo. Every other asset id, and
every other tail, falls through to the shell. The PNGs are generated
(zlib), never pasted: see THE THUMBNAIL TRAP in `immich_stub_base`.

`GET /api/map/markers` — three markers around the Eiffel Tower, enough for the
map segment to draw its settings button over a light map.

`GET /api/timeline/buckets` and `/bucket` — one day of 60 photos (the base has
6, which never scrolls): the timeline scrolls far enough for its "scroll to top"
button to appear. The first photo is `WHITE_ASSET`.
"""
import zlib

from immich_stub_base import Response, TIMELINE_DAY, bucket_payload, main, router

WHITE_ASSET = "aaaaaaaa-1111-4111-8111-000000000001"
TALL_TIMELINE = [f"aaaaaaaa-1111-4111-8111-{i:012d}" for i in range(1, 61)]
CENTRE = (48.8584, 2.2945)


def white_png(size):
    """A real, decodable, pure white (255, 255, 255) `size`×`size` PNG."""
    raw = b"".join(b"\x00" + b"\xff\xff\xff" * size for _ in range(size))

    def chunk(kind, data):
        payload = kind + data
        return (len(data).to_bytes(4, "big") + payload
                + (zlib.crc32(payload) & 0xFFFFFFFF).to_bytes(4, "big"))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", size.to_bytes(4, "big") + size.to_bytes(4, "big")
                    + bytes((8, 2, 0, 0, 0)))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


@router.prefix("GET", "/api/assets/")
def white_photo(req):
    """The white photo's bytes; any other id or tail goes to the shell."""
    headers = {"Cache-Control": "no-store"}
    if req.rest == f"{WHITE_ASSET}/thumbnail":
        return Response(white_png(256), ctype="image/png", headers=headers)
    if req.rest == f"{WHITE_ASSET}/original":
        return Response(white_png(1024), ctype="image/png", headers=headers)
    return None


def marker(mid, city, offset):
    return {
        "id": mid, "lat": CENTRE[0] + offset, "lon": CENTRE[1] + offset,
        "city": city, "state": None, "country": "Stubland",
    }


@router.get("/api/map/markers")
def map_markers(req):
    return Response([
        marker(f"dddddddd-1111-4111-8111-{i:012d}", "Stubtown", i * 0.005)
        for i in range(1, 4)
    ])


@router.get("/api/timeline/buckets")
def buckets(req):
    return Response([{"timeBucket": TIMELINE_DAY, "count": len(TALL_TIMELINE)}])


@router.get("/api/timeline/bucket")
def bucket(req):
    return Response(bucket_payload(TALL_TIMELINE))


if __name__ == "__main__":
    main(label="floating-controls")
