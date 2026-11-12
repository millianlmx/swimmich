"""Tests of the version and route logic of the stub shell (L-20).

`UITests/stubs/immich_stub_base.py` announces `IMMICH_STUB_VERSION` and refuses
(404, journaled) a replacement route its version does not have. The stubs that
prove "never a route this server does not serve" stand on it, so the table is
tested here, on a real `StubHandler` served on port 0:

    python3 -m unittest discover -s Scripts -p 'test_stub_routes.py'

Only the shell is covered. The self-contained stubs and
`immich_stub_route_compat.py` are exercised by `RouteCompatUITests` alone.
"""
import importlib.util
import json
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
STUBS = ROOT / "UITests" / "stubs"


def _load_base():
    spec = importlib.util.spec_from_file_location("immich_stub_base", STUBS / "immich_stub_base.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["immich_stub_base"] = module
    spec.loader.exec_module(module)
    return module


base = _load_base()
CONTRACT = json.loads((STUBS / "route_payloads.json").read_text())

VERSIONS = [(2, 0, 0), (2, 3, 9), (2, 4, 0), (3, 1, 0), (3, 2, 0), (3, 2, 1), (3, 4, 0), None]
QUEUE = "thumbnailGeneration"


class StubRoutesTests(unittest.TestCase):
    def setUp(self):
        for patcher in (mock.patch.object(base, "router", base.Router()),
                        mock.patch.object(base, "SERVER_VERSION", "3.4.0")):
            patcher.start()
            self.addCleanup(patcher.stop)
        base._reset()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), base.StubHandler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    # MARK: - Helpers

    def call(self, method, path, body=None):
        """`(status, decoded JSON or the raw bytes when empty / not JSON)`."""
        url = f"http://127.0.0.1:{self.server.server_address[1]}{path}"
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            url, data=data, method=method, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                status, raw = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read()
        try:
            return status, json.loads(raw)
        except ValueError:
            return status, raw

    def at_version(self, version):
        patcher = mock.patch.object(base, "SERVER_VERSION", version)
        patcher.start()
        self.addCleanup(patcher.stop)

    def stats(self):
        return dict(self.call("GET", "/api/queues")[1][0]["statistics"])

    def is_paused(self):
        return self.call("GET", "/api/queues")[1][0]["isPaused"]

    # MARK: - AC-35

    def test_AC_35_payloadsMatchContract(self):
        modern = CONTRACT["3.4.0"]
        self.assertEqual(self.call("GET", "/api/public/config"), (200, modern["publicConfig"]))
        self.assertEqual(self.call("GET", "/api/config"), (200, modern["userConfig"]))
        self.assertEqual(self.call("GET", "/api/queues"), (200, modern["queues"]))

        self.at_version("2.0.0")
        legacy = CONTRACT["2.0.0"]
        self.assertEqual(self.call("GET", "/api/server/config"), (200, legacy["serverConfig"]))
        self.assertEqual(self.call("GET", "/api/jobs"), (200, legacy["jobs"]))

    def test_AC_35_versionEndpointFollowsEnvironmentValue(self):
        self.at_version("2.0.0")
        status, body = self.call("GET", "/api/server/version")
        self.assertEqual(status, 200)
        self.assertEqual((body["major"], body["minor"], body["patch"]), (2, 0, 0))

    # MARK: - AC-36

    def test_AC_36_servesPerThreshold(self):
        for version in VERSIONS:
            for method, pattern, minimum in base.ROUTE_TABLE:
                path = pattern.replace("{name}", "x")
                expected = version is not None and version >= minimum
                self.assertEqual(base.serves(method, path, version), expected,
                                 f"{method} {path} at {version}")
            # The routes every supported version has are never refused.
            for method, path in [("GET", "/api/jobs"), ("PUT", "/api/jobs/x"),
                                 ("GET", "/api/server/config"), ("POST", "/api/people/x/merge")]:
                self.assertTrue(base.serves(method, path, version), f"{method} {path} at {version}")
        self.assertFalse(base.serves("POST", "/api/people/merge", (3, 2, 0)))
        self.assertTrue(base.serves("POST", "/api/people/x/merge", (3, 2, 0)))
        self.assertTrue(base.serves("POST", "/api/people/merge", (3, 2, 1)))

    def test_AC_36_announcedVersion(self):
        request = base.Request("GET", "/api/server/version", "", {}, {})
        self.assertEqual(base.announced_version(request), (3, 4, 0), "SERVER_VERSION without a route")

        def with_route(response):
            router = base.Router()
            router.get("/api/server/version")(lambda req: response)
            return mock.patch.object(base, "router", router)

        with with_route(base.Response({"major": 2, "minor": 5, "patch": 1})):
            self.assertEqual(base.announced_version(request), (2, 5, 1), "the router wins")
        with with_route(base.Response({"error": "down"}, status=500)):
            self.assertIsNone(base.announced_version(request))
        with with_route(base.Response({"unexpected": True})):
            self.assertIsNone(base.announced_version(request))
        with with_route(base.Response(b"not json", ctype="text/plain")):
            self.assertIsNone(base.announced_version(request))

    def test_AC_36_unservedRouteIs404AndLogged(self):
        self.at_version("2.0.0")
        for method, path in [("GET", "/api/queues"), ("GET", "/api/public/config"),
                             ("POST", "/api/people/merge")]:
            status, body = self.call(method, path, {} if method == "POST" else None)
            self.assertEqual(status, 404, f"{method} {path}")
            self.assertEqual(body, {"message": f"Cannot {method} {path}", "statusCode": 404})
        logged = {(entry["method"], entry["path"]) for entry in self.call("GET", "/__requests")[1]}
        self.assertTrue({("GET", "/api/queues"), ("GET", "/api/public/config"),
                         ("POST", "/api/people/merge")} <= logged)

        self.at_version("3.4.0")
        self.assertEqual(self.call("GET", "/api/queues")[0], 200)
        self.assertEqual(self.call("POST", "/api/people/merge", {"ids": ["c", "a"]})[0], 200)

    def test_AC_36_queueCommandEffects(self):
        # pause / resume, through both families.
        self.assertFalse(self.is_paused())
        self.assertEqual(self.call("PUT", f"/api/queues/{QUEUE}", {"isPaused": True})[0], 200)
        self.assertTrue(self.is_paused())
        self.assertTrue(self.call("GET", "/api/jobs")[1][QUEUE]["queueStatus"]["isPaused"])
        self.call("PUT", f"/api/jobs/{QUEUE}", {"command": "resume"})
        self.assertFalse(self.is_paused())
        self.call("PUT", f"/api/jobs/{QUEUE}", {"command": "pause"})
        self.assertTrue(self.is_paused())
        self.call("PUT", f"/api/queues/{QUEUE}", {"isPaused": False})
        self.assertFalse(self.is_paused())

        # start changes nothing.
        before = self.stats()
        self.assertEqual(self.call("PUT", f"/api/jobs/{QUEUE}", {"command": "start", "force": True})[0], 200)
        self.assertEqual(self.stats(), before)
        self.assertFalse(self.is_paused())

        # empty clears waiting and delayed, and only those.
        live = base.STATE["queues"][QUEUE]["statistics"]
        live.update(failed=5, delayed=2)
        self.call("PUT", f"/api/jobs/{QUEUE}", {"command": "empty"})
        self.assertEqual((self.stats()["waiting"], self.stats()["delayed"], self.stats()["failed"]), (0, 0, 5))

        # clear-failed clears failed and leaves what waits.
        live.update(waiting=3)
        self.call("PUT", f"/api/jobs/{QUEUE}", {"command": "clear-failed"})
        self.assertEqual((self.stats()["failed"], self.stats()["waiting"]), (0, 3))

        # DELETE /queues/{name}/jobs: 204 with an empty body; failed only on request.
        live.update(failed=4, delayed=1)
        status, body = self.call("DELETE", f"/api/queues/{QUEUE}/jobs", {})
        self.assertEqual((status, body), (204, b""))
        self.assertEqual((self.stats()["waiting"], self.stats()["delayed"], self.stats()["failed"]), (0, 0, 4))
        live.update(waiting=2)
        self.call("DELETE", f"/api/queues/{QUEUE}/jobs", {"failed": True})
        self.assertEqual((self.stats()["waiting"], self.stats()["failed"]), (0, 0))

        # Refusals.
        self.assertEqual(self.call("PUT", "/api/jobs/nope", {"command": "pause"})[0], 400)
        self.assertEqual(self.call("PUT", f"/api/jobs/{QUEUE}", {"command": "explode"})[0], 400)
        self.assertEqual(self.call("PUT", "/api/queues/backgroundTask", {"isPaused": True})[0], 400)
        self.assertEqual(self.call("PUT", "/api/queues/nope", {"isPaused": True})[0], 400)
        self.assertEqual(self.call("DELETE", "/api/queues/nope/jobs", {})[0], 400)

    # MARK: - AC-174

    def test_AC_174_mergeRoutesAnswerEachSource(self):
        self.assertEqual(self.call("POST", "/api/people/merge", {"ids": ["c", "a", "b"]}),
                         (200, [{"id": "a", "success": True}, {"id": "b", "success": True}]))
        self.assertEqual(self.call("POST", "/api/people/c/merge", {"ids": ["a", "b"]}),
                         (200, [{"id": "a", "success": True}, {"id": "b", "success": True}]))


if __name__ == "__main__":
    unittest.main()
