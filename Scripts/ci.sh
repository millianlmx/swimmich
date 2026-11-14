#!/usr/bin/env bash
# The CI of swimmich, runnable as is on any Mac with Xcode and XcodeGen.
#
#   Scripts/ci.sh
#
# 0. Runs the Python tests of the CI's own scripts (Scripts/test_*.py: the i18n
#    audit, the selection of the UI scenarios), then, after XcodeGen, the audit
#    itself (R1-R4) in the background, at the lowest priority; its verdict is
#    applied at the end, so one pass judges the audit and the tests.
# 1. Regenerates the project from project.yml: the committed .xcodeproj drifts,
#    and a Tests/*.swift file missing from it would pass "green" by omission.
# 2. Builds the app, its extensions and BOTH test bundles.
# 3. Runs the unit tests (ImmichSwiftUITests) and the UI scenarios of
#    Scripts/ci-ui-scenarios.txt that `SWIMMICH_CI_UI_SCOPE` selects (the gate
#    of a push, the night's core suite, or all of them) side by side, on a pool
#    of simulators of their own (`SWIMMICH_CI_UI_WORKERS`, 3 by default), created
#    on first use so the CI never boots the developer's. Each scenario runs
#    against its own Python stub from UITests/stubs/ (the scenarios not listed
#    are compiled, not run). A scenario that skips itself fails the CI: a skip
#    only means its stub was unreachable, which proves nothing.
#
# DerivedData and SwiftPM checkouts live in a persistent cache: on the
# self-hosted runner, a run only rebuilds what the commit changed.
set -euo pipefail
cd "$(dirname "$0")/.."

# Where the run's time goes, printed at the end (`ci.sh: timings: …`): the gate of
# a push has a budget (`SWIMMICH_CI_GATE_BUDGET`, 300 s), and a run over it gets a
# `::warning` that names the phase to shorten.
phase_started=$SECONDS
phase_times=()
phase_done() {
  phase_times+=("$1 $((SECONDS - phase_started)) s")
  phase_started=$SECONDS
}

# The Python tests of the scripts come first: no build, a few seconds.
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
phase_done "script tests"

CACHE="${SWIMMICH_CI_CACHE:-$HOME/Library/Caches/swimmich-ci}"
SIM_NAME="${SWIMMICH_CI_SIM:-swimmich-ci}"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
RESULT="${SWIMMICH_CI_RESULT:-build/ci/unit-tests.xcresult}"
# The app's PRODUCT_BUNDLE_IDENTIFIER (project.yml): what a simulator reset uninstalls.
APP_BUNDLE_ID="fr.millianlmx.immich-ios"
# simslim (https://github.com/MobAI-App/simslim, `brew install mobai-app/tap/simslim`)
# turns off, in each simulator of the pool, the background daemons the tests do
# not need: wallpaper posters, Siri and Apple Intelligence, photo analysis, sync,
# telemetry. Measured on an erased iPhone 17 (iOS 27.2): 209 processes down to
# 113, memory 2.0 down to 1.1 GB, idle CPU 24 down to 7 s a minute. The profile,
# Scripts/simslim-ci.json, keeps what the scenarios use (Photos, widgets, Live
# Activities, App Intents). Its overrides persist in the simulator across boots
# and resets; only an erase drops them. Without simslim the pool runs stock.
SIMSLIM_PROFILE="Scripts/simslim-ci.json"
if command -v simslim >/dev/null; then SIMSLIM=1; else SIMSLIM=0; fi

xcodegen generate --quiet

# The i18n audit (R1-R4, a virgin extraction build of about 40 s) reads the
# .xcodeproj regenerated above. It runs in the background for the whole run, at
# the lowest priority: its build takes the CPU the app's build and the simulators
# leave idle, instead of 40 s of its own. Its verdict is applied at the very end
# (`apply_audit_verdict`), so the build and the tests still run when it fails.
# The offending lines become public `::error` annotations, because the job log
# is only readable by repository admins.
audit_log="$(mktemp)"
nice -n 20 python3 Scripts/i18n-audit.py --derived-data "$CACHE/i18n-audit-DerivedData" >"$audit_log" 2>&1 &
audit_pid=$!

apply_audit_verdict() {
  local status=0
  wait "$audit_pid" || status=$?
  audit_pid=""
  cat "$audit_log"
  (( status != 0 )) || return 0
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    grep -E '^  - ' "$audit_log" | while IFS= read -r line; do
      line="${line#  - }"
      echo "::error title=i18n-audit::${line//%/%25}"
    done || true
    echo "::error::i18n-audit exited $status"
  fi
  echo "ci.sh: i18n audit failed (exit $status)" >&2
  return 1
}

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

# The scenario lines this run executes: Scripts/ci_ui_select.py reads
# Scripts/ci-ui-scenarios.txt (see "UI scenarios" below), checks its budgets and
# selects by `SWIMMICH_CI_UI_SCOPE`:
#
# * `gate`, the default on GitHub Actions: the lines the push can have broken
#   (a line new or edited, a line whose test function or stub changed), then the
#   `--smoke` lines. The gate of every push, in minutes.
# * `core`: every line but the `--release` ones. The night's suite.
# * `all`, the default on a developer's Mac: every line. The release suite, once
#   a week and on a release tag.
#
# The base the gate reads a push against (`SWIMMICH_CI_UI_BASE`, `main` by
# default) is a branch or a commit: the workflow gives a push to `main` the
# commit `main` pointed at before it. What the gate lets through, the night's
# suite catches: the price of a gate that does not grow with every feature.
UI_LIST="Scripts/ci-ui-scenarios.txt"
UI_SCOPE="${SWIMMICH_CI_UI_SCOPE:-}"
if [[ -z "$UI_SCOPE" ]]; then
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then UI_SCOPE=gate; else UI_SCOPE=all; fi
fi
select_arguments=(--scope "$UI_SCOPE" --list "$UI_LIST")
if [[ "$UI_SCOPE" == gate ]]; then
  # A tree diff against the base's tip: a branch behind main also selects what
  # main changed since, never less than its own changes. The tip alone is enough
  # (no merge base), so the shallow checkout of the runner only fetches it; a
  # developer's clone uses its own `origin/main`.
  # Forced (`+`): the runner's work directory outlives a run, and the ref an
  # earlier run left there is not an ancestor that a shallow clone can prove,
  # so a plain fetch is rejected as non-fast-forward (and `--quiet` hides why).
  UI_BASE="${SWIMMICH_CI_UI_BASE:-main}"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    base_ref=refs/ci/ui-base
    git fetch --quiet --no-tags --depth=1 origin "+$UI_BASE:$base_ref" ||
      { echo "ci.sh: could not fetch the base '$UI_BASE' of SWIMMICH_CI_UI_SCOPE=gate" >&2; exit 2; }
  else
    base_ref="refs/remotes/origin/$UI_BASE"
  fi
  git rev-parse --quiet --verify "$base_ref^{commit}" >/dev/null ||
    { echo "ci.sh: no $base_ref to compare with: SWIMMICH_CI_UI_SCOPE=gate needs it" >&2; exit 2; }
  select_arguments+=(--base "$base_ref")
fi
selected_lines=$(python3 Scripts/ci_ui_select.py "${select_arguments[@]}") || exit 2
ui_lines=()
while IFS= read -r line; do
  [[ -z "$line" ]] || ui_lines+=("$line")
done <<<"$selected_lines"

# The pool: `SWIMMICH_CI_UI_WORKERS` simulators (3 by default), worker k being
# `$SIM_NAME-ui-k`, created on first use. A worker runs one job at a time: the
# unit tests, or one line of the list. The unit tests are a job like the others,
# so they run beside the UI scenarios and a runner never holds more simulators
# than its workers. The app is built for the first worker: a destination of this
# exact kind keeps the build to the Mac's own architecture.
UI_WORKERS="${SWIMMICH_CI_UI_WORKERS:-3}"
(( UI_WORKERS >= 1 )) || { echo "ci.sh: SWIMMICH_CI_UI_WORKERS must be at least 1" >&2; exit 2; }
(( UI_WORKERS <= ${#ui_lines[@]} + 1 )) || UI_WORKERS=$(( ${#ui_lines[@]} + 1 ))
worker_udids=()
for (( worker = 1; worker <= UI_WORKERS; worker++ )); do
  worker_udids+=("$(simulator_udid "$SIM_NAME-ui-$worker")")
done

common=(
  -project ImmichSwiftUI.xcodeproj
  -scheme ImmichSwiftUI
  -derivedDataPath "$CACHE/DerivedData"
  -clonedSourcePackagesDirPath "$CACHE/SourcePackages"
  -destination "platform=iOS Simulator,id=${worker_udids[0]}"
)

phase_done "project and selection"

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
  [[ -z "${audit_pid:-}" ]] || kill "$audit_pid" 2>/dev/null || true
  for pid in ${worker_pids[@]+"${worker_pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
  # The simulators are kept (created once, reset between jobs: their disk stays
  # bounded) but not left running: a booted pool holds memory and CPU between runs.
  for sim in ${worker_udids[@]+"${worker_udids[@]}"}; do
    xcrun simctl shutdown "$sim" 2>/dev/null || true
  done
}
trap cleanup EXIT

# Boots a shut-down simulator slim: the profile is written into its launchd store
# first (a single read when it already matches), so the boot starts none of the
# daemons it turns off.
boot_simulator() {
  local sim="$1"
  if (( SIMSLIM )); then
    simslim on "$sim" --profile "$SIMSLIM_PROFILE" --preserve-boot-state >/dev/null || return
  fi
  xcrun simctl boot "$sim" 2>/dev/null || true
  xcrun simctl bootstatus "$sim" -b >/dev/null
}

# The pool boots while the app builds: its simulators booting at once took up to
# two minutes before the first test, now spent beside the build (each job still
# waits for its own simulator, `prepare_simulator`).
(( SIMSLIM )) || echo "ci.sh: simslim is not installed: the simulators run stock (see SIMSLIM_PROFILE)"
boot_pids=()
for sim in "${worker_udids[@]}"; do
  boot_simulator "$sim" >/dev/null 2>&1 &
  boot_pids+=($!)
done
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

# The jobs run the tests from the .xctestrun the build wrote, each on its worker's
# simulator: unlike `-project`/`-scheme`, it spares every job loading the project
# and resolving its packages again.
xctestrun=$(ls -t "$CACHE"/DerivedData/Build/Products/*.xctestrun 2>/dev/null | head -1)
[[ -n "$xctestrun" ]] || { echo "ci.sh: the build wrote no .xctestrun" >&2; exit 65; }

phase_done "build"

# The pool's boots end before its first job: a job's own `bootstatus -b` would
# otherwise boot a simulator stock while simslim is still writing its profile.
for pid in "${boot_pids[@]}"; do wait "$pid" || true; done
phase_done "simulators' boot after the build"

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

# Readies a worker's simulator for a job: prepare_simulator <udid> <erase 0|1>.
#
# A line that asks for it (`--erase`) gets the simulator ERASED, then booted.
# Every other job gets it booted and RESET: the app terminated, its privacy
# grants revoked and the app uninstalled (its container, its app group and its
# defaults go with it), the keychain emptied (a device left locked by Face ID
# fails the app lock's tests) and the system text size put back to L. A reset
# does not put back Photos (a `--media` line seeds its photo as the newest one)
# nor the Face ID enrolment, from this run or an earlier one: a line that needs a
# pristine device asks for `--erase`. Erasing is the exception on purpose: an
# erased device spends its first minutes rebuilding its wallpapers, widgets,
# Photos and caches in the background, and one erase per line took the CPU of
# the whole Mac.
prepare_simulator() {
  local sim="$1" erase="$2"
  if (( erase )); then
    xcrun simctl shutdown "$sim" 2>/dev/null || true
    xcrun simctl erase "$sim" && boot_simulator "$sim"
    return
  fi
  xcrun simctl bootstatus "$sim" -b >/dev/null || return
  xcrun simctl terminate "$sim" "$APP_BUNDLE_ID" 2>/dev/null || true
  xcrun simctl privacy "$sim" reset all "$APP_BUNDLE_ID" 2>/dev/null || true
  xcrun simctl uninstall "$sim" "$APP_BUNDLE_ID" || return
  xcrun simctl keychain "$sim" reset || return
  xcrun simctl ui "$sim" content_size large
}

# The unit tests that take a second or more, slowest first: they are the floor of
# the gate (the unit tests run beside the scenarios, on one simulator).
report_slow_unit_tests() {
  xcrun xcresulttool get test-results tests --path "$1" 2>/dev/null | python3 -c '
import json, sys
found = []
def walk(node, suite):
    kind = node.get("nodeType")
    if kind == "Test Case":
        found.append((node.get("durationInSeconds") or 0, suite + "/" + (node.get("name") or "?")))
    if kind == "Test Suite":
        suite = node.get("name") or suite
    for child in node.get("children") or []:
        walk(child, suite)
try:
    for node in json.load(sys.stdin).get("testNodes") or []:
        walk(node, "")
except Exception as error:
    print("ci.sh: unit test durations unreadable: %s" % error)
    raise SystemExit
found.sort(reverse=True)
slow = [item for item in found if item[0] >= 1]
print("ci.sh: unit tests: %d tests, %.0f s in the tests themselves, %d of a second or more (%.0f s)"
      % (len(found), sum(item[0] for item in found), len(slow), sum(item[0] for item in slow)))
for seconds, name in slow[:25]:
    print("ci.sh:   %5.1f s  %s" % (seconds, name))
' || true
}

# The unit tests, as a job of the pool: run_unit_tests <udid>.
run_unit_tests() {
  local sim="$1"
  echo "ci.sh: unit tests (simulator $sim)"
  if ! prepare_simulator "$sim" 0; then
    echo "::error::unit tests: could not ready the simulator"
    return 1
  fi
  rm -rf "$RESULT"
  mkdir -p "$(dirname "$RESULT")"
  if ! xcodebuild test-without-building -xctestrun "$xctestrun" -destination "platform=iOS Simulator,id=$sim" -quiet \
    -only-testing:ImmichSwiftUITests -resultBundlePath "$RESULT" </dev/null; then
    report_failed_tests "$RESULT"
    report_slow_unit_tests "$RESULT"
    return 1
  fi
  report_slow_unit_tests "$RESULT"
}

# UI scenarios. One line of Scripts/ci-ui-scenarios.txt per xcodebuild run:
#
#   <stub.py> <Class>[/<test>] [--content-size <simctl category>]
#             [--media <file name>]... [--skip <test>]... [--erase]
#             [--smoke | --release]
#
# `--smoke` and `--release` are the line's tier (see `SWIMMICH_CI_UI_SCOPE`
# above and the head of the list). A line runs on a worker's simulator, reset by `prepare_simulator` (`--erase`
# for a freshly erased device), and against its own stub on the
# worker's port, `SWIMMICH_CI_STUB_PORT` (8421 by default) + k - 1, which must
# answer `/__whoami` with its own pid (an orphan stub squatting the port would
# serve another feature's data). A second runner on the same Mac sets its own
# `SWIMMICH_CI_STUB_PORT`, `SWIMMICH_CI_SIM` and `SWIMMICH_CI_CACHE`. The
# scenario reaches it through `IMMICH_STUB_URL` (`TEST_RUNNER_IMMICH_STUB_URL`).
# `--content-size` sets the SYSTEM text size, which an app extension follows
# (the app itself takes it as a launch argument); `--media` seeds a generated
# PNG under that file name into Photos. A test that fails, or skips, fails the
# CI; every line still runs, so one run reports every broken scenario. A free
# worker takes the next job: put the longest lines first.
#
# Budget: a UI test over `SWIMMICH_CI_UI_TEST_BUDGET` seconds (180 by default)
# gets a `::warning`. The run lasts at least as long as its longest line, however
# many workers there are: a longer test is cut in several (see
# Scripts/ci-ui-scenarios.txt). A warning, not a failure: a loaded Mac doubles a
# test's time, and a CI that fails on the clock fails at random.
STUB_PORT_BASE="${SWIMMICH_CI_STUB_PORT:-8421}"
UI_TEST_BUDGET="${SWIMMICH_CI_UI_TEST_BUDGET:-180}"

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

report_slow_tests() {
  xcrun xcresulttool get test-results tests --path "$1" 2>/dev/null | python3 -c '
import json, sys
budget = float(sys.argv[1])
def walk(node):
    if node.get("nodeType") == "Test Case":
        seconds = node.get("durationInSeconds") or 0
        if seconds > budget:
            name = node.get("nodeIdentifier") or node.get("name") or "?"
            print("::warning::%s took %d s, over the %d s budget of a UI test: cut it in several"
                  % (name, seconds, budget))
    for child in node.get("children") or []:
        walk(child)
try:
    for node in json.load(sys.stdin).get("testNodes") or []:
        walk(node)
except Exception:
    pass
' "$UI_TEST_BUDGET" || true
}

# One line on one worker: run_scenario <index> <udid> <port> <stub.py> <selector> [options…].
# Runs in its own subshell (see the pool below), so its stub dies with it.
run_scenario() {
  local index="$1" sim="$2" port="$3" stub="$4" selector="$5"
  shift 5
  local content_size="" media=() skips=() erase=0 status=0 name file
  # Not local: the EXIT trap of the line's subshell reads it after the return.
  stub_pid=""
  trap '[[ -z "$stub_pid" ]] || kill "$stub_pid" 2>/dev/null || true' EXIT
  while (( $# )); do
    case "$1" in
      --content-size) content_size="$2"; shift ;;
      --media) media+=("$2"); shift ;;
      --skip) skips+=("-skip-testing:ImmichSwiftUIUITests/${selector%%/*}/$2"); shift ;;
      --erase) erase=1 ;;
      --smoke | --release) ;;
      *) echo "::error::$UI_LIST: unknown option $1"; return 2 ;;
    esac
    shift
  done
  local label="$selector" result="build/ci/ui-$index.xcresult" stub_log="build/ci/ui-$index-stub.log"
  local media_here="$media_dir/$index"
  echo "ci.sh: UI scenario $label (stub $stub, simulator $sim, port $port)"

  # Started as `run_scenario … || exit`, so `set -e` does not apply in here:
  # every preparation step checks its own status.
  if ! prepare_simulator "$sim" "$erase"; then
    echo "::error::$label: could not ready the simulator"
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
      -xctestrun "$xctestrun" -destination "platform=iOS Simulator,id=$sim" -quiet \
      -only-testing:"ImmichSwiftUIUITests/$selector" ${skips[@]+"${skips[@]}"} \
      -resultBundlePath "$result" </dev/null; then
      report_failed_tests "$result"
      status=1
    fi
    check_ui_summary "$result" "$label" || status=1
    report_slow_tests "$result"
  fi

  kill "$stub_pid" 2>/dev/null || true
  wait "$stub_pid" 2>/dev/null || true
  stub_pid=""
  return "$status"
}

# The pool. Job 0 is the unit tests, job k the k-th line of the list. bash 3.2
# (macOS) has no `wait -n`: each worker slot holds the pid of its running job
# (empty when free), polled every 2 s. A job's output goes to its own log,
# printed whole once the job ends, so the CI log never interleaves two jobs.
echo "ci.sh: unit tests and ${#ui_lines[@]} UI scenario line(s) on $UI_WORKERS simulator(s): ${worker_udids[*]}"
mkdir -p build/ci
worker_pids=()
worker_jobs=()
for (( worker = 0; worker < UI_WORKERS; worker++ )); do worker_pids+=(""); worker_jobs+=(""); done
job_log() { if (( $1 == 0 )); then echo "build/ci/unit-tests.log"; else echo "build/ci/ui-$1.log"; fi; }
unit_failed=0
ui_failures=0
jobs_total=$(( ${#ui_lines[@]} + 1 ))
next=0
running=0
while (( next < jobs_total || running > 0 )); do
  for (( worker = 0; worker < UI_WORKERS; worker++ )); do
    pid="${worker_pids[worker]}"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      if wait "$pid"; then job_status=0; else job_status=$?; fi
      job="${worker_jobs[worker]}"
      cat "$(job_log "$job")"
      if (( job_status != 0 )); then
        if (( job == 0 )); then unit_failed=1; else ui_failures=$((ui_failures + 1)); fi
      fi
      worker_pids[worker]=""
      running=$((running - 1))
      pid=""
    fi
    if [[ -z "$pid" ]] && (( next < jobs_total )); then
      if (( next == 0 )); then
        ( run_unit_tests "${worker_udids[worker]}" || exit "$?" ) >"$(job_log 0)" 2>&1 &
      else
        read -ra words <<<"${ui_lines[next - 1]}"
        ( run_scenario "$next" "${worker_udids[worker]}" "$((STUB_PORT_BASE + worker))" "${words[@]}" || exit "$?" ) \
          >"$(job_log "$next")" 2>&1 &
      fi
      worker_pids[worker]=$!
      worker_jobs[worker]="$next"
      next=$((next + 1))
      running=$((running + 1))
    fi
  done
  (( running == 0 )) || sleep 2
done

# The i18n audit ran beside the build and the tests (it only reads the catalog and
# the sources); its verdict is applied last so one pass judges the audit AND the tests.
phase_done "tests"
audit_ok=1
apply_audit_verdict || audit_ok=0
phase_done "i18n audit after the tests"
timings=$(IFS=,; echo "${phase_times[*]}")
echo "ci.sh: timings: ${timings//,/, }, total $SECONDS s"
GATE_BUDGET="${SWIMMICH_CI_GATE_BUDGET:-300}"
if [[ "$UI_SCOPE" == gate ]] && (( SECONDS > GATE_BUDGET )); then
  echo "::warning::the gate took $SECONDS s, over its budget of $GATE_BUDGET s: ${timings//,/, }"
fi
if (( unit_failed )); then echo "ci.sh: the unit tests failed" >&2; fi
if (( ui_failures )); then echo "ci.sh: $ui_failures UI scenario line(s) failed" >&2; fi
(( ! unit_failed && ! ui_failures )) || exit 65
(( audit_ok )) || exit 1
