#!/usr/bin/env bash
#
# Scripts/ci-search-captures.sh — the CI job "Search captures".
#
# The Search redesign is judged on two series of pictures of the Search tab, taken by
# Scripts/search-captures.sh: `before` on the code the redesign started from, `after` on
# the redesigned one. Scripts/search-captures-series names the series this branch of the
# repository produces. The series lives on the branch ci/search-captures-<series>, force-pushed
# as one commit that holds the 7 PNGs, their 7 measures and SOURCE.txt:
#
#   line 1  <GITHUB_SHA> <GITHUB_REF_NAME>   the commit photographed and the branch that owns the series
#   line 2  sources <tree>                   `git rev-parse HEAD:Sources` of that commit
#
# A series is never taken from under the branch that created it, and `before` never moves
# once the Sources of the checkout differ from the ones it photographed: it stays the picture
# of the original code. In those cases, and when the series is already there for this SHA, the
# job says so in a `::notice` and exits 0. The job never commits or pushes to the tested branch.
#
# Reads GITHUB_SHA, GITHUB_REF_NAME, GITHUB_REPOSITORY and GITHUB_TOKEN. Job logs are
# admin-only, so every outcome is an annotation; neither the token nor git's own messages are printed.
#
set -euo pipefail
cd "$(dirname "$0")/.."

NAMES=(home suggestions results filters-sheet no-results-filtered filtered selection)
TITLE_ERR="::error title=Search captures::"
TITLE_NOTE="::notice title=Search captures::"
BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"

# One annotation: %, carriage return and line feed would otherwise cut the message.
escape() {
  local text="$1" percent='%' cr=$'\r' lf=$'\n'
  text=${text//"$percent"/%25}
  text=${text//"$cr"/%0D}
  text=${text//"$lf"/%0A}
  printf '%s' "$text"
}
annotate() { printf '%s%s\n' "$TITLE_ERR" "$(escape "$1")"; }
notice() { printf '%s%s\n' "$TITLE_NOTE" "$(escape "$1")"; }

stderr_file=""
work=""
cleanup() { rm -rf "$stderr_file" "$work"; }
trap cleanup EXIT

series="$(tr -d '[:space:]' <Scripts/search-captures-series 2>/dev/null)" || series=""
case "$series" in
  before|after) ;;
  *) annotate "Scripts/search-captures-series must say before or after, not '$series'"; exit 1 ;;
esac
BRANCH="ci/search-captures-$series"

[ -n "${GITHUB_SHA:-}" ] || { annotate "GITHUB_SHA is not set"; exit 1; }
[ -n "${GITHUB_REF_NAME:-}" ] || { annotate "GITHUB_REF_NAME is not set"; exit 1; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { annotate "GITHUB_REPOSITORY is not set"; exit 1; }
[ -n "${GITHUB_TOKEN:-}" ] || { annotate "GITHUB_TOKEN is not set"; exit 1; }
url="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

# The sources the series would photograph: the checkout's `Sources` tree.
sources_tree() { git rev-parse HEAD:Sources 2>/dev/null; }

# Who owns the series? A branch that exists has a SOURCE.txt written by the job that created it.
rc=0
listing="$(git ls-remote --heads "$url" "refs/heads/$BRANCH" 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || { annotate "could not read branch $BRANCH (git exited $rc)"; exit 1; }
if [ -n "$listing" ]; then
  rc=0
  git fetch --quiet --depth=1 "$url" "refs/heads/$BRANCH" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { annotate "could not read branch $BRANCH (git exited $rc)"; exit 1; }
  rc=0
  owned="$(git show FETCH_HEAD:SOURCE.txt 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || { annotate "could not read branch $BRANCH (git exited $rc)"; exit 1; }
  owner_sha=""
  owner_ref=""
  recorded=""
  { IFS=' ' read -r owner_sha owner_ref || true; IFS= read -r recorded || true; } <<<"$owned"

  if [ "$owner_ref" != "$GITHUB_REF_NAME" ]; then
    notice "the $series series belongs to branch $owner_ref; nothing to do"
    exit 0
  fi
  if [ "$owner_sha" = "$GITHUB_SHA" ]; then
    notice "the $series series of $GITHUB_SHA is already on branch $BRANCH"
    exit 0
  fi
  if [ "$series" = before ]; then
    now="$(sources_tree)" || { annotate "git rev-parse HEAD:Sources failed"; exit 1; }
    frozen=""
    case "$recorded" in "sources "*) frozen="${recorded#sources }" ;; esac
    if [ "$frozen" != "$now" ]; then
      notice "the before series is frozen on Sources ${frozen:-(unrecorded)}; Sources is now $now, nothing to do"
      exit 0
    fi
  fi
fi

stderr_file="$(mktemp)" || { rc=$?; annotate "mktemp failed (exit $rc)"; exit 1; }

echo "ci-search-captures.sh: running Scripts/search-captures.sh $series"
rc=0
Scripts/search-captures.sh "$series" 2>"$stderr_file" || rc=$?
cat "$stderr_file" >&2

if [ "$rc" -ne 0 ]; then
  message="Scripts/search-captures.sh exited $rc"
  if ! grep -q '^search-captures\.sh:' "$stderr_file"; then
    last="$(grep -v '^[[:space:]]*$' "$stderr_file" | tail -n 5 || true)"
    if [ -n "$last" ]; then
      message="$message; last stderr lines:"$'\n'"$last"
    else
      message="$message with nothing on stderr"
    fi
  fi
  annotate "$message"

  prefixed="$(grep '^search-captures\.sh:' "$stderr_file" | head -n 4 || true)"
  while IFS= read -r line; do
    [ -z "$line" ] || annotate "$line"
  done <<<"$prefixed"

  result=build/search-captures/SearchCaptures.xcresult
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
    print("::error title=Search captures::" + message)
' || true
    fi
  fi
  exit 1
fi

# Runs one step of the publication; a failure names the step.
step() {
  local label="$1" status=0
  shift
  "$@" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || { annotate "$label failed (exit $status)"; exit 1; }
}
copy_pictures() {
  local name ext
  for name in "${NAMES[@]}"; do
    for ext in png txt; do
      cp "build/search-captures/$series/$series-$name.$ext" "$work/$series-$name.$ext" || return
    done
  done
}
write_source() { printf '%s %s\nsources %s\n' "$GITHUB_SHA" "$GITHUB_REF_NAME" "$tree" >"$work/SOURCE.txt"; }

tree="$(sources_tree)" || { annotate "git rev-parse HEAD:Sources failed"; exit 1; }
work="$(mktemp -d)" || { rc=$?; annotate "mktemp failed (exit $rc)"; exit 1; }
step "git init" git init --quiet "$work"
step "copy of the pictures" copy_pictures
step "writing SOURCE.txt" write_source
step "git add" git -C "$work" add .
step "git commit" git -C "$work" -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
  commit --quiet -m "Search captures ($series) of $GITHUB_SHA"

# Neither the URL (it carries the token) nor git's own messages are printed.
rc=0
git -C "$work" push --force --quiet "$url" "HEAD:refs/heads/$BRANCH" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || { annotate "could not push branch $BRANCH (git exited $rc)"; exit 1; }

pushed="$(git -C "$work" rev-parse HEAD)"
notice "the $series series of $GITHUB_SHA is on branch $BRANCH, commit $pushed: https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$pushed/$series-<state>.png"
exit 0
