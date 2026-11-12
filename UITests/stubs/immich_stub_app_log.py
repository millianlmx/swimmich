"""Immich API stub for the "log without secrets" scenario (`AppLogRedactionUITests`).

    python3 UITests/stubs/immich_stub_app_log.py 8421

    .omp/orchestration/uitest.sh <worktree> /tmp/app-log.uitest.log \\
        UITests/stubs/immich_stub_app_log.py \\
        AppLogRedactionUITests/test_AC_130_listDetailAndClipboardCarryNoAddressNorToken --erase

WHAT THIS STUB IS FOR

The app log keeps the PATH of each request. On an installation served under a
sub-path (`https://host/immich`), that path is `/immich/api/assets/statistics`:
the sub-path is part of the server's address, and the log must not keep it. This
stub serves the whole API under `/immich`, so the scenario can prove it is the
masking — not the absence of something to mask — that keeps it out of the log:

* `/immich/<path>` is noted in `RAW_PATHS` (the path as the app sent it, without
  its query), then served as if the request had been for `<path>`: the feature
  routes first, then the shell's. `GET /control/raw-paths` returns that list, so
  the scenario can first assert that the raw line DID carry `/immich`.
* `/__…`, `/provider-…` and `/control/…` are answered as they are.
* Any other path — `/api/…` without `/immich` included — is a 404: a request
  that forgot the sub-path is a bug of the app, not something to serve.

TWO MORE ROUTES

* `POST /api/oauth/callback` hands the app a recognisable access token.
* `GET /api/assets/statistics` answers counters, or — once `GET /control/drop?on=1`
  armed it — RAISES inside the handler: the base's `_dispatch` does not protect a
  handler, so the connection closes without a response and the app gets a
  transport error (a connection lost), the one outcome that makes the app log a
  thrown failure with a DETAILS and a STACK TRACE block. `?on=0` disarms it.

That transport error does not quote the address nor the token (a lost connection
carries no URL). That half of the claim is proved by the unit tests, on the real
buffer; this scenario proves the chain screen → detail → clipboard on a real
failure, and that the sub-path never shows.

The control routes are not under `/__` (the shell answers those itself, before
the feature router is consulted).
"""
import immich_stub_base as base
from immich_stub_base import LOGIN, Response, STATE, main, router

# `AppLogRedactionUITests.token` is the other half of this contract.
TOKEN = "stub-applog-token-5c1e7a20"

DROP = "statistics_dropped"
RAW = "raw_paths"

STATE.setdefault(DROP, False)
STATE.setdefault(RAW, [])

ASSET_STATS = {"images": 4242, "videos": 7317, "total": 11559}

_SUBPATH = "/immich"
_original_dispatch = base.StubHandler._dispatch


def _dispatch(self, method):
    """Serves `/immich/<path>` as `<path>`; answers 404 to the rest."""
    path, sep, query = self.path.partition("?")
    if path.startswith("/__") or path.startswith("/provider-") or path.startswith("/control/"):
        return _original_dispatch(self, method)
    if path.startswith(_SUBPATH + "/"):
        STATE[RAW].append(path)
        self.path = path[len(_SUBPATH):] + sep + query
        return _original_dispatch(self, method)
    return self._send(Response({"error": "not found", "path": path}, status=404))


base.StubHandler._dispatch = _dispatch


@router.reset
def fresh():
    STATE[DROP] = False
    STATE[RAW] = []


@router.post("/api/oauth/callback")
def sign_in(req):
    return Response({**LOGIN, "accessToken": TOKEN})


@router.get("/control/drop")
def control_drop(req):
    """Arms (`on=1`) or disarms (`on=0`) the dropped connection."""
    STATE[DROP] = req.params.get("on") == "1"
    return Response({"drop": STATE[DROP]})


@router.get("/control/raw-paths")
def control_raw_paths(req):
    """The paths the app really sent, sub-path included, queries removed."""
    return Response(STATE[RAW])


@router.get("/api/assets/statistics")
def statistics(req):
    if STATE[DROP]:
        # Not caught on purpose: the connection closes with no response.
        raise RuntimeError("stub: connection dropped on purpose")
    return Response(ASSET_STATS)


if __name__ == "__main__":
    main(label="app-log")
