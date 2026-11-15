#!/usr/bin/env bash
#
# Scripts/ci-readme-screenshots.sh — the CI job "README screenshots".
#
# The runner is the only Mac that can take the pictures of README.md and
# README.fr.md, and a job cannot push to the branch it tests (a push by
# GITHUB_TOKEN starts no workflow, and the service owns that branch). So:
#
# * the five docs/screenshots/<name>.png are committed: nothing to do, exit 0;
# * one is missing: run Scripts/screenshots.sh. On failure, say why in
#   `::error` annotations (the job logs are admin-only). On success, push the five
#   PNGs to the branch ci/readme-screenshots (force-pushed, one commit holding only
#   them and SOURCE.txt) and fail, naming the branch and the commit to commit from.
#
# The job stays red until the PNGs are committed on the tested branch. It never
# commits or pushes anything to that branch.
#
# Reads GITHUB_SHA, GITHUB_REF_NAME, GITHUB_REPOSITORY and GITHUB_TOKEN.
#
set -euo pipefail
cd "$(dirname "$0")/.."

NAMES=(timeline viewer albums search backup)
BRANCH=ci/readme-screenshots
TITLE="::error title=README screenshots::"
BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"

missing=()
for name in "${NAMES[@]}"; do
  [ -f "docs/screenshots/$name.png" ] || missing+=("$name")
done
if [ "${#missing[@]}" -eq 0 ]; then
  echo "ci-readme-screenshots.sh: the five README screenshots are committed, nothing to do"
  exit 0
fi

# One annotation: %, carriage return and line feed would otherwise cut the message.
annotate() {
  local text="$1" percent='%' cr=$'\r' lf=$'\n'
  text=${text//"$percent"/%25}
  text=${text//"$cr"/%0D}
  text=${text//"$lf"/%0A}
  printf '%s%s\n' "$TITLE" "$text"
}

stderr_file=""
work=""
cleanup() { rm -rf "$stderr_file" "$work"; }
trap cleanup EXIT

stderr_file="$(mktemp)" || { rc=$?; annotate "mktemp failed (exit $rc)"; exit 1; }

echo "ci-readme-screenshots.sh: missing ${missing[*]}; running Scripts/screenshots.sh"
rc=0
Scripts/screenshots.sh 2>"$stderr_file" || rc=$?
cat "$stderr_file" >&2

if [ "$rc" -ne 0 ]; then
  message="Scripts/screenshots.sh exited $rc"
  if ! grep -q '^screenshots\.sh:' "$stderr_file"; then
    last="$(grep -v '^[[:space:]]*$' "$stderr_file" | tail -n 5 || true)"
    if [ -n "$last" ]; then
      message="$message; last stderr lines:"$'\n'"$last"
    else
      message="$message with nothing on stderr"
    fi
  fi
  annotate "$message"

  prefixed="$(grep '^screenshots\.sh:' "$stderr_file" | head -n 4 || true)"
  while IFS= read -r line; do
    [ -z "$line" ] || annotate "$line"
  done <<<"$prefixed"

  result=build/screenshots/ReadmeScreenshots.xcresult
  if [ -e "$result" ] && command -v xcrun >/dev/null 2>&1; then
    summary="$(xcrun xcresulttool get test-results summary --path "$result" 2>/dev/null)" || summary=""
    if [ -n "$summary" ]; then
      printf '%s' "$summary" | python3 -c '
import json, sys
try:
    failures = json.load(sys.stdin).get("testFailures") or []
except Exception:
    raise SystemExit
for failure in failures[:5]:
    name = failure.get("testIdentifierString") or failure.get("testName") or "?"
    text = " ".join(str(failure.get("failureText", "")).split())
    message = ("%s: %s" % (name, text)).replace("%", "%25")
    print("::error title=README screenshots::" + message)
' || true
    fi
  fi
  exit 1
fi

[ -n "${GITHUB_SHA:-}" ] || { annotate "GITHUB_SHA is not set"; exit 1; }
[ -n "${GITHUB_REF_NAME:-}" ] || { annotate "GITHUB_REF_NAME is not set"; exit 1; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { annotate "GITHUB_REPOSITORY is not set"; exit 1; }
[ -n "${GITHUB_TOKEN:-}" ] || { annotate "GITHUB_TOKEN is not set"; exit 1; }

# Runs one step of the publication; a failure names the step.
step() {
  local label="$1" status=0
  shift
  "$@" >/dev/null || status=$?
  [ "$status" -eq 0 ] || { annotate "$label failed (exit $status)"; exit 1; }
}
copy_pictures() {
  local name
  mkdir -p "$work/docs/screenshots" || return
  for name in "${NAMES[@]}"; do cp "docs/screenshots/$name.png" "$work/docs/screenshots/$name.png" || return; done
}
write_source() { printf '%s %s\n' "$GITHUB_SHA" "$GITHUB_REF_NAME" >"$work/SOURCE.txt"; }

work="$(mktemp -d)" || { rc=$?; annotate "mktemp failed (exit $rc)"; exit 1; }
step "git init" git init --quiet "$work"
step "copy of the screenshots" copy_pictures
step "writing SOURCE.txt" write_source
step "git add" git -C "$work" add SOURCE.txt docs
step "git commit" git -C "$work" -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
  commit --quiet -m "README screenshots of $GITHUB_SHA"

# Neither the URL (it carries the token) nor git's own messages are printed.
rc=0
git -C "$work" push --force --quiet \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" \
  "HEAD:refs/heads/$BRANCH" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || { annotate "could not push branch $BRANCH (git exited $rc)"; exit 1; }

pushed="$(git -C "$work" rev-parse HEAD)"
annotate "the five screenshots of $GITHUB_SHA are on branch $BRANCH, commit $pushed: commit them under docs/screenshots/ (https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$pushed/docs/screenshots/<name>.png)"
exit 1
