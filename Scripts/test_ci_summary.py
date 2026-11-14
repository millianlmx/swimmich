"""Tests of Scripts/ci_summary.py: the positive trace (a `notice`) of a run of Scripts/ci.sh."""
import json
import os
import tempfile
import unittest

import ci_summary as summary


def counts(passed=0, failed=0, skipped=0, **extra):
    return json.dumps(dict(passedTests=passed, failedTests=failed, skippedTests=skipped, **extra))


class CiSummaryTests(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.dir = self._dir.name

    def write(self, name, label, body=""):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(label + "\n" + body)
        return path

    def jobs(self, *paths):
        return [job for job in map(summary.read_job, paths) if job is not None]

    def test_AC_195_2_eachJobIsNamedWithItsCounts(self):
        unit = self.write("job-0.summary", "unit tests", counts(812))
        scenario = self.write(
            "job-3.summary", "AssetEditsUITests/test_AC_192_editMadeBeforeShowsOnEverySurface", counts(1))
        out = summary.notices("all", self.jobs(unit, scenario))
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0].startswith("::notice::ci.sh results, scope all, part 1/1, 2 job(s)"), out[0])
        self.assertIn("%0Aunit tests: 812 passed, 0 failed, 0 skipped", out[0])
        self.assertIn(
            "%0AAssetEditsUITests/test_AC_192_editMadeBeforeShowsOnEverySurface: 1 passed, 0 failed, 0 skipped",
            out[0])

    def test_AC_195_2_failedAndSkippedAreReported(self):
        path = self.write("job-1.summary", "AlphaUITests/test_x", counts(0, 1, 1))
        out = summary.notices("core", self.jobs(path))
        self.assertIn("AlphaUITests/test_x: 0 passed, 1 failed, 1 skipped", out[0])

    def test_AC_195_2_missingSummaryIsNamed(self):
        bare = self.write("job-1.summary", "AlphaUITests/test_bare")
        cut = self.write("job-2.summary", "AlphaUITests/test_cut", '{"passed')
        empty = os.path.join(self.dir, "job-3.summary")
        open(empty, "w").close()
        notes = self.write("notes.txt", "stray label", counts(9))
        out = summary.notices("gate", self.jobs(bare, cut, empty, notes, os.path.join(self.dir, "job-4.summary")))
        self.assertEqual(len(out), 1)
        self.assertIn("2 job(s)", out[0])
        self.assertIn("%0AAlphaUITests/test_bare: no test summary", out[0])
        self.assertIn("%0AAlphaUITests/test_cut: no test summary", out[0])
        self.assertNotIn("stray label", out[0])

    def test_AC_195_2_failedTestsAreNamed(self):
        failures = [{"testIdentifierString": "T%d()" % n} for n in range(1, 8)]
        path = self.write("job-0.summary", "unit tests", counts(800, 7, 0, testFailures=failures))
        out = summary.notices("gate", self.jobs(path))
        self.assertIn(
            "unit tests: 800 passed, 7 failed, 0 skipped (failed: T1(), T2(), T3(), T4(), T5(), … 2 more)", out[0])

    def test_AC_195_2_failureWithoutIdentifierFallsBackToItsName(self):
        path = self.write("job-0.summary", "unit tests",
                          counts(1, 1, 0, testFailures=[{"testName": "testA()"}]))
        self.assertEqual(summary.read_job(path)[3], ["testA()"])

    def test_AC_195_2_jobsAreOrderedByIndex(self):
        paths = [self.write("job-%d.summary" % n, "label%d" % n, counts(1)) for n in (10, 2, 0)]
        out = summary.notices("all", self.jobs(*paths))[0]
        self.assertLess(out.index("label0:"), out.index("label2:"))
        self.assertLess(out.index("label2:"), out.index("label10:"))

    def test_AC_195_2_labelsAreEscaped(self):
        path = self.write("job-1.summary", "a%b", counts(1))
        out = summary.notices("all", self.jobs(path))[0]
        self.assertIn("a%25b: 1 passed", out)
        self.assertNotIn("\n", out)
        self.assertEqual(summary.escape("x\r\ny%"), "x%0D%0Ay%25")

    def test_AC_195_2_longRunsAreSplitUnderTheCap(self):
        def run(total):
            jobs = [(n, "job%d" % n, (1, 0, 0), []) for n in range(total)]
            return summary.notices("all", jobs, per_notice=50)

        out = run(120)
        self.assertEqual(len(out), 3)
        for number, notice in enumerate(out, 1):
            self.assertTrue(notice.startswith("::notice::ci.sh results, scope all, part %d/3, 120 job(s)" % number))
        for n in range(120):
            self.assertEqual(sum(("%0A" + "job%d:" % n) in notice for notice in out), 1, n)

        out = run(600)
        self.assertEqual(len(out), 10)
        self.assertTrue(out[-1].endswith("%0A… 100 more job(s) not listed"), out[-1][-80:])

    def test_AC_195_2_noJobStillReports(self):
        out = summary.notices("gate", self.jobs(os.path.join(self.dir, "job-*.summary")))
        self.assertEqual(out, ["::notice::ci.sh results, scope gate, part 1/1, 0 job(s)"])


if __name__ == "__main__":
    unittest.main()
