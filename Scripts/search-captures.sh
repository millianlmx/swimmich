#!/usr/bin/env bash
#
# Scripts/search-captures.sh <before|after> — photographs and measures the Search tab.
#
# It takes seven pictures of the Search tab's Results mode (home, suggestions, results,
# filters-sheet, no-results-filtered, filtered, selection) with the XCUITest
# `SearchCapturesUITests`, each with a text measurement (buttons within reach, search
# field at the top, filter chips), and leaves them in build/search-captures/<series>/
# as <series>-<state>.png and <series>-<state>.txt. The series is `before` on the code
# the Search redesign started from and `after` on the redesigned one; Scripts/ci-search-captures.sh
# publishes it.
#
# Like Scripts/screenshots.sh, it creates a throwaway iPhone 17 simulator on the newest
# iOS 26+ runtime, starts UITests/stubs/immich_stub_readme_screenshots.py (CC0 sample
# photos, no real server) on a free port, checks through /__whoami that the port answers
# the stub this script started, boots the simulator with its status bar pinned to 9:41,
# builds the app and its UI tests, installs the app and grants it Photos access, runs the
# scenario and deletes the simulator. The files of the series are deleted only once
# everything is ready to rewrite them.
# Needs a Mac with Xcode, XcodeGen and python3.
#
#   SWIMMICH_CAPTURE_PORT   port of the stub (default 0: a free port chosen by the system)
#
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "search-captures.sh: $*" >&2; exit 1; }

series="${1:-}"
case "$series" in
  before|after) ;;
  *) echo "search-captures.sh: usage: Scripts/search-captures.sh before|after" >&2; exit 2 ;;
esac

PORT="${SWIMMICH_CAPTURE_PORT:-0}"
OUT="$PWD/build/search-captures/$series"
NAMES=(home suggestions results filters-sheet no-results-filtered filtered selection)
STUB_NAME="immich_stub_readme_screenshots.py"
BUILD_DIR=build/search-captures
STUB_LOG="$BUILD_DIR/stub.log"
APP_BUNDLE_ID=fr.millianlmx.immich-ios

runtimes="$(xcrun simctl list runtimes -j)" \
  || { rc=$?; fail "could not list the simulator runtimes (exit $rc)"; }
runtime="$(printf '%s' "$runtimes" | python3 -c '
import json, sys
found = [r for r in json.load(sys.stdin)["runtimes"]
         if r["isAvailable"] and r["name"].startswith("iOS ") and int(r["version"].split(".")[0]) >= 26]
if not found:
    sys.exit("search-captures.sh: no iOS 26+ simulator runtime installed")
print(max(found, key=lambda r: [int(p) for p in r["version"].split(".")])["identifier"])
')" || { rc=$?; fail "no usable iOS 26+ simulator runtime (exit $rc)"; }

xcodegen generate --quiet || { rc=$?; fail "xcodegen generate failed (exit $rc)"; }

udid=""
stub_pid=""
cleanup() {
  [ -z "$stub_pid" ] || kill "$stub_pid" 2>/dev/null || true
  if [ -n "$udid" ]; then
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl delete "$udid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

udid="$(xcrun simctl create swimmich-search-captures com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")" \
  || { rc=$?; udid=""; fail "could not create the iPhone 17 simulator on $runtime (exit $rc)"; }

# The stub prints one JSON line first, with the port it really got; -u keeps it from sitting in a buffer.
mkdir -p "$BUILD_DIR"
python3 -u "UITests/stubs/$STUB_NAME" "$PORT" >"$STUB_LOG" 2>&1 &
stub_pid=$!
port=""
for _ in $(seq 1 50); do
  kill -0 "$stub_pid" 2>/dev/null || break
  port="$(head -n 1 "$STUB_LOG" | python3 -c '
import json, sys
try:
    port = json.loads(sys.stdin.readline())["port"]
except Exception:
    sys.exit(1)
print(port if isinstance(port, int) else "")
' 2>/dev/null)" || port=""
  [ -z "$port" ] || break
  sleep 0.2
done
if [ -z "$port" ]; then
  cat "$STUB_LOG" >&2 || true
  fail "the stub did not start on port $PORT"
fi

whoami_json="$(curl -fsS "http://127.0.0.1:$port/__whoami" 2>/dev/null)" || whoami_json=""
printf '%s' "$whoami_json" | python3 -c '
import json, sys
who = json.load(sys.stdin)
sys.exit(0 if who.get("pid") == int(sys.argv[1]) and who.get("stub") == sys.argv[2]
         and who.get("port") == int(sys.argv[3]) else 1)
' "$stub_pid" "$STUB_NAME" "$port" 2>/dev/null \
  || fail "port $port answers /__whoami with another server, not the stub this script started (pid $stub_pid)"

{
  xcrun simctl boot "$udid" \
    && xcrun simctl bootstatus "$udid" -b >/dev/null \
    && xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
         --cellularMode active --cellularBars 4 --wifiBars 3
} || { rc=$?; fail "could not boot the simulator $udid (exit $rc)"; }

rc=0
xcodebuild build-for-testing -quiet -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$BUILD_DIR" >"$BUILD_DIR/build.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  { grep ' error: ' "$BUILD_DIR/build.log" | head -n 3 | sed 's/^/search-captures.sh: build error: /' >&2; } || true
  fail "xcodebuild build-for-testing failed (exit $rc), see build/search-captures/build.log"
fi

{
  xcrun simctl install "$udid" "$BUILD_DIR/Build/Products/Debug-iphonesimulator/ImmichSwiftUI.app" \
    && xcrun simctl privacy "$udid" grant photos "$APP_BUNDLE_ID"
} || fail "could not grant Photos access to $APP_BUNDLE_ID"

mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/*.txt
rm -rf "$BUILD_DIR/SearchCaptures.xcresult"

rc=0
TEST_RUNNER_IMMICH_STUB_URL="http://127.0.0.1:$port" TEST_RUNNER_SWIMMICH_CAPTURE_DIR="$OUT" \
  TEST_RUNNER_SWIMMICH_CAPTURE_SERIES="$series" \
  xcodebuild test-without-building -quiet -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$BUILD_DIR" \
  -only-testing:ImmichSwiftUIUITests/SearchCapturesUITests \
  -resultBundlePath "$BUILD_DIR/SearchCaptures.xcresult" || rc=$?

missing=0
for name in "${NAMES[@]}"; do
  for ext in png txt; do
    [ -s "$OUT/$series-$name.$ext" ] \
      || { echo "search-captures.sh: build/search-captures/$series/$series-$name.$ext was not written" >&2; missing=1; }
  done
done
[ "$missing" -eq 0 ] || exit 1
[ "$rc" -eq 0 ] || fail "the capture scenario failed (see build/search-captures/SearchCaptures.xcresult)"
echo "search-captures.sh: wrote the ${#NAMES[@]} $series pictures and measures in build/search-captures/$series/"
