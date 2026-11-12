#!/usr/bin/env bash
# The CI of swimmich, runnable as is on any Mac with Xcode and XcodeGen.
#
#   Scripts/ci.sh
#
# 1. Regenerates the project from project.yml: the committed .xcodeproj drifts,
#    and a Tests/*.swift file missing from it would pass "green" by omission.
# 2. Builds the app, its extensions and BOTH test bundles.
# 3. Runs the unit tests (ImmichSwiftUITests) on a dedicated simulator,
#    `swimmich-ci`, created on first use so the CI never boots the developer's.
# 4. Runs the UI scenarios listed in Scripts/ci-ui-scenarios.txt, each against
#    its own Python stub from UITests/stubs/ (the scenarios not listed there are
#    compiled, not run). A scenario that skips itself fails the CI: a skip only
#    means its stub was unreachable, which proves nothing.
#
# DerivedData and SwiftPM checkouts live in a persistent cache: on the
# self-hosted runner, a run only rebuilds what the commit changed.
set -euo pipefail
cd "$(dirname "$0")/.."

CACHE="${SWIMMICH_CI_CACHE:-$HOME/Library/Caches/swimmich-ci}"
SIM_NAME="${SWIMMICH_CI_SIM:-swimmich-ci}"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
RESULT="${SWIMMICH_CI_RESULT:-build/ci/unit-tests.xcresult}"

xcodegen generate --quiet

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
media_dir="$(mktemp -d)"
stub_pid=""
cleanup() {
  rm -f "$build_log"
  rm -rf "$media_dir"
  if [[ -n "$stub_pid" ]]; then kill "$stub_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
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
  local result="$1" summary
  summary="$(xcrun xcresulttool get test-results summary --path "$result" 2>/dev/null)" || summary=""
  [[ -n "$summary" ]] || { echo "ci.sh: no test summary in $result" >&2; return 0; }
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
  report_failed_tests "$RESULT"
  exit 65
fi

# UI scenarios. One line of Scripts/ci-ui-scenarios.txt per xcodebuild run:
#
#   <stub.py> <Class>[/<test>] [--erase] [--content-size <simctl category>]
#             [--media <file name>]... [--skip <test>]...
#
# The stub is started on port 8421 for that line only, and must answer
# `/__whoami` with its own pid (an orphan stub squatting the port would serve
# another feature's data). `--erase` wipes the simulator first (Keychain, Photos,
# defaults); `--content-size` sets the SYSTEM text size, which an app extension
# follows (the app itself takes it as a launch argument), and is put back to
# `large` afterwards; `--media` seeds a generated PNG under that file name into
# Photos. A test that fails, or skips, fails the CI; every line still runs, so
# one run reports every broken scenario.
UI_LIST="Scripts/ci-ui-scenarios.txt"
STUB_PORT=8421

check_ui_summary() {
  local result="$1" label="$2" summary
  summary="$(xcrun xcresulttool get test-results summary --path "$result" 2>/dev/null)" || summary=""
  [[ -n "$summary" ]] || { echo "::error::$label: no test summary in $result"; return 1; }
  printf '%s' "$summary" | python3 -c '
import json, sys
label = sys.argv[1]
summary = json.load(sys.stdin)
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
skipped = summary.get("skippedTests", 0)
print("ci.sh: %s: %d passed, %d failed, %d skipped" % (label, passed, failed, skipped), file=sys.stderr)
if skipped or not passed:
    print("::error::%s: %d skipped, %d passed (a UI scenario that skips itself proves nothing)"
          % (label, skipped, passed))
    raise SystemExit(1)
' "$label"
}

run_scenario() {
  local index="$1" stub="$2" selector="$3"
  shift 3
  local erase=0 content_size="" media=() skips=() status=0 name file
  while (( $# )); do
    case "$1" in
      --erase) erase=1 ;;
      --content-size) content_size="$2"; shift ;;
      --media) media+=("$2"); shift ;;
      --skip) skips+=("-skip-testing:ImmichSwiftUIUITests/${selector%%/*}/$2"); shift ;;
      *) echo "::error::$UI_LIST: unknown option $1"; return 2 ;;
    esac
    shift
  done
  local label="$selector" result="build/ci/ui-$index.xcresult" stub_log="build/ci/ui-$index-stub.log"
  echo "ci.sh: UI scenario $label (stub $stub)"

  # Called as `run_scenario … || …`, so `set -e` does not apply in here: every
  # preparation step checks its own status.
  if (( erase )); then
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    if ! xcrun simctl erase "$udid" || ! xcrun simctl bootstatus "$udid" -b >/dev/null; then
      echo "::error::$label: could not erase and boot the simulator"
      return 1
    fi
  fi
  for name in ${media[@]+"${media[@]}"}; do
    file="$media_dir/$name"
    if ! python3 -c '
import sys
sys.path.insert(0, "UITests/stubs")
from immich_stub_base import png
open(sys.argv[1], "wb").write(png(sys.argv[2], size=64))
' "$file" "$name" || ! xcrun simctl addmedia "$udid" "$file"; then
      echo "::error::$label: could not seed $name into Photos"
      return 1
    fi
  done
  if [[ -n "$content_size" ]] && ! xcrun simctl ui "$udid" content_size "$content_size"; then
    echo "::error::$label: could not set the system text size to $content_size"
    xcrun simctl ui "$udid" content_size large || true
    return 1
  fi

  python3 -u "UITests/stubs/$stub" "$STUB_PORT" >"$stub_log" 2>&1 &
  stub_pid=$!
  local ready=0 attempt
  for attempt in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$STUB_PORT/__whoami" 2>/dev/null | python3 -c '
import json, sys
raise SystemExit(0 if json.load(sys.stdin).get("pid") == int(sys.argv[1]) else 1)
' "$stub_pid" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.5
  done
  if (( ! ready )); then
    echo "::error::$label: stub $stub did not answer /__whoami on port $STUB_PORT with its own pid"
    status=1
  else
    rm -rf "$result"
    if ! TEST_RUNNER_IMMICH_STUB_URL="http://127.0.0.1:$STUB_PORT" xcodebuild test-without-building \
      "${common[@]}" -quiet \
      -only-testing:"ImmichSwiftUIUITests/$selector" ${skips[@]+"${skips[@]}"} \
      -resultBundlePath "$result" </dev/null; then
      report_failed_tests "$result"
      status=1
    fi
    check_ui_summary "$result" "$label" || status=1
  fi

  kill "$stub_pid" 2>/dev/null || true
  wait "$stub_pid" 2>/dev/null || true
  stub_pid=""
  if [[ -n "$content_size" ]]; then
    xcrun simctl ui "$udid" content_size large || true
  fi
  return "$status"
}

ui_failures=0
ui_index=0
while IFS= read -r line <&3; do
  line="${line%%#*}"
  read -ra words <<<"$line"
  (( ${#words[@]} )) || continue
  ui_index=$((ui_index + 1))
  run_scenario "$ui_index" "${words[@]}" || ui_failures=$((ui_failures + 1))
done 3<"$UI_LIST"
if (( ui_failures )); then
  echo "ci.sh: $ui_failures UI scenario line(s) failed" >&2
  exit 65
fi
