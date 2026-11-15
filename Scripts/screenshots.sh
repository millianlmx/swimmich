#!/usr/bin/env bash
#
# Scripts/screenshots.sh — regenerates docs/screenshots/*.png, the pictures of
# README.md and README.fr.md.
#
# It creates a throwaway iPhone 17 simulator on the newest iOS 26+ runtime, starts
# UITests/stubs/immich_stub_readme_screenshots.py (CC0 sample photos, no real
# server or account), runs the XCUITest `ReadmeScreenshotsUITests` against it and
# deletes the simulator. Needs a Mac with Xcode, XcodeGen and python3; nothing else
# to do by hand. Commit the rewritten PNGs.
#
#   SWIMMICH_SCREENSHOT_PORT   port of the stub (default 8421)
#
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${SWIMMICH_SCREENSHOT_PORT:-8421}"
OUT="$PWD/docs/screenshots"
NAMES=(timeline viewer albums search backup)

runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
found = [r for r in json.load(sys.stdin)["runtimes"]
         if r["isAvailable"] and r["name"].startswith("iOS ") and int(r["version"].split(".")[0]) >= 26]
if not found:
    sys.exit("screenshots.sh: no iOS 26+ simulator runtime installed")
print(max(found, key=lambda r: [int(p) for p in r["version"].split(".")])["identifier"])
')"

xcodegen generate --quiet

udid="$(xcrun simctl create swimmich-screenshots com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")"
stub_pid=""
cleanup() {
  [ -z "$stub_pid" ] || kill "$stub_pid" 2>/dev/null || true
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl delete "$udid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

python3 UITests/stubs/immich_stub_readme_screenshots.py "$PORT" >/dev/null &
stub_pid=$!
for _ in $(seq 1 50); do
  curl -fs "http://127.0.0.1:$PORT/api/server/ping" >/dev/null && break
  sleep 0.2
done
curl -fs "http://127.0.0.1:$PORT/api/server/ping" >/dev/null \
  || { echo "screenshots.sh: the stub does not answer on port $PORT" >&2; exit 1; }

xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3

mkdir -p "$OUT"
for name in "${NAMES[@]}"; do rm -f "$OUT/$name.png"; done

TEST_RUNNER_IMMICH_STUB_URL="http://127.0.0.1:$PORT" TEST_RUNNER_SWIMMICH_SCREENSHOT_DIR="$OUT" \
  xcodebuild test -quiet -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build/screenshots \
  -only-testing:ImmichSwiftUIUITests/ReadmeScreenshotsUITests

for name in "${NAMES[@]}"; do
  [ -s "$OUT/$name.png" ] || { echo "screenshots.sh: docs/screenshots/$name.png was not written" >&2; exit 1; }
done
echo "screenshots.sh: wrote ${NAMES[*]/%/.png} in docs/screenshots/"
