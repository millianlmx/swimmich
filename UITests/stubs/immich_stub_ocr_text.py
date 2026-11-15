"""Immich API stub for the detected-text scenario (`OcrTextUITests`, gap G8).

Thin on purpose: `immich_stub_base` already serves the OAuth handshake, the
server config, `/api/users/me`, a day of timeline and real PNG thumbnails. This
file adds the three things the feature under test owns.

    python3 UITests/stubs/immich_stub_ocr_text.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/ocr-text.uitest.log \\
        UITests/stubs/immich_stub_ocr_text.py OcrTextUITests/test_ocrText

1. `GET /api/assets/{id}/ocr` — an ARRAY of boxes whose eight coordinates are
   the four CORNERS of a tilted quadrilateral (`x1`/`y1` top-left, `x2`/`y2`
   top-right, `x3`/`y3` bottom-right, `x4`/`y4` bottom-left), normalized 0–1 on
   the stored image: an axis-aligned rect could not be told from the real
   contract, so every quad here is visibly tilted. The array is deliberately
   NOT in reading order and carries one box under the client's display
   threshold (`textScore < 0.5`) — the app must sort, label only the confident
   boxes, and still draw all three.

   THREE assets, because the negative half is the interesting one:

   * `TEXT_ASSET` (the shell's first timeline photo) — two confident boxes plus
     the faint one,
   * `BLANK_ASSET` (the shell's second) — an EMPTY array: the viewer must say
     so, not draw an empty overlay,
   * `SEARCH_ASSET` — a detected text the timeline does NOT contain, so a tile
     that appears on the search screen can only come from the search response
     (the Photos tab stays in the accessibility tree behind the Search tab,
     and its tiles would answer `assetTile_<id>` queries too).

2. `POST /api/search/metadata` — the v3.2.0 structured filter is the only field
   a detected-text criterion travels in (`filter.ocr.matches`); the deprecated
   scalar `MetadataSearchDto.ocr` must never appear. A body carrying the filter
   gets the assets whose detected text contains the needle, a plain free-text
   body gets nothing: the two shapes are distinguishable on screen AND on the
   wire, and both are logged on `/__requests`.

3. `GET /api/server/version` — overridden to 3.2.0 on purpose. The whole OCR
   half of the search screen is gated on the structured shape
   (`SearchViewModel.supportsStructuredSearch`), and the shell's own `2.0.0`
   would leave the toolbar toggle disabled: a scenario against it would prove
   nothing about the criterion.
"""
from immich_stub_base import Response, asset, main, router

# The shell's first two timeline photos (see TIMELINE_ASSETS): the viewer half
# of the scenario walks the timeline, so the two must be on it.
TEXT_ASSET = "aaaaaaaa-1111-4111-8111-000000000001"
BLANK_ASSET = "aaaaaaaa-1111-4111-8111-000000000002"
# Deliberately absent from the timeline — the search half's own asset.
SEARCH_ASSET = "dddddddd-1111-4111-8111-000000000042"

# What the viewer must announce, most confident first.
RECEIPT_TEXT = "Rechnung"
TOTAL_TEXT = "Total 42,00 \u20ac"
# Under `isConfident` (textScore >= 0.5): drawn, never labelled, never
# announced — the threshold is a display cut-off, not a data filter.
FAINT_TEXT = "Entwurf"


def _box(index, aid, text, text_score, corners):
    """One `AssetOcrResponseDto` — all thirteen fields, none of them optional."""
    (x1, y1), (x2, y2), (x3, y3), (x4, y4) = corners
    return {
        "id": f"ocr-{index}", "assetId": aid, "text": text,
        "boxScore": 0.9, "textScore": text_score,
        "x1": x1, "y1": y1, "x2": x2, "y2": y2,
        "x3": x3, "y3": y3, "x4": x4, "y4": y4,
    }


# Corner order: top-left, top-right, bottom-right, bottom-left. Every one of
# the four edges is off-axis — a `CGRect`-shaped payload (four values instead of
# eight) could not describe any of these.
def _timeline_boxes():
    return [
        # Server order is NOT reading order: the faint box comes first and the
        # most confident one last.
        _box(1, TEXT_ASSET, FAINT_TEXT, 0.22,
             [(0.22, 0.44), (0.60, 0.41), (0.61, 0.50), (0.23, 0.53)]),
        _box(2, TEXT_ASSET, TOTAL_TEXT, 0.61,
             [(0.42, 0.70), (0.90, 0.66), (0.91, 0.79), (0.43, 0.83)]),
        _box(3, TEXT_ASSET, RECEIPT_TEXT, 0.97,
             [(0.08, 0.13), (0.56, 0.08), (0.57, 0.21), (0.09, 0.26)]),
    ]


def _search_boxes():
    return [
        _box(4, SEARCH_ASSET, RECEIPT_TEXT, 0.93,
             [(0.14, 0.30), (0.72, 0.26), (0.73, 0.39), (0.15, 0.43)]),
    ]


# Asset id → boxes. An id that is not a key here is not an OCR asset: the
# handler returns None and the shell's `_unrouted` answers the empty page.
OCR = {
    TEXT_ASSET: _timeline_boxes(),
    BLANK_ASSET: [],
    SEARCH_ASSET: _search_boxes(),
}


@router.prefix("GET", "/api/assets/")
def asset_subroute(req):
    """`/ocr` for the assets above; the shell keeps thumbnail/detail/original.

    A prefix route is consulted before the shell, so every other `/api/assets/…`
    path must fall through (`None`) rather than be swallowed here.
    """
    aid, _, tail = req.rest.partition("/")
    if tail != "ocr":
        return None
    req.note(ocr_asset=aid)
    return Response(OCR.get(aid, []))


@router.get("/api/server/version")
def structured_search_server(req):
    """The generation the detected-text criterion needs (v3.2.0 `filter.ocr`)."""
    return Response({"major": 3, "minor": 2, "patch": 0, "prerelease": None})


@router.post("/api/search/metadata")
def metadata_search(req):
    """Full text answers nothing here; the detected-text filter answers exactly
    the assets whose OCR contains the needle.

    Both shapes are recorded — `req.note` is what the scenario asserts on, and
    the whole point of the feature is that the criterion travels as
    `filter.ocr.matches` and NEVER as the deprecated scalar `ocr`.
    """
    body = req.body if isinstance(req.body, dict) else {}
    structured = body.get("filter") or {}
    # `filter.ocr` absent, null or an object — only the last one carries a needle.
    needle = (structured.get("ocr") or {}).get("matches") if isinstance(structured, dict) else None
    hits = [aid for aid, boxes in OCR.items()
            if needle and any(needle.lower() in box["text"].lower() for box in boxes)]
    req.note(ocr_matches=needle, query=body.get("query"), scalar_ocr=body.get("ocr"))
    return Response({"assets": {"count": len(hits),
                                "items": [asset(aid) for aid in hits],
                                "nextPage": None,
                                "nextCursor": None}})


if __name__ == "__main__":
    main(label="ocr-text")
