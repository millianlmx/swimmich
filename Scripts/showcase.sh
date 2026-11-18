#!/usr/bin/env bash
#
# Scripts/showcase.sh — regenerates the showcase of README.md and README.fr.md:
# the pictures in docs/showcase/*.png and the raw screen recording the demo video
# is cut from (docs/video/public/walk.mp4, with docs/video/public/marks.json).
#
# It creates a throwaway iPhone 17 Pro simulator on the newest iOS 26+ runtime,
# pins its status bar, builds the app and its UI tests, records the simulator's
# screen while the XCUITest `ShowcaseScreenshotsUITests` signs in to an Immich
# server and walks through every feature, then deletes the simulator. Each
# `MARK <name> <unix time>` line of the walk becomes an offset in marks.json.
#
#   SWIMMICH_SHOWCASE_SERVER    the Immich server (required)
#   SWIMMICH_SHOWCASE_EMAIL     its account (required)
#   SWIMMICH_SHOWCASE_PASSWORD  its password (required)
#   SWIMMICH_SHOWCASE_ALBUM     album the album features run on (default "Mountains")
#   SWIMMICH_SHOWCASE_QUERY     words the search reel is made of (default "beach")
#   SWIMMICH_SHOWCASE_PERSON    person Growing Up runs on (default "The 11x Developer")
#   SWIMMICH_SHOWCASE_DEVICE    a device's UDID: takes Growing Up there (Vision), the app signed out
#
# Then `cd docs/video && npm install && npm run render` makes the video.
#
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "showcase.sh: $*" >&2; exit 1; }
: "${SWIMMICH_SHOWCASE_SERVER:?set SWIMMICH_SHOWCASE_SERVER}"
: "${SWIMMICH_SHOWCASE_EMAIL:?set SWIMMICH_SHOWCASE_EMAIL}"
: "${SWIMMICH_SHOWCASE_PASSWORD:?set SWIMMICH_SHOWCASE_PASSWORD}"

OUT="$PWD/docs/showcase"
VIDEO_PUBLIC="$PWD/docs/video/public"
BUILD_DIR=build/showcase
LOG="$BUILD_DIR/walk.log"
APP_BUNDLE_ID=fr.millianlmx.immich-ios

# A device instead of a simulator (`SWIMMICH_SHOWCASE_DEVICE=<udid>`): Growing Up
# needs Vision, which a simulator cannot run. Only the people step runs; its
# picture comes from the test's attachments and the clip is the film the app
# exported, copied from its temporary folder. The app must be signed out.
if [ -n "${SWIMMICH_SHOWCASE_DEVICE:-}" ]; then
  device="$SWIMMICH_SHOWCASE_DEVICE"
  mkdir -p "$BUILD_DIR/device" "$OUT" "$VIDEO_PUBLIC"
  xcodegen generate --quiet || fail "xcodegen generate failed"
  xcodebuild build-for-testing -quiet -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \
    -destination "id=$device" -allowProvisioningUpdates -derivedDataPath "$BUILD_DIR/device" \
    DEVELOPMENT_TEAM="$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' project.yml | head -n 1)" \
    >"$BUILD_DIR/device-build.log" 2>&1 \
    || { grep ' error: ' "$BUILD_DIR/device-build.log" | head -n 3 >&2 || true; fail "build-for-testing for the device failed"; }
  rm -rf "$BUILD_DIR/device.xcresult" "$VIDEO_PUBLIC/growingup.mp4"
  TEST_RUNNER_SWIMMICH_SHOWCASE_DIR="/tmp/showcase" \
  TEST_RUNNER_SWIMMICH_SHOWCASE_SERVER="$SWIMMICH_SHOWCASE_SERVER" \
  TEST_RUNNER_SWIMMICH_SHOWCASE_EMAIL="$SWIMMICH_SHOWCASE_EMAIL" \
  TEST_RUNNER_SWIMMICH_SHOWCASE_PASSWORD="$SWIMMICH_SHOWCASE_PASSWORD" \
  TEST_RUNNER_SWIMMICH_SHOWCASE_PERSON="${SWIMMICH_SHOWCASE_PERSON:-The 11x Developer}" \
  TEST_RUNNER_SWIMMICH_SHOWCASE_ONLY="people" \
    xcodebuild test-without-building -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \
    -destination "id=$device" -derivedDataPath "$BUILD_DIR/device" \
    -only-testing:ImmichSwiftUIUITests/ShowcaseScreenshotsUITests \
    -resultBundlePath "$BUILD_DIR/device.xcresult" >"$BUILD_DIR/device-walk.log" 2>&1 &
  walk=$!
  # The exported film is deleted when Growing Up closes: the walk holds the
  # screen open after `EXPORTED growingup`, and the film is copied meanwhile.
  while kill -0 "$walk" 2>/dev/null; do
    if grep -q '^EXPORTED growingup' "$BUILD_DIR/device-walk.log" && [ ! -f "$VIDEO_PUBLIC/growingup.mp4" ]; then
      film="$(xcrun devicectl device info files --device "$device" --domain-type appDataContainer \
        --domain-identifier "$APP_BUNDLE_ID" --subdirectory tmp 2>/dev/null | grep -o 'growing-up-[A-F0-9-]*\.mp4' | tail -n 1)"
      if [ -n "$film" ] && xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
        --domain-identifier "$APP_BUNDLE_ID" --source "tmp/$film" --destination "$VIDEO_PUBLIC/growingup.mp4" >/dev/null; then
        echo "showcase.sh: wrote docs/video/public/growingup.mp4"
      fi
    fi
    sleep 3
  done
  wait "$walk" || true
  rm -rf "$BUILD_DIR/attachments"
  xcrun xcresulttool export attachments --path "$BUILD_DIR/device.xcresult" --output-path "$BUILD_DIR/attachments" \
    >/dev/null || fail "could not read the walk's attachments"
  python3 - "$BUILD_DIR/attachments" "$OUT" <<'PY'
import json, shutil, sys
from pathlib import Path
folder, out = Path(sys.argv[1]), Path(sys.argv[2])
for test in json.loads((folder / "manifest.json").read_text()):
    for item in test.get("attachments", []):
        name = item.get("suggestedHumanReadableName", "").split("_")[0]
        if name == "growingup":
            shutil.copy(folder / item["exportedFileName"], out / "growingup.png")
            print("showcase.sh: wrote docs/showcase/growingup.png")
PY
  [ -f "$VIDEO_PUBLIC/growingup.mp4" ] || fail "the exported Growing Up film was not copied off the device (see $BUILD_DIR/device-walk.log)"
  exit 0
fi

runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
found = [r for r in json.load(sys.stdin)["runtimes"]
         if r["isAvailable"] and r["name"].startswith("iOS ") and int(r["version"].split(".")[0]) >= 26]
if not found:
    sys.exit("showcase.sh: no iOS 26+ simulator runtime installed")
print(max(found, key=lambda r: [int(p) for p in r["version"].split(".")])["identifier"])
')" || fail "no usable iOS 26+ simulator runtime"

xcodegen generate --quiet || fail "xcodegen generate failed"

udid=""
recorder=""
cleanup() {
  [ -z "$recorder" ] || kill -INT "$recorder" 2>/dev/null || true
  if [ -n "$udid" ]; then
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl delete "$udid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

udid="$(xcrun simctl create swimmich-showcase com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime")" \
  || fail "could not create the iPhone 17 Pro simulator on $runtime"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
# The system's prompts ("Save password?") in English, like the app: one language in the pictures.
xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array en
xcrun simctl spawn "$udid" defaults write -g AppleLocale en_US
xcrun simctl shutdown "$udid"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3

mkdir -p "$BUILD_DIR" "$OUT" "$VIDEO_PUBLIC"
xcodebuild build-for-testing -quiet -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$BUILD_DIR" >"$BUILD_DIR/build.log" 2>&1 \
  || { grep ' error: ' "$BUILD_DIR/build.log" | head -n 3 >&2 || true; fail "build-for-testing failed"; }

rm -f "$OUT"/*.png "$VIDEO_PUBLIC/walk.mp4"
xcrun simctl io "$udid" recordVideo --codec=h264 --force "$VIDEO_PUBLIC/walk.mp4" 2>/dev/null &
recorder=$!
# The recording starts when its first frame lands: give it a moment, then note the time.
sleep 2
start="$(python3 -c 'import time; print(time.time())')"

rc=0
TEST_RUNNER_SWIMMICH_SHOWCASE_DIR="$OUT" \
TEST_RUNNER_SWIMMICH_SHOWCASE_SERVER="$SWIMMICH_SHOWCASE_SERVER" \
TEST_RUNNER_SWIMMICH_SHOWCASE_EMAIL="$SWIMMICH_SHOWCASE_EMAIL" \
TEST_RUNNER_SWIMMICH_SHOWCASE_PASSWORD="$SWIMMICH_SHOWCASE_PASSWORD" \
TEST_RUNNER_SWIMMICH_SHOWCASE_ALBUM="${SWIMMICH_SHOWCASE_ALBUM:-Mountains}" \
TEST_RUNNER_SWIMMICH_SHOWCASE_QUERY="${SWIMMICH_SHOWCASE_QUERY:-beach}" \
TEST_RUNNER_SWIMMICH_SHOWCASE_PERSON="${SWIMMICH_SHOWCASE_PERSON:-The 11x Developer}" \
  xcodebuild test-without-building -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$BUILD_DIR" \
  -only-testing:ImmichSwiftUIUITests/ShowcaseScreenshotsUITests >"$LOG" 2>&1 || rc=$?

kill -INT "$recorder" 2>/dev/null || true
wait "$recorder" 2>/dev/null || true
recorder=""

grep -E '^MARK ' "$LOG" | python3 -c '
import json, sys
start = float(sys.argv[1])
marks = {}
for line in sys.stdin:
    _, name, at = line.split()
    marks[name] = round(float(at) - start, 2)
json.dump(marks, open(sys.argv[2], "w"), indent=2)
print("showcase.sh: marks", marks)
' "$start" "$VIDEO_PUBLIC/marks.json"

grep -E '^SHOT ' "$LOG" | sed 's/^/showcase.sh: /' || true
grep -E 'error: -\[' "$LOG" | sed 's/^.*error: /showcase.sh: step failed: /' >&2 || true
[ "$rc" -eq 0 ] || echo "showcase.sh: the walk reported failures (see $LOG); the pictures it took are kept" >&2
