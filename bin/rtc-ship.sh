#!/usr/bin/env bash
# rtc-ship.sh — ship one milestone branch of ANY repo: rebase on origin/<default-branch>, the test
# gates, fast-forward merge into that branch, an annotated tag built from the CHANGELOG entry, push,
# a GitHub release with the repo's distributables, then refresh the installed plugin.
#
# "main" IN PROSE MEANS THE DEFAULT BRANCH, whatever it is called. Most repos use `main`; echoprism
# uses `master`. A request to "merge to main" is resolved to this repo's actual default branch —
# never to a branch literally named main, and certainly never by CREATING one, which would be a
# second default and the worst kind of confusion.
#
# WHY THIS EXISTS. The ship loop was hand-rolled per repo, and the costliest failure was not a
# wrong step but a SKIPPED one: the version bump lands after the test suite has already run, so a
# split is introduced between "tests green" and "PR opened" and only a re-check catches it. Measured
# 2026-10-24 — free-agents 0.43.2 shipped with VERSION at 0.43.1 while four other surfaces said
# 0.43.2, because the repo's own version test ran with its verdict discarded. So the gates live here,
# in one place, and a repo cannot skip them by forgetting to run its own script.
#
# Usage:
#   rtc-ship.sh <worktree-dir> <version> "<release title summary>"
#   rtc-ship.sh --test-only <worktree-dir>    run the gates and stamp the tree, ship nothing
#   rtc-ship.sh --which-config                print the config this repo would use and exit
#   rtc-ship.sh --help
#
# Per-repo specifics live in TWO places, both inside the repo being shipped:
#   rtc-ship.json   DATA the tool needs: the tag prefix, which version surfaces to check, release
#                   asset globs, the plugin to refresh, test worker count.
#   .rtc/*.sh       COMMANDS only that repo has, run at named points if present and executable:
#                     pre-flight.sh     extra gates, before anything else (a second venv's suite)
#                     pre-package.sh    build the release assets
#                     post-release.sh   after the release (a Homebrew tap trigger, say)
#                   A repo with none of these is fully supported — hooks are opt-in by presence.
#
# Env:
#   RTC_MAIN            canonical checkout (default: derived from the worktree's git common dir)
#   RTC_SKIP_TESTS=1    skip the suite gates (prefer the tree stamp: a green run of THIS tree self-skips)
#   RTC_TEST_WORKERS    xdist workers for the main suite (default 12)
#   RTC_SKIP_REFRESH=1  do not refresh the installed plugin after a confirmed release
#   RTC_TAG_VISIBILITY=0        skip the published-manifest check (default: on, it gates the release)
#   RTC_TAG_VISIBILITY_TRIES    polls before giving up (default 6; the CDN window is ~1 minute)
#   RTC_TAG_VISIBILITY_DELAY    seconds between polls (default 20)
set -euo pipefail

# Print every header comment line up to the first line of real code. NOT a hardcoded line range:
# `sed -n '2,31p'` silently hid every line added past 31, which is how a gate shipped with its own
# env vars documented in the source and invisible in --help (measured on 0.6.11).
usage() { awk 'NR>1 && !/^#/ {exit} {sub(/^# ?/, ""); print}' "$0"; }
T0=${SECONDS:-0}
phase() { printf '[%4ss] %s\n' "$((SECONDS - T0))" "$*"; }

# ----------------------------------------------------------------------------------------------
# Config: DATA comes from rtc-ship.json; COMMANDS come from .rtc/*.sh. Neither is guessed.
# ----------------------------------------------------------------------------------------------

resolve_top() {  # the repo root, or $PWD where there is NO git repo (see below)
  local base=${RTC_REPO_ROOT:-$PWD} t
  t=$(git -C "$base" rev-parse --show-toplevel 2>/dev/null) || t=""
  printf '%s\n' "${t:-$base}"
}

cfg_get() {  # cfg_get <key> [default] — one scalar out of rtc-ship.json
  local key=$1 def=${2-} top toplevel
  top=$(resolve_top)
  RTC_CFG_FILE="$top/rtc-ship.json" python3 - "$key" "$def" <<'PY'
import json, os, sys
key, default = sys.argv[1], sys.argv[2]
try:
    with open(os.environ["RTC_CFG_FILE"]) as f:
        v = json.load(f).get(key)
except Exception:
    v = None
if v is None:
    print(default)
elif isinstance(v, bool):
    print("1" if v else "0")
else:
    print(v)
PY
}

# ----------------------------------------------------------------------------------------------
# The version gate. The repo's OWN test wins when it has one; otherwise the config's declared
# surfaces are checked here. Both paths print the table and both exit non-zero on a split — the
# point of this script is that the gate cannot be skipped by not running it.
# ----------------------------------------------------------------------------------------------

version_gate() {
  # THE SAME resolver cfg_get uses, and for the same reason: an installed plugin cache is a plain
  # directory with no .git anywhere above it, and so is an extracted release tarball. Letting `git
  # rev-parse` fail left `top` EMPTY, so every surface was read through "/" and came back "<none>"
  # — a consistent tree reported as disagreeing. Found by dogfooding installed 0.6.6.
  local top; top=$(resolve_top)
  if [ -x "$top/tests/test_version_consistency.sh" ]; then
    if ! bash "$top/tests/test_version_consistency.sh"; then
      echo "✖ version surfaces disagree (the repo's own test) — ship refused" >&2; return 1
    fi
    return 0
  fi
  # No repo test: check what the config declares. A repo that declares fewer surfaces than it has
  # will drift, but a repo that declares NONE gets a manifest+changelog check rather than nothing.
  local manifest changelog vfile roadmap want mv cv vv rv
  manifest=$(cfg_get "manifest" ".claude-plugin/plugin.json")
  changelog=$(cfg_get "changelog" "CHANGELOG.md")
  vfile=$(cfg_get "version_file" "")
  roadmap=$(cfg_get "roadmap" "")
  mv=$(python3 -c "import json,sys;print(json.load(open('$top/$manifest')).get('version',''))" 2>/dev/null || echo "")
  # BOTH heading styles: Keep-a-Changelog permits `## 1.2.3` and `## [1.2.3]`, and this repo's own
  # CHANGELOG uses the unbracketed form while free-agents' uses brackets.
  cv=$(sed -n -E 's/^##+[[:space:]]+\[?([0-9]+\.[0-9]+\.[0-9]+)\]?.*/\1/p' "$top/$changelog" 2>/dev/null | head -1)
  vv=""; [ -n "$vfile" ] && [ -f "$top/$vfile" ] && vv=$(tr -d '[:space:]' < "$top/$vfile")
  rv=""; [ -n "$roadmap" ] && [ -f "$top/$roadmap" ] && rv=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$top/$roadmap" | head -1)
  echo "  $manifest : ${mv:-<none>}"
  echo "  $changelog (top entry) : ${cv:-<none>}"
  [ -n "$vfile" ] && echo "  $vfile : ${vv:-<none>}"
  [ -n "$roadmap" ] && echo "  $roadmap : ${rv:-<none>}"
  local bad=0
  # An EMPTY extraction is a FAILURE, never a pass. A gate that cannot find its input and then
  # declares success is worse than no gate — it let a planted split through on the first run of
  # this script, because an unreadable changelog silently skipped its comparison.
  if [ -z "$mv" ]; then echo "✖ no version in $manifest" >&2; bad=1; fi
  if [ -z "$changelog" ]; then
    # A repo may legitimately have no changelog at all (echoprism: package.json, no CHANGELOG.md).
    # Saying so beats failing on a file that was never promised.
    echo "  (no changelog declared — not checked)"
    cv=$mv
  elif [ -z "$cv" ]; then echo "✖ no numbered heading found in $changelog" >&2; bad=1
  elif [ "$cv" != "$mv" ]; then echo "✖ changelog top is $cv, manifest says $mv" >&2; bad=1; fi
  if [ -n "$vfile" ] && [ ! -f "$top/$vfile" ]; then echo "✖ $vfile is declared in the config but absent" >&2; bad=1
  elif [ -n "$vv" ] && [ "$vv" != "$mv" ]; then echo "✖ $vfile says $vv, manifest says $mv" >&2; bad=1; fi
  if [ -n "$roadmap" ] && [ -f "$top/$roadmap" ] && [ -n "$rv" ] && [ "$rv" != "$mv" ]; then
    echo "✖ $roadmap says $rv, manifest says $mv" >&2; bad=1
  fi
  return "$bad"
}

# ----------------------------------------------------------------------------------------------
# The suite gates: parallel pytest, plus a tree stamp so a tree that already passed is not re-run.
# A repo's own extra gates go in .rtc/pre-flight.sh (free-agents' litellm/picker venvs, say).
# ----------------------------------------------------------------------------------------------

gates() {
  local tree stamp d rc=0 pids=() names=() out
  tree=$(git rev-parse 'HEAD^{tree}')
  stamp="$(git rev-parse --git-common-dir)/rtc-tested/$tree"
  if [ -e "$stamp" ]; then
    phase "tests: tree ${tree:0:10} already passed every gate ($(date -r "$stamp" '+%H:%M')) — skipped"
    return 0
  fi
  if [ -x .rtc/pre-flight.sh ]; then
    if ./.rtc/pre-flight.sh; then phase "pre-flight gates: pass"
    else rc=1; phase "✖ pre-flight gates FAILED"; fi
  fi
  # How this repo's tests run is the REPO'S business, not the tool's assumption. A pytest suite is
  # the default, but a repo of shell suites would otherwise collect nothing and exit 5 — so the
  # command comes from the config, and an UNCOLLECTED suite is a failure, never a silent pass.
  local test_cmd; test_cmd=$(cfg_get "test_cmd" "")
  d=$(mktemp -d)
  if [ -n "$test_cmd" ]; then
    if bash -c "$test_cmd" >"$d/main" 2>&1; then phase "tests (config): pass"
    else phase "✖ tests (config) FAILED"; grep -E "FAIL|✖" "$d/main" | head -10 >&2; rc=1; fi
  else
    "$HOME/.local/bin/pytest" -q tests -p no:cacheprovider -n "${RTC_TEST_WORKERS:-12}" \
      </dev/null >"$d/main" 2>&1 &
    names+=(main); pids+=($!)
  fi
  local i ok
  for i in "${!pids[@]}"; do
    # wait FIRST, so the log is complete before it is classified.
    ok=0; wait "${pids[$i]}" && ok=1
    if [ "$ok" = 0 ]; then
      rc=1; phase "✖ pytest ${names[$i]} FAILED: $(grep -E 'passed|failed|error' "$d/${names[$i]}" | tail -1)"
      grep -E '^(FAILED|ERROR) ' "$d/${names[$i]}" | head -10 >&2
    elif grep -q "no tests ran" "$d/${names[$i]}"; then
      rc=1; phase "✖ pytest ${names[$i]} collected NO tests — declare a test_cmd in rtc-ship.json"
    else
      phase "pytest ${names[$i]}: $(grep -E 'passed|failed' "$d/${names[$i]}" | tail -1)"
    fi
  done
  if [ "$rc" = 0 ]; then mkdir -p "$(dirname "$stamp")"; touch "$stamp"; rm -rf "$d"
  else echo "✖ tests failed — full logs kept in $d" >&2; fi
  return "$rc"
}

hook() {  # hook <name> — run a repo hook if it is present and executable
  local name=$1
  if [ -x ".rtc/$name" ]; then
    if "./.rtc/$name"; then phase "hook $name: pass"; return 0
    else phase "✖ hook $name FAILED"; return 1; fi
  fi
  return 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  --test-only) ;;
  --versions-only) ;;
  --which-config)
    git rev-parse --show-toplevel
    cfg_get "tag_prefix" "(none)"; exit 0 ;;
  -*) echo "rtc-ship.sh: unrecognised option $1" >&2; usage >&2; exit 2 ;;
esac

if [ "$1" = --test-only ]; then
  [ $# -eq 2 ] || { usage >&2; exit 2; }
  cd "$2"
  # FAIL, do not warn. A gate that reports a mismatch and exits 0 trains the operator to believe
  # the ground is covered — that is exactly how a decorative check survives.
  if ! version_gate; then echo "✖ version surfaces disagree — see above. Ship will refuse." >&2; exit 1; fi
  gates; exit $?
fi
if [ "$1" = --versions-only ]; then
  [ $# -eq 2 ] || { usage >&2; exit 2; }
  cd "$2"
  # The version gate ALONE — fast enough to run before every commit, and the only part a
  # hand-rolled ship reliably skips.
  if ! version_gate; then echo "✖ version surfaces disagree" >&2; exit 1; fi
  phase "version surfaces agree"; exit 0
fi
[ $# -eq 3 ] || { usage >&2; exit 2; }

WT=$1 V=$2 TITLE=$3
cd "$WT"; WT=$(pwd)
# -z, not -n: `[ -n "$out" ] || { dirty }` declares a CLEAN tree dirty and refuses every valid ship.
[ -z "$(git status --porcelain)" ] || { echo "✖ $WT is dirty" >&2; exit 1; }
BR=$(git branch --show-current)
TOP=$(git rev-parse --show-toplevel)
MAIN=${RTC_MAIN:-$(git rev-parse --git-common-dir | sed 's#/.git$##')}
PREFIX=$(cfg_get "tag_prefix" "")
# The default branch is NOT assumed. Config first (echoprism uses `master`), then the remote's own
# HEAD, and only then `main` — a hardcoded `main` would mis-ship a whole repo.
DEFAULT_BRANCH=$(cfg_get "default_branch" "")
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git -C "$MAIN" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
                   | sed 's|^origin/||' || true)
fi
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main

# --- the version gate, where a hand-rolled ship skips it --------------------------------
# It runs AFTER the rebase and BEFORE the merge, because the bump lands between "suite green"
# and "PR opened". This is the gate whose absence let 0.43.2 ship split.
if ! version_gate; then echo "✖ version surfaces disagree — see above. Ship refused." >&2; exit 1; fi
hook pre-flight || exit 1
if [ "${RTC_SKIP_TESTS:-0}" != 1 ]; then gates || exit 1; fi

cd "$MAIN"
[ "$(git branch --show-current)" = "$DEFAULT_BRANCH" ] || { echo "✖ $MAIN not on $DEFAULT_BRANCH" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "✖ $MAIN has tracked changes" >&2; exit 1; }
git fetch -q origin
git pull -q --ff-only origin "$DEFAULT_BRANCH"
git merge -q --ff-only "$BR"

# Extracted with python, not an awk program assembled from quoted fragments: the bracket-optional
# heading form plus an interpolated version made a regex too fragile to trust in shell quoting.
# Both heading styles are accepted (## 1.2.3 and ## [1.2.3]).
notes=$(if [ -f CHANGELOG.md ]; then CHANGELOG_FILE=CHANGELOG.md VERSION="$V" python3 - <<'PYEOF'
import os, re, sys
path, version = os.environ["CHANGELOG_FILE"], os.environ["VERSION"]
text = open(path, encoding="utf-8", errors="replace").read()
m = re.search(r"^##+[ \t]+\[?" + re.escape(version) + r"\]?\b", text, re.M)
if not m:
    sys.exit(1)
# Skip to the end of the HEADING line: a heading may carry a date and title after the version
# (`## [0.6.4] — 2026-10-24 — …`), and those are not release notes.
nl = text.find("\n", m.end())
rest = text[len(text) if nl == -1 else nl + 1:]
# Stop at the next SAME-LEVEL heading only: `##+` would also match `###`, truncating every
# entry at its first sub-heading and producing an empty release note.
nxt = re.search(r"^##(?!#)", rest, re.M)
sys.stdout.write(rest[:nxt.start()] if nxt else rest)
PYEOF
else echo ""; fi)
git tag -a "${PREFIX}${V}" -m "$(basename "$MAIN") $V — $TITLE

$notes"
git push -q origin "$DEFAULT_BRANCH" "${PREFIX}${V}"
phase "merged, tagged ${PREFIX}${V}, pushed"

# --- the tag must be VISIBLE, not merely pushed ------------------------------------------------
# A push returns BEFORE the host serves the new state, and the window is real (measured 2026-10-14:
# raw + ls-remote served the pre-push state for about a minute). The refresh step resolves the
# published MANIFEST from that CDN, so a ship that moves on immediately can print "done — v1.2.3 is
# live" while every installer still resolves the previous version. Measured on 0.6.7: exactly that
# — get-haiggoh read the stale manifest, reported "0.6.6 (current)" and copied nothing, and only a
# manual retry landed it. The fifth silent-failure class in this loop.
published_version() {  # the version the PUBLISHED manifest declares, or "" if it cannot be read
  local url body owner_repo
  url=$(git -C "$MAIN" remote get-url origin 2>/dev/null) || return 0
  owner_repo=$(printf '%s' "$url" | sed -e 's#^git@github.com:#github/#' -e 's#^https://github.com/##' \
                                        -e 's#^https://##' -e 's#\.git$##')
  case "$owner_repo" in */*) ;; *) return 0 ;; esac     # a local-path remote: nothing to check
  body=$(curl -fsS --max-time 20 \
    "https://raw.githubusercontent.com/$owner_repo/$DEFAULT_BRANCH/$(cfg_get manifest .claude-plugin/plugin.json)" 2>/dev/null) || body=""
  printf '%s' "$body" | sed -n -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1
  return 0
}

if [ "${RTC_TAG_VISIBILITY:-1}" = 1 ]; then
  vis_tries=0
  while :; do
    got=$(published_version)
    if [ "$got" = "$V" ]; then phase "tag ${PREFIX}${V} is VISIBLE to installers"; break; fi
    vis_tries=$((vis_tries + 1))
    if [ "$vis_tries" -ge "${RTC_TAG_VISIBILITY_TRIES:-6}" ]; then
      echo "✖ the published manifest declares ${got:-<nothing>}, not $V — installers still resolve the old version" >&2
      echo "  the tag and the branch are pushed, but nothing is released yet. Re-check, then re-run:" >&2
      echo "    curl -s https://raw.githubusercontent.com/<owner>/<repo>/$DEFAULT_BRANCH/$(cfg_get manifest .claude-plugin/plugin.json)" >&2
      echo "    rtc-ship.sh $WT $V \"$TITLE\"" >&2
      exit 1
    fi
    phase "tag not visible yet (${got:-<nothing>}) — waiting ${RTC_TAG_VISIBILITY_DELAY:-20}s (try $vis_tries/${RTC_TAG_VISIBILITY_TRIES:-6})"
    sleep "${RTC_TAG_VISIBILITY_DELAY:-20}"
  done
fi

# --- assets: built by the repo's own hook, so the tool never hardcodes a filename ----------
if [ -x "$TOP/.rtc/pre-package.sh" ]; then
  ( cd "$TOP" && ./.rtc/pre-package.sh >/dev/null ) || { echo "✖ pre-package failed" >&2; exit 1; }
fi
# Resolve the globs in the MAIN shell, not a process substitution: an `exit` inside `< <(...)`
# only leaves that subshell, so a glob matching nothing would be dropped, the pipe would carry on
# with the globs that DID match, and the ship would publish a release missing an asset while
# reporting success — indistinguishable from a working release until someone tries to install it.
ASSETS=(); MISSING=()
# `set -f` around the split: each pattern arrives as ONE word from the config, and an unquoted
# for-word PATHNAME-EXPANDS against the CURRENT directory — which is $MAIN here, after the merge
# (measured 2026-10-26, free-agents 0.46.2: MAIN held the previous release's leftover
# dist/free-agents-0.46.1.tar.gz, the pattern expanded into literal filenames THERE, and compgen
# in the worktree then matched nothing — aborting the ship AFTER the tag was pushed). The shell
# must split the value but never glob it; compgen -G below is the only globber, and it runs in $TOP.
set -f
for g in $(cfg_get "assets" ""); do
  [ -n "$g" ] || continue
  # `|| true` inside the substitution: a non-matching glob makes compgen exit non-zero, and that
  # status becomes the assignment's own — under `set -e` it aborts the ship before the message
  # below can say WHICH glob failed. Exit code 1 with no reason is the failure this loop prevents.
  m=$(cd "$TOP" && compgen -G "$g" || true)
  if [ -z "$m" ]; then MISSING+=("$g"); else
    # Absolute, worktree-anchored paths: gh runs with cwd=$MAIN, so a relative asset name would
    # hand it MAIN's file — the stale build this loop exists to avoid. A match that is already
    # absolute (the config declared an absolute pattern) is passed through untouched.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case $f in /*) ASSETS+=("$f") ;; *) ASSETS+=("$TOP/$f") ;; esac
    done <<< "$m"
  fi
done
set +f
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "✖ asset glob(s) matched nothing in $TOP: ${MISSING[*]}" >&2
  echo "  the release would ship without them — fix the packaging hook or the glob" >&2
  exit 1
fi
if [ -n "$notes" ]; then
  nf=$(mktemp); printf '%s\n' "$notes" > "$nf"
  gh release create "${PREFIX}${V}" --title "$(basename "$MAIN") $V — $TITLE" \
    --notes-file "$nf" "${ASSETS[@]}" >/dev/null
  rm -f "$nf"
else
  # No changelog to draw notes from (a repo may legitimately have none). Let gh derive them from
  # the commits rather than shipping an EMPTY body — which is what the first version of this script
  # did, and an empty release is a release nobody reads.
  gh release create "${PREFIX}${V}" --title "$(basename "$MAIN") $V — $TITLE" \
    --generate-notes "${ASSETS[@]}" >/dev/null
fi
phase "release published${ASSETS:+ with ${#ASSETS[@]} asset(s)}"

installed_version() {  # installed_version <plugin> — the version the INSTALLED cache holds, or ""
  local plugin=$1 base best v
  # Overridable so a test can point at a scratch cache: the real one is tool-owned state, and a
  # ship must never read (let alone write) it except through the tool that owns it.
  base=${RTC_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}
  for d in "$base"/*/"$plugin"; do
    [ -d "$d" ] || continue
    # Versionless numeric sort: the cache dirs are named by version and there is no index to read.
    best=$(find "$d" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)
    [ -n "$best" ] || continue
    v=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version",""))' \
        "$best/.claude-plugin/plugin.json" 2>/dev/null) || v=""
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  done
  return 0
}

PLUGIN=$(cfg_get "refresh_plugin" "")
if [ -n "$PLUGIN" ] && [ "${RTC_SKIP_REFRESH:-0}" != 1 ]; then
  get-haiggoh apply --only "$PLUGIN" 2>&1 | sed 's/^/  /' || echo "⚠ refresh failed" >&2
  # VERIFY it moved — invoking is not the same as landing. `get-haiggoh` exits 0 having copied
  # NOTHING when the manifest it reads is still the old version (a raw.githubusercontent.com
  # propagation window, a stale marketplace cache, an unbumped manifest), so a green exit code
  # says nothing about whether the installed copy is now $V. Measured 2026-10-25 on 0.6.7: this
  # loop printed "done — v0.6.7 is live" and exited 0 while the installed copy was still 0.6.6,
  # and only a manual retry landed it. fa-ship.sh checked this; the generalization dropped it.
  got=$(installed_version "$PLUGIN")
  if [ "$got" != "$V" ]; then
    echo "✖ the installed $PLUGIN is at ${got:-<none>}, not $V — the refresh did not land" >&2
    echo "  re-run once after a short delay (the manifest is served by a CDN), then: get-haiggoh apply --only $PLUGIN" >&2
    exit 1
  fi
  phase "installed $PLUGIN is $V"
fi
if [ -x "$TOP/.rtc/post-release.sh" ]; then
  # FAIL, do not warn. post-release is where a repo verifies the refresh it just performed (the
  # installed copy is at $V, the tap formula points at this release). A warning here lets a release
  # whose refresh silently did nothing print "done — v1.2.3 is live", which is the exact failure
  # this loop exists to prevent: a success message over an unverified outcome.
  if ! ( cd "$TOP" && ./.rtc/post-release.sh >/dev/null ); then
    echo "✖ post-release hook failed — the release is published but NOT confirmed live" >&2
    exit 1
  fi
fi
phase "done — ${PREFIX}${V} is live"
