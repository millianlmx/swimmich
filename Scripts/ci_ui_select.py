#!/usr/bin/env python3
"""Which lines of Scripts/ci-ui-scenarios.txt a run of Scripts/ci.sh executes.

    ci_ui_select.py --scope gate|core|all --list <file> [--base <git ref>]
                    [--capacity <lines>]

Prints the selected lines, in the order they run, one per line. Exit 2 when the
list is malformed or over its budgets.

A line has a tier:

* `--smoke`: every push runs it (the gate). One per critical journey.
* no flag: the core suite, every night. A journey, or the only execution proof
  of a criterion (nothing in the unit tests proves it).
* `--release`: the release suite only, once a week and on a release tag. A
  second proof of a criterion the unit tests already prove.

Scopes:

* `all`: every line (the release suite).
* `core`: every line but the `--release` ones (the night's suite).
* `gate`: the lines the push can have broken, then the smoke lines.

What a push can have broken, read against `--base`:

* a line new in the list, or edited (a change of tier alone is not an edit);
* a line whose test function changed in UITests/Scenarios/<Class>.swift. A change
  outside the test functions (a helper, the set-up) selects the class's lines but
  the `--release` ones; a change of comments alone selects nothing;
* a line whose stub changed, but the `--release` ones.

The gate runs at most `--capacity` lines, one per simulator the unit tests leave
free: a scenario never waits behind another, so the gate lasts as long as its
longest line, not as the sum of them. Changed lines come first, then the smoke
lines; what does not fit is left to the night's suite, with a warning when a
changed line is left.

Shared code (anything else under UITests/, `immich_stub_base.py`, Scripts/ci.sh,
this script) can break any line: the gate does not run them all, the night's
suite judges them.

Budgets (`SWIMMICH_CI_UI_SMOKE_MAX`, 5; `SWIMMICH_CI_UI_CORE_MAX`, 30): the gate
and the night's suite do not grow with every feature. A new scenario that does
not fit replaces a line, or is `--release`; its detailed criteria belong to the
unit tests (a whole screen is measured hosted, see Tests/HostedScreen.swift).
"""
import argparse
import os
import re
import subprocess
import sys

TIERS = ("--smoke", "--release")
SHARED = ("Scripts/ci.sh", "Scripts/ci_ui_select.py")
WHOLE = "whole class"

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
TEST = re.compile(r"^(\s*)func (test\w*)\(")


class ListError(Exception):
    pass


def parse_list(text):
    """The scenario lines, each a list of words, comments and blanks dropped."""
    lines = []
    for number, raw in enumerate(text.split("\n"), 1):
        words = raw.split("#", 1)[0].split()
        if not words:
            continue
        if len(words) < 2:
            raise ListError("line %d: a line is '<stub.py> <Class>[/<test>] [options]'" % number)
        if "--smoke" in words and "--release" in words:
            raise ListError("line %d: a line is --smoke or --release, not both" % number)
        lines.append(words)
    return lines


def tier(words):
    if "--smoke" in words:
        return "smoke"
    if "--release" in words:
        return "release"
    return "core"


def key(words):
    """A line without its tier: moving a line between tiers does not edit it."""
    return " ".join(word for word in words if word not in TIERS)


def check_budgets(lines, smoke_max, core_max):
    smoke = sum(1 for words in lines if tier(words) == "smoke")
    night = sum(1 for words in lines if tier(words) != "release")
    if smoke > smoke_max:
        raise ListError(
            "%d --smoke lines, over the budget of %d: the gate of every push must stay short. "
            "A new smoke line replaces one." % (smoke, smoke_max))
    if night > core_max:
        raise ListError(
            "%d lines in the night's suite (smoke and core), over the budget of %d. Mark a line "
            "--release (a criterion the unit tests already prove) or replace one; a detailed "
            "criterion belongs to the unit tests, not to a new scenario." % (night, core_max))


def test_spans(source):
    """(name, first line, last line) of each test function, lines counted from 1."""
    lines = source.split("\n")
    spans = []
    index = 0
    while index < len(lines):
        match = TEST.match(lines[index])
        if not match:
            index += 1
            continue
        closing = match.group(1) + "}"
        end = index
        while end < len(lines) and lines[end].rstrip() != closing:
            end += 1
        spans.append((match.group(2), index + 1, min(end, len(lines) - 1) + 1))
        index = end + 1
    return spans


def is_comment(text):
    stripped = text.strip()
    return not stripped or stripped.startswith("//")


def class_changes(diff, source):
    """What `git diff -U0` changed in a test class, given the class's new source.

    A set of test names (empty when only comments changed), or WHOLE when code
    outside the test functions changed.
    """
    spans = test_spans(source)
    lines = source.split("\n")

    def owner(number):
        for name, first, last in spans:
            if first <= number <= last:
                return name
        return None

    touched = set()
    hunks = []
    for raw in diff.split("\n"):
        match = HUNK.match(raw)
        if match:
            hunks.append([int(match.group(1)), int(match.group(2) or 1), []])
        elif hunks and raw[:1] in "+-" and not raw.startswith(("+++", "---")):
            hunks[-1][2].append(raw[1:])
    for start, count, body in hunks:
        if all(is_comment(text) for text in body):
            continue
        if count == 0:
            # Lines removed after line `start`: inside a test only when the lines
            # on both sides of the cut are that test's.
            name = owner(start)
            if name is None or owner(start + 1) != name:
                return WHOLE
            touched.add(name)
            continue
        for number in range(start, start + count):
            if number <= len(lines) and is_comment(lines[number - 1]):
                continue
            name = owner(number)
            if name is None:
                return WHOLE
            touched.add(name)
    return touched


def select(lines, scope, changed=(), base_keys=None, classes=None, log=None, capacity=None, warn=None):
    """Indices of the lines of `lines` the scope runs, in running order.

    `changed`: the paths the push changed. `base_keys`: `key()` of the base's
    lines. `classes`: for each changed class, `class_changes()`.
    """
    say = log or (lambda message: None)
    if scope == "all":
        return list(range(len(lines)))
    if scope == "core":
        return [index for index, words in enumerate(lines) if tier(words) != "release"]
    if scope != "gate":
        raise ListError("the scope is 'gate', 'core' or 'all'")

    base_keys = base_keys or set()
    classes = classes or {}
    shared = sorted(
        path for path in changed
        if path in SHARED
        or (path.startswith("UITests/") and not path.startswith("UITests/Scenarios/")
            and not (path.startswith("UITests/stubs/immich_stub_") and path != "UITests/stubs/immich_stub_base.py"))
    )
    stubs = {path.rsplit("/", 1)[1] for path in changed if path.startswith("UITests/stubs/immich_stub_")}

    touched = []
    for index, words in enumerate(lines):
        name, _, test = words[1].partition("/")
        change = classes.get(name)
        release = tier(words) == "release"
        if key(words) not in base_keys:
            touched.append(index)
        elif change == WHOLE or words[0] in stubs:
            if not release:
                touched.append(index)
        elif change and (not test or test in change):
            touched.append(index)
    smoke = [index for index, words in enumerate(lines) if tier(words) == "smoke" and index not in touched]
    if shared:
        say("shared UI-test code changed (%s): the gate runs the smoke lines, the night's suite judges the others"
            % ", ".join(shared[:5]))
    say("UI scope gate: %d changed line(s), then %d smoke line(s), of %d" % (len(touched), len(smoke), len(lines)))
    selected = touched + smoke
    if capacity is not None and len(selected) > capacity:
        capacity = max(capacity, 1)
        left = [lines[index][1] for index in touched[capacity:]]
        say("the gate runs %d line(s), one per free simulator: %d left to the night's suite"
            % (capacity, len(selected) - capacity))
        if left and warn:
            warn("the gate ran %d of the %d scenario lines this push changed, one per free simulator. "
                 "Not run: %s. Run them before merging (Run workflow, suite 'all'), or the night's suite will."
                 % (min(capacity, len(touched)), len(touched), ", ".join(left)))
        selected = selected[:capacity]
    return selected


def git(*arguments):
    return subprocess.run(("git",) + arguments, capture_output=True, text=True).stdout


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--scope", required=True)
    parser.add_argument("--list", required=True)
    parser.add_argument("--base")
    parser.add_argument("--capacity", type=int)
    options = parser.parse_args(argv)

    def log(message):
        print("ci.sh: " + message, file=sys.stderr)

    try:
        lines = parse_list(open(options.list).read())
        check_budgets(lines,
                      int(os.environ.get("SWIMMICH_CI_UI_SMOKE_MAX", "5")),
                      int(os.environ.get("SWIMMICH_CI_UI_CORE_MAX", "30")))
        changed, base_keys, classes = [], set(), {}
        if options.scope == "gate":
            if not options.base:
                raise ListError("the scope 'gate' needs --base")
            changed = [path for path in git("diff", "--name-only", options.base, "HEAD").split("\n") if path]
            base_keys = {key(words) for words in parse_list(git("show", options.base + ":" + options.list))}
            for path in changed:
                if path.startswith("UITests/Scenarios/") and path.endswith(".swift"):
                    name = path.rsplit("/", 1)[1][:-len(".swift")]
                    try:
                        source = open(path).read()
                    except OSError:
                        classes[name] = WHOLE
                        continue
                    classes[name] = class_changes(git("diff", "-U0", options.base, "HEAD", "--", path), source)
        selected = select(lines, options.scope, changed, base_keys, classes, log, options.capacity,
                          lambda message: print("::warning::" + message, file=sys.stderr))
    except ListError as error:
        # On stderr: ci.sh captures stdout (the selected lines), and GitHub reads
        # the annotation from either stream.
        print("::error::%s: %s" % (options.list, error), file=sys.stderr)
        return 2
    if options.scope != "gate":
        log("UI scope %s: %d of %d line(s)" % (options.scope, len(selected), len(lines)))
    for index in selected:
        print(" ".join(lines[index]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
