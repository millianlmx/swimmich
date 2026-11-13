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
# 2. Builds the app, its extensions and BOTH test bundles.
# 3. Runs the unit tests (ImmichSwiftUITests) on a dedicated simulator,
#    `swimmich-ci`, created on first use so the CI never boots the developer's.
# 4. Runs the UI scenarios listed in Scripts/ci-ui-scenarios.txt, each against
#    its own Python stub from UITests/stubs/ (the scenarios not listed there are
#    compiled, not run), several at a time on a pool of simulators of their own
#    (`SWIMMICH_CI_UI_WORKERS`, 3 by default). A scenario that skips itself fails
#    the CI: a skip only means its stub was unreachable, which proves nothing.
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

# The udid of the simulator named "$1", created on first use with the newest
# installed iOS runtime that Xcode can drive.
simulator_udid() {
  local name="$1" found runtime
  found=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["name"] == name:
            print(device["udid"])
            raise SystemExit
' "$name")
  if [[ -z "$found" ]]; then
    runtime=$(xcrun simctl list runtimes available -j | python3 -c '
import json, sys
ios = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS"]
ios.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(ios[-1]["identifier"] if ios else "")
')
    [[ -n "$runtime" ]] || { echo "ci.sh: no iOS simulator runtime installed" >&2; return 2; }
    found=$(xcrun simctl create "$name" "$DEVICE_TYPE" "$runtime")
  fi
  printf '%s\n' "$found"
}

udid=$(simulator_udid "$SIM_NAME")
echo "ci.sh: simulator $SIM_NAME ($udid)"
# Erased, then booted (and waited for) up front. Erased: the simulator outlives
# a run, and a device another run left locked by Face ID fails the app lock's
# unit tests. Booted: a cold device handed to xcodebuild can fail with "Invalid
# device state" before the first test.
xcrun simctl shutdown "$udid" 2>/dev/null || true
xcrun simctl erase "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null

# Everything but the destination: each UI scenario picks its own simulator.
project=(
  -project ImmichSwiftUI.xcodeproj
  -scheme ImmichSwiftUI
  -derivedDataPath "$CACHE/DerivedData"
  -clonedSourcePackagesDirPath "$CACHE/SourcePackages"
)
common=("${project[@]}" -destination "platform=iOS Simulator,id=$udid")

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
worker_pids=()
cleanup() {
  rm -f "$build_log" "$python_log" "$audit_log"
  rm -rf "$media_dir"
  local pid sim
  for pid in ${worker_pids[@]+"${worker_pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
  # The simulators are kept (created once, erased before use: their disk stays
  # bounded) but not left running: a booted pool holds memory and CPU between runs.
  for sim in "$udid" ${worker_udids[@]+"${worker_udids[@]}"}; do
    xcrun simctl shutdown "$sim" 2>/dev/null || true
  done
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
#   <stub.py> <Class>[/<test>] [--content-size <simctl category>]
#             [--media <file name>]... [--skip <test>]...
#
# The lines run several at a time, one per worker of a pool of
# `SWIMMICH_CI_UI_WORKERS` simulators (3 by default): worker k is
# `$SIM_NAME-ui-k`, created on first use, none of them the unit tests'
# simulator (a UI line can leave a device locked by Face ID). Each line gets a worker's
# simulator freshly ERASED (no line inherits another's keychain, defaults,
# Photos or lock: the order of the list does not matter), and its own stub on
# the worker's port, `SWIMMICH_CI_STUB_PORT` (8421 by default) + k - 1, which
# must answer `/__whoami` with its own pid (an orphan stub squatting the port
# would serve another feature's data). A second runner on the same Mac sets its
# own `SWIMMICH_CI_STUB_PORT`, `SWIMMICH_CI_SIM` and `SWIMMICH_CI_CACHE`. The
# scenario reaches it through `IMMICH_STUB_URL` (`TEST_RUNNER_IMMICH_STUB_URL`).
# `--content-size` sets the SYSTEM text size, which an app extension follows
# (the app itself takes it as a launch argument); `--media` seeds a generated
# PNG under that file name into Photos. A test that fails, or skips, fails the
# CI; every line still runs, so one run reports every broken scenario. A free
# worker takes the next line: put the longest lines first.
UI_LIST="Scripts/ci-ui-scenarios.txt"
UI_WORKERS="${SWIMMICH_CI_UI_WORKERS:-3}"
STUB_PORT_BASE="${SWIMMICH_CI_STUB_PORT:-8421}"

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

# One line on one worker: run_scenario <index> <udid> <port> <stub.py> <selector> [options…].
# Runs in its own subshell (see the pool below), so its stub dies with it.
run_scenario() {
  local index="$1" sim="$2" port="$3" stub="$4" selector="$5"
  shift 5
  local content_size="" media=() skips=() status=0 name file
  # Not local: the EXIT trap of the line's subshell reads it after the return.
  stub_pid=""
  trap '[[ -z "$stub_pid" ]] || kill "$stub_pid" 2>/dev/null || true' EXIT
  while (( $# )); do
    case "$1" in
      --content-size) content_size="$2"; shift ;;
      --media) media+=("$2"); shift ;;
      --skip) skips+=("-skip-testing:ImmichSwiftUIUITests/${selector%%/*}/$2"); shift ;;
      *) echo "::error::$UI_LIST: unknown option $1"; return 2 ;;
    esac
    shift
  done
  local label="$selector" result="build/ci/ui-$index.xcresult" stub_log="build/ci/ui-$index-stub.log"
  local media_here="$media_dir/$index"
  echo "ci.sh: UI scenario $label (stub $stub, simulator $sim, port $port)"

  # Started as `run_scenario … || exit`, so `set -e` does not apply in here:
  # every preparation step checks its own status.
  xcrun simctl shutdown "$sim" 2>/dev/null || true
  if ! xcrun simctl erase "$sim" || ! xcrun simctl bootstatus "$sim" -b >/dev/null; then
    echo "::error::$label: could not erase and boot the simulator"
    return 1
  fi
  mkdir -p "$media_here"
  for name in ${media[@]+"${media[@]}"}; do
    file="$media_here/$name"
    if ! python3 -c '
import sys
sys.path.insert(0, "UITests/stubs")
from immich_stub_base import png
open(sys.argv[1], "wb").write(png(sys.argv[2], size=64))
' "$file" "$name" || ! xcrun simctl addmedia "$sim" "$file"; then
      echo "::error::$label: could not seed $name into Photos"
      return 1
    fi
  done
  if [[ -n "$content_size" ]] && ! xcrun simctl ui "$sim" content_size "$content_size"; then
    echo "::error::$label: could not set the system text size to $content_size"
    return 1
  fi

  # A cancelled run (GitHub kills the job, not its subshells' children) leaves its
  # stub listening: that orphan, a stub of this repository, is stopped first.
  # Anything else on the port is left alone, and the `/__whoami` check fails.
  local holder
  for holder in $(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null); do
    if ps -o command= -p "$holder" | grep -q 'UITests/stubs/'; then
      echo "ci.sh: stopping orphan stub $holder on port $port"
      kill "$holder" 2>/dev/null || true
    fi
  done
  sleep 0.5

  python3 -u "UITests/stubs/$stub" "$port" >"$stub_log" 2>&1 &
  stub_pid=$!
  local ready=0 attempt
  for attempt in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$port/__whoami" 2>/dev/null | python3 -c '
import json, sys
raise SystemExit(0 if json.load(sys.stdin).get("pid") == int(sys.argv[1]) else 1)
' "$stub_pid" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.5
  done
  if (( ! ready )); then
    echo "::error::$label: stub $stub did not answer /__whoami on port $port with its own pid"
    status=1
  else
    rm -rf "$result"
    if ! TEST_RUNNER_IMMICH_STUB_URL="http://127.0.0.1:$port" xcodebuild test-without-building \
      "${project[@]}" -destination "platform=iOS Simulator,id=$sim" -quiet \
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
  return "$status"
}

ui_lines=()
while IFS= read -r line <&3; do
  line="${line%%#*}"
  read -ra words <<<"$line"
  (( ${#words[@]} )) || continue
  ui_lines+=("${words[*]}")
done 3<"$UI_LIST"

(( UI_WORKERS >= 1 )) || { echo "ci.sh: SWIMMICH_CI_UI_WORKERS must be at least 1" >&2; exit 2; }
(( UI_WORKERS <= ${#ui_lines[@]} )) || UI_WORKERS=${#ui_lines[@]}
worker_udids=()
for (( worker = 1; worker <= UI_WORKERS; worker++ )); do
  worker_udids+=("$(simulator_udid "$SIM_NAME-ui-$worker")")
done
echo "ci.sh: ${#ui_lines[@]} UI scenario line(s) on $UI_WORKERS simulator(s): ${worker_udids[*]-}"

# The pool. bash 3.2 (macOS) has no `wait -n`: each worker slot holds the pid
# of its running line (empty when free), polled every 2 s. A line's output goes
# to its own log, printed whole once the line ends, so the CI log never
# interleaves two scenarios.
mkdir -p build/ci
worker_pids=()
worker_lines=()
for (( worker = 0; worker < UI_WORKERS; worker++ )); do worker_pids+=(""); worker_lines+=(""); done
ui_failures=0
next=0
running=0
while (( next < ${#ui_lines[@]} || running > 0 )); do
  for (( worker = 0; worker < UI_WORKERS; worker++ )); do
    pid="${worker_pids[worker]}"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      if wait "$pid"; then line_status=0; else line_status=$?; fi
      index="${worker_lines[worker]}"
      cat "build/ci/ui-$index.log"
      (( line_status == 0 )) || ui_failures=$((ui_failures + 1))
      worker_pids[worker]=""
      running=$((running - 1))
      pid=""
    fi
    if [[ -z "$pid" ]] && (( next < ${#ui_lines[@]} )); then
      index=$((next + 1))
      read -ra words <<<"${ui_lines[next]}"
      ( run_scenario "$index" "${worker_udids[worker]}" "$((STUB_PORT_BASE + worker))" "${words[@]}" || exit "$?" ) \
        >"build/ci/ui-$index.log" 2>&1 &
      worker_pids[worker]=$!
      worker_lines[worker]="$index"
      next=$((next + 1))
      running=$((running + 1))
    fi
  done
  (( running == 0 )) || sleep 2
done
if (( ui_failures )); then
  echo "ci.sh: $ui_failures UI scenario line(s) failed" >&2
  exit 65
fi

# The i18n audit ran first (it only reads the catalog and the sources); its
# verdict is applied last so one pass judges the audit AND the tests.
if (( audit_status != 0 )); then
  echo "ci.sh: i18n audit failed (exit $audit_status)" >&2
  exit 1
fi
