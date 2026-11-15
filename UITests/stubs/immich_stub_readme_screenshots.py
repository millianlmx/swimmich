"""Immich API stub of the README screenshots (`ReadmeScreenshotsUITests`).

    python3 UITests/stubs/immich_stub_readme_screenshots.py 8421

    Scripts/screenshots.sh        # regenerates docs/screenshots/*.png against this stub

Everything the app needs to boot and sign in comes from `immich_stub_base`. This
file answers what a screenshot has to show LOADED, with real pictures instead of
the base's flat-colour PNGs: 24 photos of two months (September and August 2026),
four albums, and a search whose results depend on the typed word. Nothing here is
personal: the eight pictures are the CC0 photos of `fixtures/readme/` (provenance
and licence in `fixtures/readme/README.md`), the account is the base's "Stub User".

THE PHOTOS
    `COUNT` assets, ids `cccccccc-0000-4000-8000-<n:012d>` for n = 1..24, newest
    first. Asset n shows `PHOTOS[(n * 3) % 8]`: 3 is coprime with 8, so two
    neighbours of the grid never show the same picture. Thumbnails (`size=thumbnail`)
    are the 480 px JPEGs, every other size (`preview`, `fullsize`) and `/original`
    the 1280 px ones, served `Cache-Control: no-store` like the base's PNGs.

THE ALBUMS
    `GET /api/albums` lists four albums, each made of the photos whose slug it names.
    The album detail reads its photos with `POST /api/search/metadata` and `albumIds`.

THE SEARCH
    `POST /api/search/smart` and `/metadata` match the word of `query` against the
    tags of each picture ("nature" gives the butterfly, the flower and the iguana).
    An empty query gives every photo, a word no picture carries gives none; one page.
"""
from pathlib import Path

from immich_stub_base import Response, asset, bucket_payload, main, router

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "readme"

# slug, width, height, tags, city, country
PHOTOS = [
    ("01-autumn", 1280, 853, ("autumn", "trees", "nature", "quebec"), "Québec", "Canada"),
    ("02-sunset", 1280, 729, ("sunset", "sea", "beach", "venezuela"), "Juan Griego", "Venezuela"),
    ("03-cavern", 1280, 965, ("cavern", "sea", "diving", "brazil"), "Arraial do Cabo", "Brazil"),
    ("04-butterfly", 1280, 866, ("butterfly", "insect", "nature", "garden"), "Isla Margarita", "Venezuela"),
    ("05-flower", 1280, 881, ("flower", "garden", "nature", "quebec"), "Québec", "Canada"),
    ("06-iguana", 1280, 850, ("iguana", "reptile", "animal", "nature"), "Maracaibo", "Venezuela"),
    ("07-skyline", 1280, 748, ("skyline", "city", "harbour", "night"), "Hong Kong", "China"),
    ("08-bridge", 1280, 850, ("bridge", "lake", "city", "venezuela"), "Cabimas", "Venezuela"),
]
COUNT = 24

# Each album is the set of pictures it names.
ALBUMS = [
    ("Québec in autumn", ("01-autumn", "05-flower")),
    ("Venezuela", ("02-sunset", "06-iguana", "08-bridge")),
    ("Wildlife", ("04-butterfly", "06-iguana", "05-flower")),
    ("Harbours and bridges", ("07-skyline", "08-bridge", "03-cavern")),
]

# month -> (first n, last n); each n belongs to the day of `taken()`.
MONTHS = {"2026-09-01": (1, 16), "2026-08-01": (17, 24)}
DAYS = [(1, "2026-09-14"), (6, "2026-09-12"), (10, "2026-09-07"), (17, "2026-08-23"), (21, "2026-08-09")]


def photo_id(n):
    return f"cccccccc-0000-4000-8000-{n:012d}"


def number_of(aid):
    """The n of a stub asset id, or `None` for an id that is not one of ours."""
    if not aid.startswith("cccccccc-0000-4000-8000-"):
        return None
    n = int(aid[-12:])
    return n if 1 <= n <= COUNT else None


def photo_of(n):
    return PHOTOS[(n * 3) % len(PHOTOS)]


def taken(n):
    """Strictly decreasing with n: the grid order and the id agree."""
    day = next(d for first, d in reversed(DAYS) if n >= first)
    minutes = 12 * 60 - n
    return f"{day}T{minutes // 60:02d}:{minutes % 60:02d}:00.000Z"


def asset_dto(n):
    slug, width, height, _tags, city, country = photo_of(n)
    stamp = taken(n)
    dto = asset(photo_id(n))
    dto.update({"width": width, "height": height, "originalFileName": f"{slug}.jpg",
                "originalPath": f"/photos/{slug}.jpg", "fileCreatedAt": stamp,
                "localDateTime": stamp, "createdAt": stamp})
    dto["exifInfo"].update({"city": city, "country": country, "exifImageWidth": width,
                            "exifImageHeight": height, "dateTimeOriginal": stamp,
                            "make": None, "model": None, "fileSizeInByte": 240000})
    return dto


def album_numbers(slugs):
    return [n for n in range(1, COUNT + 1) if photo_of(n)[0] in slugs]


def album_id(k):
    return f"dddddddd-0000-4000-8000-{k:012d}"


def album_dto(k):
    name, slugs = ALBUMS[k - 1]
    numbers = album_numbers(slugs)
    return {
        "id": album_id(k), "albumName": name, "description": "",
        "createdAt": "2026-09-01T10:00:00.000Z", "updatedAt": "2026-09-14T10:00:00.000Z",
        "albumThumbnailAssetId": photo_id(numbers[0]), "shared": False, "hasSharedLink": False,
        "assetCount": len(numbers), "isActivityEnabled": False, "order": "desc", "albumUsers": [],
    }


# MARK: - Timeline


@router.get("/api/timeline/buckets")
def buckets(req):
    return Response([{"timeBucket": month, "count": last - first + 1}
                     for month, (first, last) in MONTHS.items()])


@router.get("/api/timeline/bucket")
def bucket(req):
    first, last = MONTHS.get(req.params.get("timeBucket", ""), (1, 0))
    numbers = range(first, last + 1)
    payload = bucket_payload([photo_id(n) for n in numbers])
    payload["ratio"] = [photo_of(n)[1] / photo_of(n)[2] for n in numbers]
    payload["fileCreatedAt"] = [taken(n) for n in numbers]
    payload["createdAt"] = list(payload["fileCreatedAt"])
    return Response(payload)


# MARK: - Pictures


@router.prefix("GET", "/api/assets/")
def assets(req):
    aid, _, tail = req.rest.partition("/")
    n = number_of(aid)
    if n is None:
        return None  # `statistics` and any foreign id: the shell answers
    if not tail:
        return Response(asset_dto(n))
    if tail in ("thumbnail", "original"):
        small = tail == "thumbnail" and req.params.get("size", "thumbnail") == "thumbnail"
        data = (FIXTURES / f"{photo_of(n)[0]}{'-thumb' if small else ''}.jpg").read_bytes()
        return Response(data, ctype="image/jpeg", headers={"Cache-Control": "no-store"})
    return None


# MARK: - Albums


@router.get("/api/albums")
def albums(req):
    return Response([] if req.params.get("shared") == "true" else
                    [album_dto(k) for k in range(1, len(ALBUMS) + 1)])


@router.prefix("GET", "/api/albums/")
def album_detail(req):
    if "/" in req.rest or req.rest not in {album_id(k) for k in range(1, len(ALBUMS) + 1)}:
        return None
    return Response(album_dto(int(req.rest[-12:])))


# MARK: - Search


def _results(req):
    body = req.body if isinstance(req.body, dict) else {}
    if body.get("albumIds"):
        k = int(body["albumIds"][0][-12:])
        numbers = album_numbers(ALBUMS[k - 1][1])
    else:
        word = str(body.get("query") or "").strip().lower()
        numbers = [n for n in range(1, COUNT + 1) if not word or word in photo_of(n)[3]]
    req.note(matched=len(numbers))
    items = [asset_dto(n) for n in numbers] if int(body.get("page") or 1) == 1 else []
    return Response({"assets": {"count": len(items), "items": items, "nextPage": None, "nextCursor": None}})


@router.post("/api/search/smart")
def search_smart(req):
    return _results(req)


@router.post("/api/search/metadata")
def search_metadata(req):
    return _results(req)


if __name__ == "__main__":
    main(label="readme-screenshots")
