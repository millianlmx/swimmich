#!/usr/bin/env bash
# Archives, signs and uploads Swimmich to App Store Connect from CI secrets only.
#
#   Scripts/release.sh <tag>     tag is v<major>[.<minor>[.<patch>]]
#   Scripts/release.sh --cleanup remove the signing state of a killed run
#
# Reads the 8 secrets of Scripts/release_checks.py (REQUIRED_SECRETS) from the
# environment, which the "App Store upload" job of .github/workflows/ci.yml fills
# from the GitHub Environment `app-store`. Signing is manual, from a temporary
# keychain of the job: no Apple ID, no -allowProvisioningUpdates. Every file
# derived from a secret lives under $S (outside the repository) and is removed
# on exit, even on failure; the keychain search list, shared by the runners of
# this Mac, only gains the temporary keychain while Scripts/ipa.sh runs. The
# session keychain is never touched. Never `set -x`: it would print secrets.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

CHECKS=(python3 Scripts/release_checks.py)

usage() {
  echo "usage: Scripts/release.sh <tag> | --cleanup" >&2
  exit 2
}
[[ $# -eq 1 && ("$1" == "--cleanup" || "$1" != -*) ]] || usage

# Runs the command given and keeps its non-empty output lines in KEYCHAIN_LIST
# (bash 3.2, the macOS default, has no mapfile).
KEYCHAIN_LIST=()
read_keychain_list() {
  KEYCHAIN_LIST=()
  local line
  while IFS= read -r line; do
    KEYCHAIN_LIST+=("$line")
  done < <("$@")
}
without_keychain() { security list-keychains -d user | "${CHECKS[@]}" search-list-without "$1"; }
whole_list() { security list-keychains -d user | "${CHECKS[@]}" search-list; }

fail() { # <title> <message>
  echo "::error title=$1::$2"
  exit 1
}

# Takes the temporary keychain out of the search list, keeping every other entry
# in its current order. Never re-applies a snapshot: another process may have
# added a keychain since.
drop_from_search_list() {
  read_keychain_list whole_list
  local all=${#KEYCHAIN_LIST[@]}
  read_keychain_list without_keychain "$1"
  if ((all != ${#KEYCHAIN_LIST[@]})) && ((${#KEYCHAIN_LIST[@]} > 0)); then
    security list-keychains -d user -s "${KEYCHAIN_LIST[@]}"
  fi
}

# Idempotent. Returns 1 when the verification at the end finds a leftover.
clean_state() {
  if [[ ! -e "$S" ]]; then
    echo "release.sh: no signing state to clean"
    return 0
  fi
  local kc="$S/release.keychain-db" status=0 path
  drop_from_search_list "$kc" || true
  [[ -e "$kc" ]] && { security delete-keychain "$kc" || true; }
  if [[ -f "$S/installed-profiles.txt" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] && rm -f "$path"
    done <"$S/installed-profiles.txt"
  fi

  read_keychain_list whole_list || true
  local before=${#KEYCHAIN_LIST[@]}
  read_keychain_list without_keychain "$kc"
  if ((before != ${#KEYCHAIN_LIST[@]})); then
    echo "::error title=Signing state::the release keychain is still in the keychain search list"
    status=1
  fi
  if [[ -f "$S/search-list.txt" ]]; then
    local lost=()
    while IFS= read -r path; do
      lost+=("$path")
    done < <(security list-keychains -d user | "${CHECKS[@]}" search-list-lost "$S/search-list.txt" || true)
    if ((${#lost[@]} > 0)); then
      echo "::error title=Signing state::the keychain search list lost ${lost[*]}"
      status=1
    fi
  fi
  if [[ -f "$S/installed-profiles.txt" ]]; then
    while IFS= read -r path; do
      if [[ -n "$path" && -e "$path" ]]; then
        echo "::error title=Signing state::provisioning profile $path is still installed"
        status=1
      fi
    done <"$S/installed-profiles.txt"
  fi
  if [[ -s "$S/identity.txt" && -f "$S/identities-before.txt" ]]; then
    local id now was
    id=$(<"$S/identity.txt")
    now=$(security find-identity -v -p codesigning 2>/dev/null | grep -c "$id" || true)
    was=$(grep -c "$id" "$S/identities-before.txt" || true)
    if ((now > was)); then
      echo "::error title=Signing state::the session keychain gained the release identity"
      status=1
    fi
  fi
  rm -rf "$S"
  return "$status"
}

finish() {
  local rc=$?
  trap - EXIT INT TERM
  clean_state || rc=1
  exit "$rc"
}

# 1-3: nothing touches a signing tool before the secrets, the tag and the state
# directory are known good.
if [[ "$1" == "--cleanup" ]]; then
  S=$("${CHECKS[@]}" state-dir) || { printf '%s\n' "$S"; exit 1; }
  clean_state
  exit $?
fi
tag="$1"
"${CHECKS[@]}" secrets || exit 1
version=$("${CHECKS[@]}" version "$tag") || { printf '%s\n' "$version"; exit 1; }
S=$("${CHECKS[@]}" state-dir) || { printf '%s\n' "$S"; exit 1; }

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ -e "$S" ]] && { clean_state || exit 1; }

mkdir -p "$S"
kc="$S/release.keychain-db"
whole_list >"$S/search-list.txt"
security find-identity -v -p codesigning >"$S/identities-before.txt" || true

# Temporary keychain, and the Apple Distribution certificate in it.
pw=$(openssl rand -base64 24)
echo "::add-mask::$pw"
security create-keychain -p "$pw" "$kc"
security set-keychain-settings -lut 21600 "$kc"
security unlock-keychain -p "$pw" "$kc"
if ! { printf '%s' "$APPLE_DISTRIBUTION_P12_BASE64" | base64 --decode >"$S/dist.p12" \
  && security import "$S/dist.p12" -k "$kc" -P "$APPLE_DISTRIBUTION_P12_PASSWORD" \
    -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1; } 2>/dev/null; then
  rm -f "$S/dist.p12"
  fail "Signing secret" "APPLE_DISTRIBUTION_P12_BASE64 / APPLE_DISTRIBUTION_P12_PASSWORD: the .p12 could not be imported (wrong password or not a PKCS#12)"
fi
rm -f "$S/dist.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" >/dev/null 2>&1

identities=$(security find-identity -v -p codesigning "$kc" | grep '"Apple Distribution: ' || true)
count=$(printf '%s' "$identities" | grep -c . || true)
[[ "$count" == 1 ]] \
  || fail "Signing secret" "APPLE_DISTRIBUTION_P12_BASE64 must hold exactly one valid Apple Distribution identity (found $count)"
IDENTITY=$(printf '%s' "$identities" | awk '{print $2}')
echo "$IDENTITY" >"$S/identity.txt"
if grep -q "$IDENTITY" "$S/identities-before.txt"; then
  echo "::notice title=Signing::the keychain search list already holds certificate $IDENTITY; the export may sign with that copy of the same certificate"
fi

# Provisioning profiles: checked against the certificate, installed only when
# absent (a profile a human installed is never replaced nor removed).
secret_of() {
  case "$1" in
    app) echo PROFILE_APP_BASE64 ;;
    widgets) echo PROFILE_WIDGETS_BASE64 ;;
    share-extension) echo PROFILE_SHARE_EXTENSION_BASE64 ;;
  esac
}
profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
UUID_APP="" UUID_WIDGETS="" UUID_SHARE=""
for label in app widgets share-extension; do
  secret=$(secret_of "$label")
  { printf '%s' "${!secret}" | base64 --decode >"$S/$label.mobileprovision" \
    && security cms -D -i "$S/$label.mobileprovision" >"$S/$label.plist"; } 2>/dev/null \
    || fail "Provisioning profile" "$secret: is not a provisioning profile"
  uuid=$("${CHECKS[@]}" profile "$S/$label.plist" "$label" "$IDENTITY") || { printf '%s\n' "$uuid"; exit 1; }
  mkdir -p "$profiles_dir"
  if [[ ! -e "$profiles_dir/$uuid.mobileprovision" ]]; then
    cp "$S/$label.mobileprovision" "$profiles_dir/$uuid.mobileprovision"
    echo "$profiles_dir/$uuid.mobileprovision" >>"$S/installed-profiles.txt"
  fi
  case "$label" in
    app) UUID_APP=$uuid ;;
    widgets) UUID_WIDGETS=$uuid ;;
    share-extension) UUID_SHARE=$uuid ;;
  esac
done

# App Store Connect API key, used by the upload only.
mkdir -p "$S/private_keys"
chmod 700 "$S/private_keys"
key="$S/private_keys/AuthKey_$ASC_KEY_ID.p8"
printf '%s' "$ASC_KEY_P8_BASE64" | base64 --decode >"$key" 2>/dev/null || true
chmod 600 "$key" 2>/dev/null || true
# The header is split so that a scan of the tracked files for key material does
# not match this script.
[[ "$(head -c 27 "$key" 2>/dev/null)" == "-----BEGIN PRIV""ATE KEY-----" ]] \
  || fail "Signing secret" "ASC_KEY_P8_BASE64 is not a base64-encoded .p8 key"

# Archive and export. The temporary keychain is in the search list for this
# window only (Xcode finds an identity through that shared list).
BUILD=$(date -u +%Y%m%d.%H%M)
read_keychain_list without_keychain "$kc"
security list-keychains -d user -s "$kc" ${KEYCHAIN_LIST[@]+"${KEYCHAIN_LIST[@]}"}
unset_secrets=()
for name in $("${CHECKS[@]}" secret-names); do
  unset_secrets+=(-u "$name")
done
rc=0
env ${unset_secrets[@]+"${unset_secrets[@]}"} \
  SWIMMICH_BUILD_NUMBER="$BUILD" \
  SWIMMICH_SIGN_IDENTITY="$IDENTITY" \
  SWIMMICH_SIGN_KEYCHAIN="$kc" \
  SWIMMICH_PROFILE_APP="$UUID_APP" \
  SWIMMICH_PROFILE_WIDGETS="$UUID_WIDGETS" \
  SWIMMICH_PROFILE_SHARE="$UUID_SHARE" \
  Scripts/ipa.sh "$version" || rc=$?
drop_from_search_list "$kc"
[[ "$rc" == 0 ]] || exit 1

if API_PRIVATE_KEYS_DIR="$S/private_keys" xcrun altool --upload-app -f build/ipa/Swimmich.ipa -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"; then
  echo "::notice title=App Store Connect::Swimmich $version ($BUILD) uploaded; TestFlight processes it, then waits for the export compliance answer"
else
  fail "App Store Connect" "upload of $version ($BUILD) failed, see the \"Archive, sign and upload\" step"
fi
