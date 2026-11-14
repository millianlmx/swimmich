#!/usr/bin/env python3
"""The positive trace of a run of Scripts/ci.sh: one GitHub `notice` naming every job it ran.

    ci_summary.py --scope gate|core|all <build/ci/job-N.summary>...

Prints one or more `::notice::<message>` lines on stdout and always exits 0: the
trace never changes the verdict of the run.

Why: the CI of the forge annotates a failure, a skipped scenario or a slow test,
and nothing else. A scenario that passed and a scenario that never ran leave the
same absence of trace, and the job logs and artifacts are not readable without
admin rights. An annotation is: it is the only proof, readable from outside, that
a test was seen passing.

A job file `job-<k>.summary` (k = 0 for the unit tests, k = the line's index in the
pool otherwise) holds, on its first non-empty line, the job's label (`unit tests`,
or the `<Class>[/<test>]` selector of its line), then the raw JSON printed by
`xcrun xcresulttool get test-results summary`, possibly empty. A file that is
absent, empty, or not named `job-<digits>.summary` (the literal pattern bash leaves
when nothing matches) is ignored. A job with a label but no readable JSON is
reported as `no test summary`.

GitHub caps annotations at 10 per severity and per step, and CI runs in one step:
`notices` packs 50 jobs per annotation and stops at 10 annotations.
"""
import argparse
import json
import os
import re
import sys

NAME = re.compile(r"^job-(\d+)\.summary$")
MAX_NAMED_FAILURES = 5
MAX_NOTICES = 10


def read_job(path):
    """(index, label, counts, failed) of a job file, or None when the file is ignored.

    counts is (passed, failed, skipped), or None when the JSON is empty or unreadable;
    failed lists the identifiers of the failed tests, in order.
    """
    match = NAME.match(os.path.basename(path))
    if not match:
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return None
    position = next((i for i, line in enumerate(lines) if line.strip()), None)
    if position is None:
        return None
    label = lines[position].strip()
    try:
        summary = json.loads("\n".join(lines[position + 1:]))
    except ValueError:
        summary = None
    if not isinstance(summary, dict):
        return int(match.group(1)), label, None, []
    counts = tuple(int(summary.get(key) or 0) for key in ("passedTests", "failedTests", "skippedTests"))
    failed = []
    for failure in summary.get("testFailures") or []:
        if isinstance(failure, dict):
            name = failure.get("testIdentifierString") or failure.get("testName")
            if name:
                failed.append(str(name))
    return int(match.group(1)), label, counts, failed


def job_line(label, counts, failed=()):
    """`<label>: <P> passed, <F> failed, <S> skipped`, with the first failed names when there are some."""
    if counts is None:
        return "%s: no test summary" % label
    line = "%s: %d passed, %d failed, %d skipped" % (label, *counts)
    failed = list(failed)
    if failed:
        names = failed[:MAX_NAMED_FAILURES]
        if len(failed) > len(names):
            names.append("… %d more" % (len(failed) - len(names)))
        line += " (failed: %s)" % ", ".join(names)
    return line


def escape(text):
    """The escaping GitHub applies to the data of a workflow command."""
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def notices(scope, jobs, per_notice=50):
    """The `::notice::` lines for jobs, a list of read_job results, ordered by index."""
    ordered = sorted(jobs, key=lambda job: job[0])
    lines = [escape(job_line(label, counts, failed)) for _, label, counts, failed in ordered]
    packs = [lines[i:i + per_notice] for i in range(0, len(lines), per_notice)] or [[]]
    hidden = 0
    if len(packs) > MAX_NOTICES:
        hidden = sum(len(pack) for pack in packs[MAX_NOTICES:])
        packs = packs[:MAX_NOTICES]
    out = []
    for number, pack in enumerate(packs, 1):
        parts = list(pack)
        if hidden and number == len(packs):
            parts.append("… %d more job(s) not listed" % hidden)
        head = "::notice::ci.sh results, scope %s, part %d/%d, %d job(s)" % (
            escape(scope), number, len(packs), len(lines))
        out.append("%0A".join([head] + parts))
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--scope", required=True)
    parser.add_argument("files", nargs="*")
    args = parser.parse_args(argv)
    jobs = [job for job in map(read_job, args.files) if job is not None]
    for line in notices(args.scope, jobs):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
