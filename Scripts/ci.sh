#!/usr/bin/env bash
# The CI of swimmich, runnable as is on any Mac with Xcode and XcodeGen.
#
#   Scripts/ci.sh
#
# 0. Runs the Python tests of the i18n audit (Scripts/test_*.py), then, after
#    XcodeGen, the audit itself (R1-R4); its verdict is applied at the end, so
#    one pass judges the audit and the tests.
# 1. Regenerates the project from project.yml: the committed .xcodeproj drifts,
#    and a Tests/*.swift file missing from it would pass "green" by omission.
# 2. Builds the app, its extensions and BOTH test bundles (the UI scenarios are
#    compiled, not run: each needs its own Python stub, see UITests/stubs/).
# 3. Runs the unit tests (ImmichSwiftUITests) on a dedicated simulator,
#    `swimmich-ci`, created on first use so the CI never boots the developer's.
#
# DerivedData and SwiftPM checkouts live in a persistent cache: on the
# self-hosted runner, a run only rebuilds what the commit changed.
set -euo pipefail
cd "$(dirname "$0")/.."

# The Python tests of the audit script (R4) come first: no build, a few seconds.
# Each failed test becomes a public `::error` annotation (see report_errors).
python_log="$(mktemp)"
if ! python3 -m unittest discover -s Scripts -p 'test_*.py' >"$python_log" 2>&1; then
  cat "$python_log" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    grep -E '^(FAIL|ERROR):' "$python_log" | while IFS= read -r line; do
      echo "::error::${line//%/%25}"
    done || true
  fi
  rm -f "$python_log"
  exit 1
fi
rm -f "$python_log"

CACHE="${SWIMMICH_CI_CACHE:-$HOME/Library/Caches/swimmich-ci}"
SIM_NAME="${SWIMMICH_CI_SIM:-swimmich-ci}"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
RESULT="${SWIMMICH_CI_RESULT:-build/ci/unit-tests.xcresult}"

xcodegen generate --quiet

# The i18n audit (R1-R4, a virgin extraction build of about 40 s) reads the
# .xcodeproj regenerated above. Its status is remembered, not acted on: the
# build and the tests still run, and the verdict is applied at the very end.
# The offending lines become public `::error` annotations, because the job log
# is only readable by repository admins.
audit_log="$(mktemp)"
audit_status=0
python3 Scripts/i18n-audit.py --derived-data "$CACHE/i18n-audit-DerivedData" >"$audit_log" 2>&1 || audit_status=$?
cat "$audit_log"
if (( audit_status != 0 )); then
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    grep -E '^  - ' "$audit_log" | while IFS= read -r line; do
      line="${line#  - }"
      echo "::error title=i18n-audit::${line//%/%25}"
    done || true
    echo "::error::i18n-audit exited $audit_status"
  fi
fi

udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["name"] == name:
            print(device["udid"])
            raise SystemExit
' "$SIM_NAME")
if [[ -z "$udid" ]]; then
  # The newest installed iOS runtime that Xcode can drive.
  runtime=$(xcrun simctl list runtimes available -j | python3 -c '
import json, sys
ios = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS"]
ios.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(ios[-1]["identifier"] if ios else "")
')
  [[ -n "$runtime" ]] || { echo "ci.sh: no iOS simulator runtime installed" >&2; exit 2; }
  udid=$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" "$runtime")
fi
echo "ci.sh: simulator $SIM_NAME ($udid)"
# Booted (and waited for) up front: a cold device handed to xcodebuild can fail
# with "Invalid device state" before the first test.
xcrun simctl bootstatus "$udid" -b >/dev/null

common=(
  -project ImmichSwiftUI.xcodeproj
  -scheme ImmichSwiftUI
  -destination "platform=iOS Simulator,id=$udid"
  -derivedDataPath "$CACHE/DerivedData"
  -clonedSourcePackagesDirPath "$CACHE/SourcePackages"
)

# Signed for the simulator on purpose: CODE_SIGNING_ALLOWED=NO drops the
# keychain-sharing entitlements, and the session-store tests then read nil.
# The persistent DerivedData can be left inconsistent by an earlier run (the
# build then dies with "failed with exit code 0 but produced no further
# output" and no usable diagnostic). On failure: report the compiler errors,
# purge that cache and build once more; a genuine source error fails twice.
#
# Compiler errors are reported as `file:line:col: error:` lines and, on
# GitHub Actions, as `::error` annotations: the job log is only readable by
# repository admins, whereas annotations are public (check-run API). Source
# excerpts that merely contain the word "error" (`error: &error`) are skipped.
report_errors() {
  local log="$1" root="$PWD/" message
  grep -E '^[^ ].*:[0-9]+:([0-9]+:)? error: |^error: ' "$log" | grep -v 'produced no further output' | sort -u |
    while IFS= read -r line; do
      echo "$line" >&2
      [[ -n "${GITHUB_ACTIONS:-}" ]] || continue
      if [[ "$line" =~ ^([^:]+):([0-9]+):([0-9]+:)?\ error:\ (.*)$ ]]; then
        message="${BASH_REMATCH[4]//%/%25}"
        echo "::error file=${BASH_REMATCH[1]#"$root"},line=${BASH_REMATCH[2]}::$message"
      else
        message="${line#error: }"
        echo "::error::${message//%/%25}"
      fi
    done || true
}

build_log="$(mktemp)"
trap 'rm -f "$build_log" "$python_log" "$audit_log"' EXIT
if ! xcodebuild build-for-testing "${common[@]}" -quiet 2>&1 | tee "$build_log"; then
  echo "ci.sh: build failed; compiler errors of the first attempt:" >&2
  report_errors "$build_log"
  echo "ci.sh: purging $CACHE/DerivedData and building again" >&2
  rm -rf "$CACHE/DerivedData"
  if ! xcodebuild build-for-testing "${common[@]}" 2>&1 | tee "$build_log"; then
    echo "ci.sh: clean build failed too; compiler errors:" >&2
    report_errors "$build_log"
    exit 65
  fi
fi

# A test failure leaves nothing readable in the public log either (the log is
# admin-only), so the failed tests are read back from the result bundle and
# reported like compiler errors: one `::error` annotation per failed test.
report_failed_tests() {
  local summary
  summary="$(xcrun xcresulttool get test-results summary --path "$RESULT" 2>/dev/null)" || summary=""
  [[ -n "$summary" ]] || { echo "ci.sh: no test summary in $RESULT" >&2; return 0; }
  printf '%s' "$summary" | python3 -c '
import json, sys
try:
    failures = json.load(sys.stdin).get("testFailures") or []
except Exception as error:
    print("::error::ci.sh: unreadable test summary: %s" % error)
    raise SystemExit
print("ci.sh: %d failed test(s)" % len(failures), file=sys.stderr)
if not failures:
    print("::error::the test run failed without a failed test (crash of the test host?)")
for failure in failures[:10]:
    name = failure.get("testIdentifierString") or failure.get("testName") or "?"
    text = " ".join(str(failure.get("failureText", "")).split())
    message = ("%s: %s" % (name, text)).replace("%", "%25")
    print("::error::" + message)
    print("ci.sh: FAILED " + name + ": " + text, file=sys.stderr)
'
}

rm -rf "$RESULT"
mkdir -p "$(dirname "$RESULT")"
if ! xcodebuild test-without-building "${common[@]}" -quiet \
  -only-testing:ImmichSwiftUITests \
  -resultBundlePath "$RESULT"; then
  report_failed_tests
  exit 65
fi

# The i18n audit ran first (it only reads the catalog and the sources); its
# verdict is applied last so one pass judges the audit AND the tests.
if (( audit_status != 0 )); then
  echo "ci.sh: i18n audit failed (exit $audit_status)" >&2
  exit 1
fi
