#!/usr/bin/env bash
# Archives Swimmich in Release and exports the IPA signed for the App Store.
#
#   Scripts/ipa.sh [--upload] [marketing-version]
#
# Output: build/ipa/Swimmich.ipa (and the .xcarchive next to it). With
# --upload, the export is sent to App Store Connect (TestFlight) instead; that
# needs the app's record on App Store Connect (bundle fr.millianlmx.immich-ios).
#
# Signing is automatic (-allowProvisioningUpdates): xcodebuild creates or
# refreshes the Apple Distribution certificate and the App Store profiles of the
# app, the widget and the share extension. It authenticates with, in order:
#   - an App Store Connect API key (App Manager role), when all three ASC_*
#     variables (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH) are set: any Mac;
#   - otherwise the Apple ID signed in to Xcode (Settings › Accounts) of the
#     user running the script: only on that Mac, in that user's session.
#
# The build number is the UTC time (YYYYMMDD.HHMM, each part under 2^31): it
# only grows, and never collides with a build uploaded by hand from Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

UPLOAD=0
if [[ "${1:-}" == "--upload" ]]; then
  UPLOAD=1
  shift
fi
VERSION="${1:-}"
BUILD="$(date -u +%Y%m%d.%H%M)"
OUT="${SWIMMICH_IPA_DIR:-build/ipa}"
CACHE="${SWIMMICH_CI_CACHE:-$HOME/Library/Caches/swimmich-ci}"

auth=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" || -n "${ASC_KEY_PATH:-}" ]]; then
  : "${ASC_KEY_ID:?ASC_KEY_ID is required with an API key}"
  : "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required with an API key}"
  : "${ASC_KEY_PATH:?ASC_KEY_PATH is required with an API key}"
  [[ -f "$ASC_KEY_PATH" ]] || { echo "ipa.sh: $ASC_KEY_PATH not found" >&2; exit 2; }
  auth+=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
  echo "ipa.sh: signing with App Store Connect API key $ASC_KEY_ID"
else
  echo "ipa.sh: signing with the Apple ID signed in to Xcode"
fi

versions=(CURRENT_PROJECT_VERSION="$BUILD")
[[ -n "$VERSION" ]] && versions+=(MARKETING_VERSION="$VERSION")

xcodegen generate --quiet
rm -rf "$OUT"
mkdir -p "$OUT"

echo "ipa.sh: archiving ${VERSION:-<project version>} ($BUILD)"
xcodebuild archive -quiet \
  -project ImmichSwiftUI.xcodeproj \
  -scheme ImmichSwiftUI \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$OUT/Swimmich.xcarchive" \
  -clonedSourcePackagesDirPath "$CACHE/SourcePackages" \
  "${auth[@]}" "${versions[@]}"

destination=export
[[ "$UPLOAD" == 1 ]] && destination=upload
cat >"$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>$destination</string>
  <key>teamID</key>
  <string>2MJF39L8VY</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST

echo "ipa.sh: exporting ($destination)"
xcodebuild -exportArchive -quiet \
  -archivePath "$OUT/Swimmich.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" \
  "${auth[@]}"

if [[ "$UPLOAD" == 1 ]]; then
  echo "ipa.sh: build $BUILD uploaded; TestFlight processes it in a few minutes"
else
  mv "$OUT"/export/*.ipa "$OUT/Swimmich.ipa"
  # Refuse an unsigned or ad-hoc result: the IPA must carry Apple Distribution.
  app_dir="$OUT/verify"
  rm -rf "$app_dir" && mkdir -p "$app_dir"
  unzip -q "$OUT/Swimmich.ipa" -d "$app_dir"
  codesign --verify --deep --strict "$app_dir"/Payload/*.app
  authority=$(codesign -dvv "$app_dir"/Payload/*.app 2>&1)
  [[ "$authority" == *"Authority=Apple Distribution"* ]] \
    || { echo "ipa.sh: the app is not signed with Apple Distribution" >&2; exit 1; }
  echo "ipa.sh: $OUT/Swimmich.ipa ($BUILD), signed Apple Distribution"
fi
