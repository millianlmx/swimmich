#!/usr/bin/env bash
# Archives Swimmich in Release and uploads it to App Store Connect (TestFlight).
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=/path/AuthKey_….p8 Scripts/release.sh [marketing-version]
#
# Signing is automatic: the App Store Connect API key lets xcodebuild create or
# refresh the distribution certificate and the App Store profiles of the app,
# the widget and the share extension (-allowProvisioningUpdates), with no Apple
# ID signed in to Xcode. The key needs the App Manager role.
#
# The build number is the UTC time (YYYYMMDD.HHMM, each part under 2^31): it
# only grows, and never collides with a build uploaded by hand from Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ASC_KEY_ID:?App Store Connect API key id (ASC_KEY_ID) is required}"
: "${ASC_ISSUER_ID:?App Store Connect issuer id (ASC_ISSUER_ID) is required}"
: "${ASC_KEY_PATH:?path to the AuthKey_<id>.p8 file (ASC_KEY_PATH) is required}"
[[ -f "$ASC_KEY_PATH" ]] || { echo "release.sh: $ASC_KEY_PATH not found" >&2; exit 2; }

VERSION="${1:-}"
BUILD="$(date -u +%Y%m%d.%H%M)"
OUT="${SWIMMICH_RELEASE_DIR:-build/release}"
CACHE="${SWIMMICH_CI_CACHE:-$HOME/Library/Caches/swimmich-ci}"

auth=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)
versions=(CURRENT_PROJECT_VERSION="$BUILD")
[[ -n "$VERSION" ]] && versions+=(MARKETING_VERSION="$VERSION")

xcodegen generate --quiet
rm -rf "$OUT"
mkdir -p "$OUT"

echo "release.sh: archiving ${VERSION:-<project version>} ($BUILD)"
xcodebuild archive -quiet \
  -project ImmichSwiftUI.xcodeproj \
  -scheme ImmichSwiftUI \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$OUT/Swimmich.xcarchive" \
  -clonedSourcePackagesDirPath "$CACHE/SourcePackages" \
  "${auth[@]}" "${versions[@]}"

cat >"$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>teamID</key>
  <string>2MJF39L8VY</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST

echo "release.sh: uploading to App Store Connect"
xcodebuild -exportArchive -quiet \
  -archivePath "$OUT/Swimmich.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" \
  "${auth[@]}"

echo "release.sh: build $BUILD uploaded; TestFlight processes it in a few minutes"
