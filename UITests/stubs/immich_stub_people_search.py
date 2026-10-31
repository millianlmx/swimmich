"""Immich API stub for the "people search by name" scenario (`PeopleSearchUITests`).

Thin on purpose: booting, signing in and drawing the timeline come from
`immich_stub_base` (the OAuth handshake, the server config, `/api/users/me`, a
day of timeline, real PNG thumbnails). This file adds what the feature owns — a
four-person library, the paged list and the ONE route the search box calls:

    python3 -u UITests/stubs/immich_stub_people_search.py 8421

    TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test-without-building \\
        -only-testing:ImmichSwiftUIUITests/PeopleSearchUITests ...

(there is no launcher in a worktree: `.omp/orchestration/uitest.sh` is absent and
gitignored, so the stub is started by hand — see the header of the scenario).

THE LIBRARY. Ada (5 photos), Alan (3 photos, the ONLY favourite), Alice (7
photos) and Alina (9 photos, HIDDEN). `GET /api/people` answers the three
visible ones, plus Alina when `withHidden=true`; it always says `hidden: 1` and
`hasNextPage: false`, whatever `page` is. Once the counts arrived, the paged
screen therefore reads: "Featured" = [Alan]; "People" = [Alice, Ada] (most
photos first); a "Show 1 hidden people" button.

THE SEARCH. `GET /api/search/person?name=&withHidden=` answers a BARE array, in
an order the server owns, from a table of exact strings (case-sensitive, and the
`name` is NOT trimmed here — the shell does not trim parameters, so a name with a
blank at either end matches nothing and the scenario can tell the app trimmed):

* `ali`  -> [Alice, Alan]; with `withHidden=true`, [Alice, Alan, Alina].
  [Alice, Alan] differs from the alphabetical order (Alan, Alice) and from the
  Featured/People split (the favourite Alan would sit on top under a "Featured"
  header); it coincides with the sort by photo count (7 > 3), which only the
  three-person answer tells apart (Alina, 9 photos, would lead).
* `zzz`  -> [] (the "no result" screen).
* `err`  -> 500 the FIRST time after a reset, then [Ada] (Retry). The body of the
  500 carries the sentinel `STUB-500-BODY`: it must never reach the screen.
* anything else (the intermediate keystrokes "a", "al", "z", "e", "er", or an
  untrimmed name) -> [].
The hidden person only shows up when `withHidden` is true.

Every request is in the shell's log (`GET /__requests`: method, path without the
query, params), which is how a scenario reads back what the app really sent.
"""
from immich_stub_base import STATE, TIMELINE_ASSETS, Response, asset, main, png, router

# Keep these in step with `PeopleSearchUITests` (it recopies the ids).
ADA = "eeeeeeee-3333-4333-8333-000000000001"
ALAN = "eeeeeeee-3333-4333-8333-000000000002"
ALICE = "eeeeeeee-3333-4333-8333-000000000003"
ALINA = "eeeeeeee-3333-4333-8333-000000000004"

# `GET /api/people/{id}/statistics` — the count under each name.
COUNTS = {ADA: 5, ALAN: 3, ALICE: 7, ALINA: 9}


def person(pid, name, favorite=False, hidden=False):
    """One `PersonResponseDto` — every non-optional field the app decodes."""
    return {
        "id": pid,
        "name": name,
        "birthDate": None,
        "thumbnailPath": "",
        "isHidden": hidden,
        "color": "#4a5aef",
        "isFavorite": favorite,
        "updatedAt": "2026-09-01T10:00:00.000Z",
    }


def seed():
    """(Re)install the fixture — run at import and on every `/__reset`, so no
    assertion can be satisfied by a previous run's leftovers."""
    STATE["err_failed"] = False


router.reset(seed)
seed()

PEOPLE = {
    ADA: person(ADA, "Ada"),
    ALAN: person(ALAN, "Alan", favorite=True),
    ALICE: person(ALICE, "Alice"),
    ALINA: person(ALINA, "Alina", hidden=True),
}


def _people(ids):
    return [PEOPLE[pid] for pid in ids]


# MARK: - Routes


@router.get("/api/people")
def people(req):
    """The paged list. `page` is ignored (one page); `withHidden=true` adds Alina."""
    if req.params.get("withHidden") == "true":
        listed = _people([ADA, ALAN, ALICE, ALINA])
    else:
        listed = _people([ADA, ALAN, ALICE])
    return Response({
        "people": listed,
        "hidden": 1,
        "total": len(listed),
        "hasNextPage": False,
    })


@router.prefix("GET", "/api/people/")
def one_person(req):
    """The drill-down's own reads and the row counts: statistics and the avatar.
    `None` for anything else, which falls through to the shell."""
    pid, _, tail = req.rest.partition("/")
    if pid not in PEOPLE:
        return None
    if tail == "statistics":
        return Response({"assets": COUNTS[pid]})
    if tail == "thumbnail":
        # A real PNG: the shell's `[]` here paints a broken avatar in every
        # screenshot of the drill-down.
        return Response(png(pid), ctype="image/png", headers={"Cache-Control": "no-store"})
    return None


@router.post("/api/search/metadata")
def person_faces(req):
    """The faces grid of the drill-down (`searchMetadata(personIds:)`).

    The shell acknowledges an unrouted POST with `{"successful": true}`, which
    fails to decode into `SearchResponseDto` and paints a red banner over the
    card. The three ids are the shell's own timeline assets, so their thumbnails
    resolve through `/api/assets/{id}/thumbnail`.
    """
    items = [asset(aid) for aid in TIMELINE_ASSETS[:3]]
    return Response({"assets": {"count": len(items), "items": items, "nextPage": None}})


@router.get("/api/search/person")
def search_person(req):
    """`GET /api/search/person?name=&withHidden=` — a bare array, no pagination."""
    name = req.params.get("name", "")
    with_hidden = req.params.get("withHidden") == "true"
    if name == "ali":
        return Response(_people([ALICE, ALAN, ALINA] if with_hidden else [ALICE, ALAN]))
    if name == "err":
        if not STATE["err_failed"]:
            STATE["err_failed"] = True
            return Response({"message": "STUB-500-BODY err",
                             "error": "Internal Server Error",
                             "statusCode": 500}, status=500)
        return Response(_people([ADA]))
    return Response([])


if __name__ == "__main__":
    main(label="people-search")
