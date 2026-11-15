"""Tests of the Search captures chain: the job, the scenario/script agreement, the stub's city filter, the publication script."""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_readme import write_tool
from test_release_checks import job_blocks, read

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "UITests" / "stubs"))

import immich_stub_readme_screenshots as shots  # noqa: E402
from immich_stub_base import Request  # noqa: E402

STATES = ["home", "suggestions", "results", "filters-sheet", "no-results-filtered", "filtered", "selection"]


class TestSearchCapturesJob(unittest.TestCase):
    def test_AC_1_job_writes_only_its_series_branch(self):
        block = job_blocks(read(".github/workflows/ci.yml"))["search-captures"]
        for wanted in ("name: Search captures", "needs: unit-tests", "!cancelled()", "github.event_name == 'push'",
                       "contents: write", "${{ github.token }}", "run: Scripts/ci-search-captures.sh"):
            self.assertIn(wanted, block)
        self.assertNotIn("secrets.", block)
        self.assertNotIn("environment:", block)


class TestSearchCapturesFiles(unittest.TestCase):
    def test_AC_1_script_and_scenario_agree_on_the_states(self):
        script = read("Scripts/search-captures.sh")
        scenario = read("UITests/Scenarios/SearchCapturesUITests.swift")
        self.assertEqual(re.search(r"^NAMES=\((.+)\)$", script, re.M).group(1).split(), STATES)
        self.assertEqual(re.findall(r'try capture\("([\w-]+)"\)', scenario), STATES)
        self.assertIn("SearchCapturesUITests.swift in Sources", read("ImmichSwiftUI.xcodeproj/project.pbxproj"))


class TestSearchCapturesStub(unittest.TestCase):
    def test_AC_1_city_narrows_the_search(self):
        def found(**body):
            payload = shots.router.handle(Request("POST", "/api/search/smart", "", {}, body)).payload
            return [shots.photo_of(shots.number_of(a["id"]))[4] for a in payload["assets"]["items"]]

        quebec = found(query="nature", city="Québec")
        self.assertEqual(quebec, ["Québec"] * 6)
        self.assertEqual(found(query="nature", city="québec"), quebec)
        self.assertEqual(found(query="nature", city="Hong Kong"), [])
        self.assertEqual(len(found(query="nature")), 12)


@unittest.skipUnless(shutil.which("git") and shutil.which("bash"), "needs git and bash")
class TestSearchCapturesJobScript(unittest.TestCase):
    """Scripts/ci-search-captures.sh with a fake search-captures.sh and a local bare repository as the remote."""
    BOT = "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"
    BRANCH = "ci/search-captures-before"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.work = self.tmp / "work"
        (self.work / "Scripts").mkdir(parents=True)
        (self.work / "Sources").mkdir()
        shutil.copy2(ROOT / "Scripts" / "ci-search-captures.sh", self.work / "Scripts" / "ci-search-captures.sh")
        (self.work / "Scripts" / "search-captures-series").write_text("before\n", encoding="utf-8")
        (self.work / "Sources" / "a.swift").write_text("let a = 1\n", encoding="utf-8")
        names = " ".join(STATES)
        write_tool(self.work / "Scripts" / "search-captures.sh", f'''echo "$*" >> "$FAKE_CALLS"
case "$FAKE_MODE" in
  write)
    mkdir -p "build/search-captures/$1"
    for name in {names}; do
      printf 'png of %s' "$name" > "build/search-captures/$1/$1-$name.png"
      printf 'measure of %s' "$name" > "build/search-captures/$1/$1-$name.txt"
    done ;;
  fail)
    echo "search-captures.sh: the scenario failed" >&2; exit 1 ;;
esac
''')
        self.remote = self.tmp / "remote.git"
        self.calls = self.tmp / "calls.log"
        (self.tmp / "gitconfig").write_text(
            f'[url "file://{self.remote}"]\n\tinsteadOf = https://x-access-token:t0ken@github.com/owner/repo.git\n'
            "[user]\n\tuseConfigOnly = true\n", encoding="utf-8")  # no user.name: git cannot guess an identity
        subprocess.run(["git", "init", "--bare", "--quiet", str(self.remote)], check=True, env=self.env("none"))
        subprocess.run(["git", "init", "--quiet", str(self.work)], check=True, env=self.env("none"))
        self.commit_all("base")

    def env(self, mode, sha="abc123", ref="harness/x"):
        return {"PATH": os.environ["PATH"], "HOME": str(self.tmp),
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(self.tmp / "gitconfig"),
                "GITHUB_SHA": sha, "GITHUB_REF_NAME": ref, "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_TOKEN": "t0ken", "FAKE_CALLS": str(self.calls), "FAKE_MODE": mode}

    def commit_all(self, message):
        subprocess.run(["git", "-C", str(self.work), "add", "."], check=True, env=self.env("none"))
        subprocess.run(["git", "-C", str(self.work), "-c", "user.name=dev", "-c", "user.email=dev@example.com",
                        "commit", "--quiet", "-m", message], check=True, env=self.env("none"))

    def run_job(self, mode, **kwargs):
        return subprocess.run(["bash", "Scripts/ci-search-captures.sh"], cwd=self.work, env=self.env(mode, **kwargs),
                              capture_output=True, text=True, timeout=60)

    def git(self, *args, repo=None):
        done = subprocess.run(["git", "-C", str(repo or self.remote), *args], capture_output=True, check=True)
        return done.stdout.decode().strip()

    def branches(self):
        return self.git("for-each-ref", "--format=%(refname)").splitlines()

    def scripted_calls(self):
        return self.calls.read_text(encoding="utf-8").splitlines() if self.calls.exists() else []

    def notices(self, done):
        return [l for l in done.stdout.splitlines() if l.startswith("::notice title=Search captures::")]

    def test_AC_1_first_run_publishes_the_series(self):
        done = self.run_job("write")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.scripted_calls(), ["before"])
        self.assertEqual(self.branches(), [f"refs/heads/{self.BRANCH}"])
        tree = self.git("ls-tree", "-r", "--name-only", self.BRANCH).splitlines()
        self.assertEqual(sorted(tree), sorted(["SOURCE.txt"] + [f"before-{s}.{e}" for s in STATES for e in ("png", "txt")]))
        sources = self.git("rev-parse", "HEAD:Sources", repo=self.work)
        self.assertEqual(self.git("show", f"{self.BRANCH}:SOURCE.txt"), f"abc123 harness/x\nsources {sources}")
        self.assertEqual(self.git("show", f"{self.BRANCH}:before-home.png"), "png of home")
        self.assertEqual(self.git("log", "-1", "--format=%an <%ae>|%cn <%ce>", self.BRANCH), f"{self.BOT}|{self.BOT}")
        pushed = self.git("rev-parse", self.BRANCH)
        self.assertTrue(any(pushed in n for n in self.notices(done)), done.stdout)
        self.assertNotIn("t0ken", done.stdout + done.stderr)

    def test_AC_1_same_sha_is_not_taken_again(self):
        self.assertEqual(self.run_job("write").returncode, 0)
        before = self.git("rev-parse", self.BRANCH)
        done = self.run_job("write")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.scripted_calls(), ["before"])
        self.assertEqual(self.git("rev-parse", self.BRANCH), before)

    def test_AC_1_owner_retakes_on_a_new_sha(self):
        self.assertEqual(self.run_job("write").returncode, 0)
        done = self.run_job("write", sha="def456")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.scripted_calls(), ["before", "before"])
        self.assertTrue(self.git("show", f"{self.BRANCH}:SOURCE.txt").startswith("def456 harness/x\n"))

    def test_AC_1_before_series_is_never_retaken_on_changed_sources(self):
        self.assertEqual(self.run_job("write").returncode, 0)
        before = self.git("rev-parse", self.BRANCH)
        (self.work / "Sources" / "a.swift").write_text("let a = 2\n", encoding="utf-8")
        self.commit_all("redesign")
        done = self.run_job("write", sha="def456")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.scripted_calls(), ["before"])
        self.assertEqual(self.git("rev-parse", self.BRANCH), before)
        self.assertTrue(any("frozen on Sources" in n for n in self.notices(done)), done.stdout)

    def test_AC_1_another_branch_never_replaces_the_series(self):
        self.assertEqual(self.run_job("write").returncode, 0)
        before = self.git("rev-parse", self.BRANCH)
        done = self.run_job("write", sha="def456", ref="main")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.scripted_calls(), ["before"])
        self.assertEqual(self.git("rev-parse", self.BRANCH), before)
        self.assertTrue(any("harness/x" in n for n in self.notices(done)), done.stdout)

    def test_AC_1_capture_failure_is_reported_without_pushing(self):
        done = self.run_job("fail")
        self.assertEqual(done.returncode, 1)
        lines = done.stdout.splitlines()
        first = "::error title=Search captures::Scripts/search-captures.sh exited 1"
        second = "::error title=Search captures::search-captures.sh: the scenario failed"
        self.assertIn(first, lines)
        self.assertIn(second, lines)
        self.assertLess(lines.index(first), lines.index(second))
        self.assertEqual(self.branches(), [])

    def test_AC_1_unknown_series_fails_before_capturing(self):
        (self.work / "Scripts" / "search-captures-series").write_text("later\n", encoding="utf-8")
        done = self.run_job("write")
        self.assertEqual(done.returncode, 1)
        self.assertIn("::error title=Search captures::Scripts/search-captures-series must say before or after, not 'later'",
                      done.stdout.splitlines())
        self.assertEqual(self.scripted_calls(), [])
        self.assertEqual(self.branches(), [])


if __name__ == "__main__":
    unittest.main()
