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
# With SWIMMICH_SIGN_IDENTITY set (Scripts/release.sh, CI release only) signing
# is manual instead: the identity (SHA-1 of the certificate) is looked up in
# SWIMMICH_SIGN_KEYCHAIN, the profiles are the installed ones named by
# SWIMMICH_PROFILE_APP / _WIDGETS / _SHARE (UUIDs), and no Apple ID nor
# -allowProvisioningUpdates is involved. This mode only exports.
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
BUILD="${SWIMMICH_BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M)}"
OUT="${SWIMMICH_IPA_DIR:-build/ipa}"
CACHE="${SWIMMICH_CI_CACHE:-$HOME/Library/Caches/swimmich-ci}"

MANUAL=0
auth=()
if [[ -n "${SWIMMICH_SIGN_IDENTITY:-}" ]]; then
  MANUAL=1
  for var in SWIMMICH_SIGN_KEYCHAIN SWIMMICH_PROFILE_APP SWIMMICH_PROFILE_WIDGETS SWIMMICH_PROFILE_SHARE; do
    [[ -n "${!var:-}" ]] || { echo "ipa.sh: $var is required with SWIMMICH_SIGN_IDENTITY" >&2; exit 2; }
  done
  # OTHER_CODE_SIGN_FLAGS is split at spaces.
  [[ "$SWIMMICH_SIGN_KEYCHAIN" != *" "* ]] \
    || { echo "ipa.sh: SWIMMICH_SIGN_KEYCHAIN must not contain spaces" >&2; exit 2; }
  [[ "$UPLOAD" == 0 ]] \
    || { echo "ipa.sh: manual signing only exports; Scripts/release.sh uploads" >&2; exit 2; }
  echo "ipa.sh: signing manually with $SWIMMICH_SIGN_IDENTITY"
elif [[ -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" || -n "${ASC_KEY_PATH:-}" ]]; then
  : "${ASC_KEY_ID:?ASC_KEY_ID is required with an API key}"
  : "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required with an API key}"
  : "${ASC_KEY_PATH:?ASC_KEY_PATH is required with an API key}"
  [[ -f "$ASC_KEY_PATH" ]] || { echo "ipa.sh: $ASC_KEY_PATH not found" >&2; exit 2; }
  auth=(
    -allowProvisioningUpdates
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
  echo "ipa.sh: signing with App Store Connect API key $ASC_KEY_ID"
else
  auth=(-allowProvisioningUpdates)
  echo "ipa.sh: signing with the Apple ID signed in to Xcode"
fi

versions=(CURRENT_PROJECT_VERSION="$BUILD")
[[ -n "$VERSION" ]] && versions+=(MARKETING_VERSION="$VERSION")

# Name of an installed provisioning profile, from its UUID.
profile_name() {
  local file="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$1.mobileprovision"
  [[ -f "$file" ]] || { echo "ipa.sh: profile $1 is not installed" >&2; exit 2; }
  security cms -D -i "$file" | python3 Scripts/release_checks.py profile-field /dev/stdin Name
}

# The manual signing settings come from project-release-signing.yml, included by
# project.yml only when SWIMMICH_RELEASE_SIGNING is set; without it the project
# is the one `main` has always been signed with.
if [[ "$MANUAL" == 1 ]]; then
  specifier_app=$(profile_name "$SWIMMICH_PROFILE_APP")
  specifier_widgets=$(profile_name "$SWIMMICH_PROFILE_WIDGETS")
  specifier_share=$(profile_name "$SWIMMICH_PROFILE_SHARE")
  env SWIMMICH_RELEASE_SIGNING=YES \
    SWIMMICH_PROFILE_SPECIFIER_APP="$specifier_app" \
    SWIMMICH_PROFILE_SPECIFIER_WIDGETS="$specifier_widgets" \
    SWIMMICH_PROFILE_SPECIFIER_SHARE="$specifier_share" \
    xcodegen generate --quiet
else
  env -u SWIMMICH_RELEASE_SIGNING xcodegen generate --quiet
fi
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
  ${auth[@]+"${auth[@]}"} "${versions[@]}"

destination=export
[[ "$UPLOAD" == 1 ]] && destination=upload
if [[ "$MANUAL" == 1 ]]; then
  signing_xml=$(cat <<XML
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>$SWIMMICH_SIGN_IDENTITY</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>fr.millianlmx.immich-ios</key>
    <string>$SWIMMICH_PROFILE_APP</string>
    <key>fr.millianlmx.immich-ios.widgets</key>
    <string>$SWIMMICH_PROFILE_WIDGETS</string>
    <key>fr.millianlmx.immich-ios.share-extension</key>
    <string>$SWIMMICH_PROFILE_SHARE</string>
  </dict>
XML
)
else
  signing_xml=$(cat <<XML
  <key>signingStyle</key>
  <string>automatic</string>
XML
)
fi
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
$signing_xml
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
  ${auth[@]+"${auth[@]}"}

if [[ "$UPLOAD" == 1 ]]; then
  echo "ipa.sh: build $BUILD uploaded; TestFlight processes it in a few minutes"
else
  mv "$OUT"/export/*.ipa "$OUT/Swimmich.ipa"
  # Refuse an unsigned or ad-hoc result: the IPA must carry Apple Distribution.
  app_dir="$OUT/verify"
  rm -rf "$app_dir" && mkdir -p "$app_dir"
  unzip -q "$OUT/Swimmich.ipa" -d "$app_dir"
  # The packaging App Store Connect rejects (ITMS-90206): refuse it before any upload.
  python3 Scripts/release_checks.py payload "$app_dir/Payload" || exit 1
  codesign --verify --deep --strict "$app_dir"/Payload/*.app
  authority=$(codesign -dvv "$app_dir"/Payload/*.app 2>&1)
  [[ "$authority" == *"Authority=Apple Distribution"* ]] \
    || { echo "ipa.sh: the app is not signed with Apple Distribution" >&2; exit 1; }
  if [[ "$MANUAL" == 1 ]]; then
    # The certificate and the profile of the app and of each extension are the
    # ones given as secrets, not whatever else the Mac holds.
    certs=$(mktemp -d)
    trap 'rm -rf "$certs"' EXIT
    app_bundle=$(echo "$app_dir"/Payload/*.app)
    observed=()
    for entry in "app:$app_bundle:$SWIMMICH_PROFILE_APP" \
      "widgets:$app_bundle/PlugIns/ImmichWidgets.appex:$SWIMMICH_PROFILE_WIDGETS" \
      "share-extension:$app_bundle/PlugIns/ImmichShareExtension.appex:$SWIMMICH_PROFILE_SHARE"; do
      label=${entry%%:*}
      rest=${entry#*:}
      bundle=${rest%:*}
      expected=${rest##*:}
      codesign -d --extract-certificates="$certs/$label." "$bundle" 2>/dev/null
      sha1=$(shasum -a 1 "$certs/$label.0" | awk '{print toupper($1)}')
      embedded=$(security cms -D -i "$bundle/embedded.mobileprovision" \
        | python3 Scripts/release_checks.py profile-field /dev/stdin UUID)
      observed+=("$label=$sha1,$embedded,$expected")
    done
    python3 Scripts/release_checks.py signing "$SWIMMICH_SIGN_IDENTITY" "${observed[@]}" || exit 1
  fi
  echo "ipa.sh: $OUT/Swimmich.ipa ($BUILD), signed Apple Distribution"
fi
