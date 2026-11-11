#!/usr/bin/env bash
# The CI of swimmich, runnable as is on any Mac with Xcode and XcodeGen.
#
#   Scripts/ci.sh
#
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
# output" and no usable diagnostic). On failure: print the compiler errors,
# purge that cache and build once more; a genuine source error fails twice.
build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT
if ! xcodebuild build-for-testing "${common[@]}" -quiet 2>&1 | tee "$build_log"; then
  echo "ci.sh: build failed; compiler errors of the first attempt:" >&2
  grep -E "error:" "$build_log" >&2 || true
  echo "ci.sh: purging $CACHE/DerivedData and building again" >&2
  rm -rf "$CACHE/DerivedData"
  xcodebuild build-for-testing "${common[@]}"
fi

rm -rf "$RESULT"
mkdir -p "$(dirname "$RESULT")"
xcodebuild test-without-building "${common[@]}" -quiet \
  -only-testing:ImmichSwiftUITests \
  -resultBundlePath "$RESULT"
