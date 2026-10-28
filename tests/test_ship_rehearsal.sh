#!/usr/bin/env bash
# tests/test_ship_rehearsal.sh — the ship loop's MERGE→TAG→PUSH→RELEASE→REFRESH path, rehearsed.
#
# The other ship test (test_rtc_ship.sh) covers --help and the version gate. That leaves the half of
# the loop that does the irreversible work — merge, tag, push, publish, refresh — with NO coverage,
# which is precisely where a silently skipped step is unrecoverable. This rehearses it end to end
# against a scratch repo with a LOCAL origin and a stubbed `gh`, so the real steps run without
# publishing anything.
#
# Both directions, as always: a rehearsal that succeeds proves the happy path, and each guard is
# planted with a defect to confirm it can actually FAIL. A guard nobody has seen go red is
# indistinguishable from a decorative one.
#
# Usage: bash tests/test_ship_rehearsal.sh
set -uo pipefail
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# ---------------------------------------------------------------------------------------------
# The rehearsal: a bare "origin", its clone as the canonical checkout, and a worktree branch to
# ship. `gh` and `get-haiggoh` are stubbed to RECORD, so the assertions are about what the loop
# actually asked them to do rather than about network state we do not control.
# ---------------------------------------------------------------------------------------------
rehearse() {  # rehearse <dir> — build the scratch repo; caller then edits and ships it
  local d=$1
  git init -q --bare "$d/origin.git"
  git init -q "$d/main"
  (
    cd "$d/main" || exit 1
    git config user.email t@t; git config user.name t
    git checkout -q -b main
    mkdir -p .claude-plugin bin .rtc
    printf '{\n  "name": "rehearsal",\n  "version": "0.1.0"\n}\n' > .claude-plugin/plugin.json
    printf '# Changelog\n\n## 0.1.0\n\nfirst\n' > CHANGELOG.md
    cat > rtc-ship.json <<'JSON'
{
  "tag_prefix": "v",
  "default_branch": "main",
  "manifest": ".claude-plugin/plugin.json",
  "changelog": "CHANGELOG.md",
  "assets": "",
  "refresh_plugin": "rehearsal"
}
JSON
    git add -A && git commit -qm first
    git config url."$d/origin.git".insteadOf https://github.com/haiggoh/rehearsal.git
    git remote add origin https://github.com/haiggoh/rehearsal.git
    git push -q origin main
    git worktree add -q "$d/wt" -b feat/ship
  )
  # The bump lands IN THE WORKTREE — committing it in the canonical checkout instead makes main
  # diverge, and the fast-forward merge the ship loop performs becomes impossible.
  (
    cd "$d/wt" || exit 1
    printf '{\n  "name": "rehearsal",\n  "version": "0.2.0"\n}\n' > .claude-plugin/plugin.json
    printf '# Changelog\n\n## 0.2.0\n\nsecond\n\n## 0.1.0\n\nfirst\n' > CHANGELOG.md
    mkdir -p dist && echo tarball > "dist/rehearsal-0.2.0.tar.gz"
    git add -A && git commit -qm bump
  )
  mkdir -p "$d/bin"
  # The stub CDN: serve the manifest an installer would parse. Without it the visibility gate
  # reaches the real raw.githubusercontent.com for a repo that does not exist.
  cat > "$d/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"name":"rehearsal","version":"%s"}\n' "$PUBLISHED_VERSION"
STUB
  chmod +x "$d/bin/curl"
  # The gh stub records the release notes BODY too, not just the argv: "the notes came from the
  # CHANGELOG" is a claim about content, and an argv-only stub cannot see it.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "gh %s\n" "$*" >> "$CALLS"' \
    'prev=""' \
    'for a in "$@"; do' \
    '  if [ "$prev" = "--notes-file" ]; then printf "NOTES-BODY:" >> "$CALLS"; tr '"'"'\n'"'"' '"'"' '"'"' < "$a" >> "$CALLS"; printf '"'"'\n'"'"' >> "$CALLS"; fi' \
    '  prev="$a"' \
    'done' \
    '# GH_FAIL_CREATE=1: a failing upload, speaking on STDOUT the way gh reports an API error.' \
    'if [ "$1 $2" = "release create" ] && [ "${GH_FAIL_CREATE:-0}" = 1 ]; then echo "HTTP 422: Validation Failed (stub)"; exit 1; fi' \
    '# Remember what was uploaded, so `release view` can answer from what the release really holds.' \
    'if [ "$1 $2" = "release create" ]; then : > "$CALLS.assets"; for a in "$@"; do [ -f "$a" ] && basename "$a" >> "$CALLS.assets"; done; fi' \
    '# GH_VIEW_DROP=<name>: the release came back WITHOUT that asset (an upload GitHub lost).' \
    'if [ "$1 $2" = "release view" ]; then grep -vx "${GH_VIEW_DROP:-}" "$CALLS.assets" 2>/dev/null; exit 0; fi' \
    'exit 0' > "$d/bin/gh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "get-haiggoh %s\n" "$*" >> "$CALLS"' \
    'exit 0' > "$d/bin/get-haiggoh"
  chmod +x "$d/bin/gh" "$d/bin/get-haiggoh"
  # The normal case: the refresh lands, so the scratch cache already holds the shipped version.
  fake_cache "$d" 0.2.0
}

ship() {  # ship <dir> [extra rtc-ship args...] — run the loop with the stubs on PATH
  local d=$1; shift
  # RTC_BACKUP_DIR is pinned to the scratch tree in EVERY ship, not just the cleanup tests: the
  # loop now reaps the shipped worktree, and a rehearsal that wrote a backup into the real
  # $HOME/.claude/backups would be wrecking the machine it runs on.
  ( cd "$d/wt" && CALLS="$d/calls" PATH="$d/bin:$PATH" RTC_SKIP_TESTS=1 \
      RTC_PLUGIN_CACHE="$d/cache" RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 \
      PUBLISHED_VERSION=0.2.0 RTC_SHIP_LOG_DIR="$d/logs" \
      "$ROOT/bin/rtc-ship.sh" "$d/wt" "$@" ) >"$d/out" 2>&1
  echo $?
}

fake_cache() {  # fake_cache <dir> <version> — what the installed plugin cache claims to hold
  local d=$1 v=$2
  rm -rf "$d/cache"
  mkdir -p "$d/cache/haiggoh/rehearsal/$v/.claude-plugin"
  printf '{\n  "name": "rehearsal",\n  "version": "%s"\n}\n' "$v" \
    > "$d/cache/haiggoh/rehearsal/$v/.claude-plugin/plugin.json"
}

D="$TMP/r1"; rehearse "$D"
is "a clean rehearsal ships (exit 0)" "0" "$(ship "$D" 0.2.0 'second')"
is "the branch was fast-forward MERGED into the default branch" \
   "1" "$(git -C "$D/main" log --oneline main | grep -c 'bump')"
is "an annotated tag was created" "v0.2.0" "$(git -C "$D/main" tag -l v0.2.0)"
is "and PUSHED to the origin" "v0.2.0" "$(git -C "$D/origin.git" tag -l v0.2.0)"
CALLS=$(cat "$D/calls" 2>/dev/null)
has "gh release create was called with the tag" "$CALLS" "gh release create v0.2.0"
has "the release title carries the summary" "$CALLS" "0.2.0 — second"
has "the release notes came from the CHANGELOG entry" "$CALLS" "NOTES-BODY: second"
has "the installed plugin was refreshed" "$CALLS" "get-haiggoh apply --only rehearsal"
has "the loop reports the release as live" "$(cat "$D/out")" "is live"

# A repo hook must be able to FAIL the ship. post-release is where a Homebrew trigger or an
# installed-copy check lives; warning and continuing means a release whose refresh never landed
# still prints "done — v1.2.3 is live".
D="$TMP/r2"; rehearse "$D"
mkdir -p "$D/wt/.rtc"
printf '#!/usr/bin/env bash\necho "installed copy is 9.9.9, not 0.2.0" >&2\nexit 1\n' > "$D/wt/.rtc/post-release.sh"
chmod +x "$D/wt/.rtc/post-release.sh"
# COMMIT it: an untracked hook makes the worktree dirty, and the ship correctly refuses a dirty
# tree — which would make this test pass for the wrong reason.
( cd "$D/wt" && git add -A && git commit -qm 'add post-release hook' )
rc=$(ship "$D" 0.2.0 'second')
is "a FAILING post-release hook fails the ship" "1" "$rc"
has "and says which hook failed" "$(cat "$D/out")" "post-release"
is "and does not claim the release is live" "0" "$(grep -c 'is live' "$D/out")"

# An asset glob that matches NOTHING must not publish a release missing it. `compgen -G` exits
# non-zero on no match and `|| true` swallowed it, so the loop reported success having dropped the
# asset — a release nobody can install, looking exactly like a successful one.
D="$TMP/r3"; rehearse "$D"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["assets"] = "dist/rehearsal-0.2.0.tar.gz dist/does-not-exist-*.tar.gz"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
( cd "$D/wt" && git add -A && git commit -qm 'declare assets' )
rc=$(ship "$D" 0.2.0 'second')
is "an asset glob matching nothing FAILS the ship" "1" "$rc"
has "and names the glob that matched nothing" "$(cat "$D/out")" "does-not-exist"
is "and the release was NOT published" "0" "$(grep -c 'release published' "$D/out")"

# The happy path WITH assets: the release is created carrying them, and the count is reported.
D="$TMP/r4"; rehearse "$D"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["assets"] = "dist/rehearsal-*.tar.gz"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
( cd "$D/wt" && git add -A && git commit -qm 'declare assets' )
is "declared assets ship" "0" "$(ship "$D" 0.2.0 'second')"
has "and the asset is handed to gh release create" "$(cat "$D/calls")" "dist/rehearsal-0.2.0.tar.gz"
has "and the count is reported" "$(cat "$D/out")" "1 asset"

# A STALE build in the canonical checkout must neither break nor leak into the release. Measured
# 2026-10-26 (free-agents 0.46.2): the loop runs the asset step after `cd "$MAIN"`, and an
# unquoted `for g in $(cfg_get assets)` pathname-expanded `dist/free-agents-*.tar.gz` THERE — into
# the previous release's leftover `dist/free-agents-0.46.1.tar.gz` — so compgen in the worktree
# matched nothing and the release failed after the tag was pushed. The relative paths it hands gh
# would have uploaded MAIN's stale files even with the glob fixed, so the paths must be absolute.
D="$TMP/r4b"; rehearse "$D"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["assets"] = "dist/rehearsal-*.tar.gz"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
( cd "$D/wt" && git add -A && git commit -qm 'declare assets' )
mkdir -p "$D/main/dist" && echo stale > "$D/main/dist/rehearsal-0.1.0.tar.gz"   # untracked leftover
is "a stale build in the canonical checkout does not fail the ship" "0" "$(ship "$D" 0.2.0 'second')"
has "gh gets the WORKTREE's asset by absolute path" "$(cat "$D/calls")" "$D/wt/dist/rehearsal-0.2.0.tar.gz"
is "and never the canonical checkout's stale build" "0" "$(grep -c 'rehearsal-0.1.0' "$D/calls")"

# obs 0057: a pre-package phase whose output nobody asserts. The scratch pre-package here is a
# silent no-op — it runs green and builds nothing — and the worktree's dist/ still holds the
# PREVIOUS release's tarball, which satisfies the glob. The ship must FAIL naming the stale
# asset instead of publishing it (measured on free-agents 0.45.2/0.45.3, which glob-matched
# dist/free-agents-0.44.1.tar.gz while packaging had built nothing current).
D="$TMP/r4c"; rehearse "$D"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["assets"] = "dist/rehearsal-*.tar.gz"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
mkdir -p "$D/wt/.rtc"
mv "$D/wt/dist/rehearsal-0.2.0.tar.gz" "$D/wt/dist/rehearsal-0.1.0.tar.gz"
printf '#!/usr/bin/env bash\n# the silent no-op: runs green, builds nothing\nexit 0\n' > "$D/wt/.rtc/pre-package.sh"
chmod +x "$D/wt/.rtc/pre-package.sh"
( cd "$D/wt" && git add -A && git commit -qm 'stale dist asset, no-op pre-package' )
rc=$(ship "$D" 0.2.0 'second')
is "a stale version-bearing asset FAILS the ship" "1" "$rc"
has "and names the stale asset" "$(cat "$D/out")" "rehearsal-0.1.0"
is "and the release was NOT published" "0" "$(grep -c 'release published' "$D/out")"

# ---------------------------------------------------------------------------------------------
# The refresh must be VERIFIED, not just invoked. `get-haiggoh` exits 0 having copied nothing when
# the manifest it reads is still the old version (a raw.githubusercontent.com propagation window,
# a stale marketplace cache, an unbumped manifest) — so a green exit code says nothing about
# whether the installed copy is now $V. Measured on 0.6.7: the loop printed "done — v0.6.7 is
# live" and exited 0 while the installed copy was still 0.6.6, and only a manual retry landed it.
# fa-ship.sh checked this; the generalization into rtc-ship.sh dropped the check.
# ---------------------------------------------------------------------------------------------
D="$TMP/r5"; rehearse "$D"; fake_cache "$D" 0.2.0
is "a refresh that moved the version ships" "0" "$(ship "$D" 0.2.0 'second')"
has "and reports the installed version" "$(cat "$D/out")" "installed"

D="$TMP/r6"; rehearse "$D"; fake_cache "$D" 0.1.0
rc=$(ship "$D" 0.2.0 'second')
is "a refresh that did NOT move the version FAILS the ship" "1" "$rc"
has "and names both the installed and the shipped version" "$(cat "$D/out")" "is at 0.1.0, not 0.2.0"
is "and does not claim the release is live" "0" "$(grep -c 'is live' "$D/out")"
# ---------------------------------------------------------------------------------------------
# The tag must be VISIBLE, not merely pushed. `git push` returns before the host SERVES the new
# state, and the window is real (measured 2026-10-14: raw + ls-remote served the pre-push state for
# about a minute). The refresh reads the PUBLISHED MANIFEST from that CDN, so a ship that moves on
# immediately can print "done — v1.2.3 is live" while every installer still resolves the previous
# version. Measured on 0.6.7: exactly that, and only a manual retry landed it.
# ---------------------------------------------------------------------------------------------
D="$TMP/r7"; rehearse "$D"
PUBLISHED_VERSION=0.2.0
d=$D
cat > "$d/bin/curl" <<'STUB'
#!/usr/bin/env bash
# the stub CDN: serve the manifest an installer would parse, at whatever version it is told
printf '{"name":"rehearsal","version":"%s"}
' "$PUBLISHED_VERSION"
STUB
chmod +x "$d/bin/curl"
is "a visible tag ships" "0" "$(cd "$d/wt" && PUBLISHED_VERSION=0.2.0 CALLS="$d/calls" PATH="$d/bin:$PATH" RTC_PLUGIN_CACHE="$d/cache" RTC_SKIP_TESTS=1 RTC_TAG_VISIBILITY_DELAY=0 bash "$ROOT/bin/rtc-ship.sh" "$d/wt" 0.2.0 'second' >/dev/null 2>&1; echo $?)"

D="$TMP/r8"; rehearse "$D"; d=$D
cat > "$d/bin/curl" <<'STUB'
#!/usr/bin/env bash
# the stub CDN: serve the manifest an installer would parse, at whatever version it is told
printf '{"name":"rehearsal","version":"%s"}
' "$PUBLISHED_VERSION"
STUB
chmod +x "$d/bin/curl"
# the CDN is still serving the PREVIOUS version, and never catches up
rc=$(cd "$d/wt" && PUBLISHED_VERSION=0.1.0 RTC_TAG_VISIBILITY_TRIES=2 RTC_TAG_VISIBILITY_DELAY=0 CALLS="$d/calls" PATH="$d/bin:$PATH" RTC_PLUGIN_CACHE="$d/cache" RTC_SKIP_TESTS=1 RTC_TAG_VISIBILITY_DELAY=0 RTC_SHIP_LOG_DIR="$d/logs" bash "$ROOT/bin/rtc-ship.sh" "$d/wt" 0.2.0 'second' >/dev/null 2>&1; echo $?)
is "an INVISIBLE tag fails the ship" "1" "$rc"

# Pre-flight runs exactly ONCE per ship, in BOTH modes (found 2026-10-27). The standalone call was
# `hook pre-flight` (no `.sh`), a silent no-op: a gates-skipped ship never ran pre-flight. Fixing
# only the name would have made a GATED ship run it twice (hook, then gates()).
counting_preflight() {  # counting_preflight <dir> — a committed pre-flight that tallies its runs
  local d=$1
  mkdir -p "$d/wt/.rtc"
  printf '#!/usr/bin/env bash\necho run >> "$PF_COUNT"\n' > "$d/wt/.rtc/pre-flight.sh"
  chmod +x "$d/wt/.rtc/pre-flight.sh"
  ( cd "$d/wt" && git add .rtc && git -c user.email=t@t -c user.name=t commit -qm preflight )
}
D="$TMP/r9"; rehearse "$D"; counting_preflight "$D"
ship_rc=$(PF_COUNT="$D/pf.count" ship "$D" 0.2.0 'second')
is "a ship with the suite gates skipped still ships" "0" "$ship_rc"
is "  and still runs pre-flight, once (was: never)" "1" "$(wc -l < "$D/pf.count" | tr -d ' ')"

D="$TMP/r10"; rehearse "$D"; counting_preflight "$D"
mkdir -p "$D/home/.local/bin"
printf '#!/usr/bin/env bash\necho "1 passed in 0.01s"\n' > "$D/home/.local/bin/pytest"
chmod +x "$D/home/.local/bin/pytest"
rc=$(cd "$D/wt" && HOME="$D/home" PF_COUNT="$D/pf.count" CALLS="$D/calls" PATH="$D/bin:$PATH" \
       RTC_PLUGIN_CACHE="$D/cache" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION=0.2.0 \
       bash "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' >"$D/out" 2>&1; echo $?)
is "a GATED ship ships" "0" "$rc"
is "  and runs pre-flight exactly once (not also as a hook)" "1" "$(wc -l < "$D/pf.count" | tr -d ' ')"

# ---------------------------------------------------------------------------------------------
# Cleanup after a CONFIRMED release. The CHANGELOG has advertised this step since 0.7.0; the
# generalization from fa-ship.sh dropped it, which is exactly why fa-wt-config and rtc-wt-glob
# sat there fully merged, tagged and shipped, never reaped. The rules are harmonised with
# watch-your-step's worktree-remove guard (same taxonomy, same component-not-substring matching,
# same collapsed-dir inspection) but deliberately NOT coupled to it: this is the AUTOMATIC path
# and must decide correctly with or without that plugin installed.
# ---------------------------------------------------------------------------------------------
ship_c() {  # ship_c <dir> [VAR=val ...] — a ship with cleanup on and backups contained in $TMP
  local d=$1; shift
  rm -rf "$TMP/bk"          # one test's rescue must not be read by the next one's assertion
  # `env`, not an assignment prefix: a bare "$@" anywhere in the prefix makes bash treat every
  # VAR=val AFTER it as a COMMAND word (exit 127, "command not found"), so the extra
  # RTC_SKIP_CLEANUP-style overrides could never be spliced in that way.
  ( cd "$d/wt" && env CALLS="$d/calls" PATH="$d/bin:$PATH" RTC_SKIP_TESTS=1 \
      RTC_PLUGIN_CACHE="$d/cache" RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 \
      PUBLISHED_VERSION=0.2.0 RTC_SHIP_LOG_DIR="$d/logs" "$@" bash "$ROOT/bin/rtc-ship.sh" "$d/wt" 0.2.0 'second' ) >"$d/out" 2>&1
  echo $?
}
# `git branch --list` prefixes `+` (held by a worktree) and `*` (current), so a surviving branch
# asserts as "+ feat/ship". Read refs instead of the decorated list.
branches() { git -C "$1" for-each-ref --format='%(refname:short)' refs/heads; }
# What was rescued, relative to the backup root — the timestamped directory is part of the path
# and is not the fact under test.
bk() { find "$TMP/bk" -type f 2>/dev/null | sed "s|^$TMP/bk/[^/]*/||" | sort; }

D="$TMP/u1"; rehearse "$D"
( cd "$D/wt" && git push -q origin feat/ship )      # the topic branch reached the remote too
is "a confirmed release reaps the shipped worktree" "0" "$(ship_c "$D")"
is "  the worktree directory is gone" "" "$([ -d "$D/wt" ] && echo present || echo '')"
is "  the branch is gone locally" "" "$(git -C "$D/main" branch --list feat/ship)"
is "  the MERGED REMOTE ref is gone too" "" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x feat/ship || echo '')"
has "  and each step is reported" "$(cat "$D/out")" "cleanup: removed worktree"
has "  including the remote deletion" "$(cat "$D/out")" "cleanup: deleted origin/feat/ship"
is "  and the release still reports live" "1" "$(grep -c 'is live' "$D/out")"
is "  with nothing precious, no backup is taken" "0" "$(bk | wc -l | tr -d ' ')"

D="$TMP/u2"; rehearse "$D"
( cd "$D/wt" && git push -q origin feat/ship )
is "RTC_SKIP_CLEANUP=1 keeps the worktree" "0" "$(ship_c "$D" RTC_SKIP_CLEANUP=1)"
is "  and the branch" "feat/ship" "$(branches "$D/main" | grep -x feat/ship || echo '')"
is "  and the remote ref" "feat/ship" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x feat/ship || echo '')"
is "  and the skip is announced, naming the route" "1" \
   "$(grep -c 'cleanup: skipped (RTC_SKIP_CLEANUP=1)' "$D/out")"

# A merged branch that ANOTHER worktree still has checked out must survive both sweeps: a
# concurrent session may be standing in it. This is the guard that makes the routine safe to run
# unattended, and it is tested by planting exactly that worktree.
D="$TMP/u3"; rehearse "$D"
( cd "$D/main" && git branch other/merged && git push -q origin other/merged \
    && git worktree add -q "$D/wt2" other/merged )
is "a merged branch held by ANOTHER worktree survives" "0" "$(ship_c "$D")"
is "  locally" "other/merged" "$(branches "$D/main" | grep -x other/merged || echo '')"
is "  and on the remote" "other/merged" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x other/merged || echo '')"
is "  and its worktree survives" "0" "$([ -d "$D/wt2" ] && echo 0 || echo 1)"
is "  and the default branch is never swept locally" "main" "$(branches "$D/main" | grep -x main || echo '')"
# Pinned separately from the local one: `git branch -d` already refuses to delete a checked-out or
# current branch, so the LOCAL skip is belt-and-braces and deleting it from the script changes
# nothing observable. The REMOTE skip is the load-bearing one — `git push origin --delete` knows
# nothing about local worktrees or the default branch, so removing it really does delete origin/main.
is "  and never the default branch on the remote either" "main" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x main || echo '')"

# HALF ONE of the trap: git collapses a wholly-ignored directory to 'sub/', so the name cannot tell
# a Finder-junk directory from a real one. Inspecting it is the whole rule.
D="$TMP/u4"; rehearse "$D"
( cd "$D/wt" && mkdir -p sub && echo finder > sub/.DS_Store \
    && printf 'sub/\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm 'ignore sub' )
is "a .DS_Store-only ignored dir is noise" "0" "$(ship_c "$D")"
is "  so no backup is taken" "0" "$(bk | wc -l | tr -d ' ')"

# HALF TWO: the same collapsed shape holding junk AND the only copy of something real.
D="$TMP/u5"; rehearse "$D"
( cd "$D/wt" && mkdir -p sub && echo finder > sub/.DS_Store && echo 'the only copy' > sub/ledger.md \
    && printf 'sub/\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm 'ignore sub' )
is "a collapsed dir holding junk AND a real file is NOT noise" "0" "$(ship_c "$D")"
is "  so the real file is rescued" "sub/ledger.md" "$(bk | grep -x 'sub/ledger.md' || echo '')"
has "  and the rescue is reported" "$(cat "$D/out")" "backed up"

# A DIRECTORY component excuses a path; a substring would excuse its neighbours too. 'myvenv/plan.md'
# is a ledger, not a virtualenv — the second half of the same trap.
D="$TMP/u6"; rehearse "$D"
( cd "$D/wt" && mkdir -p myvenv venv && echo plan > myvenv/plan.md && echo x > venv/marker \
    && printf 'myvenv/\nvenv/\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm ignore )
is "the component rule rescues myvenv/plan.md" "0" "$(ship_c "$D")"
is "  and it is backed up" "myvenv/plan.md" "$(bk | grep -x 'myvenv/plan.md' || echo '')"
is "  while venv/marker is cache and is not backed up" "0" "$(bk | grep -c 'venv/marker')"

# The generalized config.local.sh rule: an ignored file the canonical checkout already holds,
# byte for byte, is not information this worktree alone has.
D="$TMP/u7"; rehearse "$D"
( cd "$D/wt" && mkdir -p config && echo same > config/config.local.sh \
    && printf 'config/config.local.sh\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm ignore )
mkdir -p "$D/main/config" && echo same > "$D/main/config/config.local.sh"
is "an ignored file IDENTICAL to the canonical copy is not precious" "0" "$(ship_c "$D")"
is "  so no backup is taken" "0" "$(bk | wc -l | tr -d ' ')"

D="$TMP/u8"; rehearse "$D"
( cd "$D/wt" && mkdir -p config && echo 'worktree copy, edited' > config/config.local.sh \
    && printf 'config/config.local.sh\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm ignore )
mkdir -p "$D/main/config" && echo 'canonical copy differs' > "$D/main/config/config.local.sh"
is "a DIFFERING ignored copy IS precious" "0" "$(ship_c "$D")"
is "  and is backed up" "config/config.local.sh" "$(bk | grep -x 'config/config.local.sh' || echo '')"

# An unmerged worktree is kept, and says why — never removed silently.
D="$TMP/u9"; rehearse "$D"
( cd "$D/main" && git worktree add -q "$D/wt2" -b feat/unmerged )
( cd "$D/wt2" && echo nope > nope.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm unmerged )
is "an unmerged foreign worktree is kept" "0" "$(ship_c "$D")"
is "  its directory survives" "0" "$([ -d "$D/wt2" ] && echo 0 || echo 1)"
is "  and its branch survives" "feat/unmerged" "$(branches "$D/main" | grep -x feat/unmerged || echo '')"
# NOT asserted here: the "kept, and says why" branch belongs to the SHIPPED worktree, and the ship
# loop has always merged it into the default branch by the time cleanup runs — so that message is a
# backstop for a state this harness cannot construct, not a covered path. The foreign-worktree
# assertions above are what the rehearsal can prove.

# Shipping the canonical checkout itself must reap nothing: that tree is what every other worktree
# is measured against, so deleting it would take the repo's only clean copy with it. RTC_MAIN is
# pinned because the derivation `git rev-parse --git-common-dir | sed 's#/.git$##'` returns a
# RELATIVE path when $WT is the primary checkout (pre-existing, unrelated to cleanup), which would
# fail the ship before the guard is ever reached.
D="$TMP/u10"; rehearse "$D"; fake_cache "$D" 0.1.0
rc=$( cd "$D/main" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 \
      RTC_SKIP_REFRESH=1 RTC_MAIN="$D/main" RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 \
      PUBLISHED_VERSION=0.1.0 RTC_SHIP_LOG_DIR="$D/logs" bash "$ROOT/bin/rtc-ship.sh" "$D/main" 0.1.0 'canonical' >"$D/out" 2>&1; echo $? )
is "shipping the canonical checkout ships" "0" "$rc"
is "  and does NOT remove it" "0" "$([ -d "$D/main" ] && echo 0 || echo 1)"
is "  and reports why it was not touched" "1" "$(grep -c 'canonical checkout' "$D/out")"

# What this case actually proves, and what it does NOT. Measured 2026-10-27 by deleting each
# safeguard from the script in turn: git refuses to delete a branch that is checked out, and refuses
# to delete the branch a remote's HEAD points at, so both `$DEFAULT_BRANCH` skips are unreachable
# during a real ship — the ship has already required $MAIN to be on $DEFAULT_BRANCH, which puts the
# default branch in `in_wt` and therefore behind the in_wt test. This test pins the OUTCOME (the
# default branch survives even when origin/HEAD points somewhere else, which is the echoprism
# `master` shape and the case where git's own protection stops applying), not either skip line.
# Deleting the remote skip leaves this test green — that is a true negative, documented in the
# script, not a gap in this test.
D="$TMP/u11"; rehearse "$D"
( cd "$D/main" || exit 1
  # origin/HEAD must point at a branch that is (a) NOT the default branch this repo's config names,
  # and (b) deliberately UNMERGED, so the sweep never reaches it. Both matter: if it pointed at a
  # merged branch, `git push --delete` would refuse it as the remote's current branch and the
  # "the sweep still sweeps" assertion could never pass.
  git checkout -q -b trunk
  echo unreleasable > unreleasable.txt
  git add -A && git -c user.email=t@t -c user.name=t commit -qm unreleasable
  git push -q origin trunk
  git checkout -q main
  git -C "$D/origin.git" symbolic-ref HEAD refs/heads/trunk
  # a MERGED topic branch, to prove the sweep still sweeps when it should
  git branch topic && git push -q origin topic )
is "a config-named default branch survives when origin/HEAD points elsewhere" "0" "$(ship_c "$D")"
is "  origin/main is NOT deleted" "main" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x main || echo '')"
is "  while the merged topic branch IS swept" "" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x topic || echo '')"
is "  and the unmerged branch origin/HEAD points at is left alone" "trunk" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x trunk || echo '')"

# The opt-outs. Reaping is the default (every u-test above runs with it on); the user may skip
# it for ONE ship (--no-reap, transient), permanently ("reap": false in rtc-ship.json), or via
# the pre-existing environment route (RTC_SKIP_CLEANUP=1). A skip is ANNOUNCED, never silent:
# a tool that quietly stops tidying looks broken from its own output.
D="$TMP/u12"; rehearse "$D"
( cd "$D/main" && git branch topic/merged )
is "the default ship reaps (baseline for the opt-outs)" "0" "$(ship_c "$D")"
is "  the merged branch is gone" "" "$(branches "$D/main" | grep -x 'topic/merged' || echo '')"

D="$TMP/u13"; rehearse "$D"
( cd "$D/main" && git branch topic/merged )
rc=$(ship "$D" 0.2.0 'second' --no-reap)
is "--no-reap ships" "0" "$rc"
is "  and the merged branch SURVIVES" "topic/merged" "$(branches "$D/main" | grep -x 'topic/merged' || echo '')"
is "  and the shipped worktree survives" "0" "$([ -d "$D/wt" ] && echo 0 || echo 1)"
has "  and the skip is announced" "$(cat "$D/out")" "cleanup: skipped (--no-reap)"

D="$TMP/u14"; rehearse "$D"
( cd "$D/main" && git branch topic/merged )
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["reap"] = False
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
( cd "$D/wt" && git add -A && git commit -qm 'opt out of reaping' )
rc=$(ship_c "$D")
is "a config reap:false ships" "0" "$rc"
is "  and the merged branch SURVIVES" "topic/merged" "$(branches "$D/main" | grep -x 'topic/merged' || echo '')"
is "  and the shipped worktree survives" "0" "$([ -d "$D/wt" ] && echo 0 || echo 1)"
has "  and the skip names the config route" "$(cat "$D/out")" "reap"

D="$TMP/u15"; rehearse "$D"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["reap"] = "flase"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
( cd "$D/wt" && git add -A && git commit -qm 'typo the opt-out' )
rc=$(ship_c "$D")
is "a NON-boolean reap value fails the ship BEFORE any irreversible step" "2" "$rc"
has "  naming the bad value" "$(cat "$D/out")" "flase"
is "  and nothing was published" "0" "$(grep -c 'release published' "$D/out")"

# ---------------------------------------------------------------------------------------------
# fa-ship.sh parity (2026-10-28). A call-site sweep of the script rtc-ship.sh replaced found
# features the port dropped while its header and CHANGELOG still claimed them. Each case below
# was RED before its fix.
# ---------------------------------------------------------------------------------------------

# p1 — the REBASE. fa-ship rebased the worktree onto origin/main before the gates; rtc-ship's header
# said so and had no `git rebase` call, so a branch behind main passed every gate and then died at
# `merge --ff-only`.
D="$TMP/p1"; rehearse "$D"
( cd "$D/main" && echo later > later.txt && git add later.txt \
    && git -c user.email=t@t -c user.name=t commit -qm 'main moved on' && git push -q origin main )
is "p1 a branch BEHIND the default branch is rebased and ships" "0" "$(ship "$D" 0.2.0 'second')"
is "  the shipped tag holds main's newer commit" "1" \
   "$(git -C "$D/main" log --oneline v0.2.0 2>/dev/null | grep -c 'main moved on')"
is "  and the bump" "1" "$(git -C "$D/main" log --oneline v0.2.0 2>/dev/null | grep -c 'bump')"

# p1b — a conflicting rebase stops the ship BEFORE anything irreversible, and leaves no half-rebase.
D="$TMP/p1b"; rehearse "$D"
( cd "$D/main" && printf '# Changelog\n\n## 0.1.1\n\nmain edit\n' > CHANGELOG.md && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm 'conflicting edit' && git push -q origin main )
rc=$(ship "$D" 0.2.0 'second')
is "p1b a conflicting rebase fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  and says it was the rebase" "$(cat "$D/out")" "rebase onto origin/main failed"
is "  before any gate ran" "0" "$(grep -c 'version surfaces\|plugin.json :' "$D/out")"
is "  and no tag was made" "" "$(git -C "$D/main" tag -l v0.2.0)"
is "  and the worktree is not left mid-rebase" "" \
   "$(cd "$D/wt" && [ -d "$(git rev-parse --git-path rebase-merge)" ] && echo mid-rebase || echo '')"

# p2 — the version ARGUMENT must match the tree. rtc checked the surfaces against EACH OTHER only;
# a typo'd version merged main locally and then died with no message.
D="$TMP/p2"; rehearse "$D"
rc=$(ship "$D" 0.3.0 'typo')
is "p2 a version argument the tree does not carry fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  naming the argument" "$(cat "$D/out")" "0.3.0"
has "  and what the tree says" "$(cat "$D/out")" "0.2.0"
is "  before main was touched" "0" "$(git -C "$D/main" log --oneline main | grep -c 'bump')"

# p2b — the CHANGELOG half of the door. A repo whose OWN version test ignores the changelog (the
# gate then defers to it) let a version with no entry through to the notes extraction, which died
# after the local merge. free-agents ships exactly this way: its own test_version_consistency.sh.
D="$TMP/p2b"; rehearse "$D"
( cd "$D/wt" && mkdir -p tests && printf '#!/usr/bin/env bash\nexit 0\n' > tests/test_version_consistency.sh \
    && chmod +x tests/test_version_consistency.sh \
    && printf '# Changelog\n\n## 0.1.0\n\nfirst\n' > CHANGELOG.md \
    && git add -A && git commit -qm 'own version test; changelog lacks 0.2.0' )
rc=$(ship "$D" 0.2.0 'second')
is "p2b a version with no CHANGELOG entry fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  saying the entry is missing" "$(cat "$D/out")" "has no entry for 0.2.0"
is "  before main was touched" "0" "$(git -C "$D/main" log --oneline main | grep -c 'own version test')"

# p3 — a failing phase is SHOWN, not discarded. fa-ship's run_logged (2026-10-26, after a packaging
# step "died silently") printed a verdict and the log's tail; rtc ran pre-package >/dev/null.
D="$TMP/p3"; rehearse "$D"; mkdir -p "$D/wt/.rtc"
printf '#!/usr/bin/env bash\necho "building the tarball: missing input foo.txt"\nexit 3\n' > "$D/wt/.rtc/pre-package.sh"
chmod +x "$D/wt/.rtc/pre-package.sh"
( cd "$D/wt" && git add -A && git commit -qm 'failing pre-package' )
rc=$(ship "$D" 0.2.0 'second')
is "p3 a failing pre-package fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  with its own words in the output" "$(cat "$D/out")" "missing input foo.txt"
has "  and an explicit verdict" "$(cat "$D/out")" "FAILED (exit 3)"

# p4 — the logs land where RTC_SHIP_LOG_DIR says (fa-ship: FA_SHIP_LOG_DIR), and a passing phase
# says so with a verdict too.
D="$TMP/p4b"; rehearse "$D"; mkdir -p "$D/wt/.rtc"
printf '#!/usr/bin/env bash\necho "built it"\n' > "$D/wt/.rtc/pre-package.sh"
chmod +x "$D/wt/.rtc/pre-package.sh"
( cd "$D/wt" && git add -A && git commit -qm 'passing pre-package' )
rc=$( ( cd "$D/wt" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 RTC_PLUGIN_CACHE="$D/cache" \
        RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION=0.2.0 \
        RTC_SHIP_LOG_DIR="$D/logs" "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' ) >"$D/out" 2>&1; echo $?)
is "p4b a ship with RTC_SHIP_LOG_DIR ships" "0" "$rc"
is "  and the pre-package log is kept there" "built it" "$(cat "$D/logs/pre-package.log" 2>/dev/null)"
has "  and the passing phase has a verdict" "$(cat "$D/out")" "✓ pre-package"

# p5 — a failing upload is shown too: gh reports API errors on stdout, which went to /dev/null.
D="$TMP/p5"; rehearse "$D"
rc=$( ( cd "$D/wt" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 RTC_PLUGIN_CACHE="$D/cache" \
        RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION=0.2.0 GH_FAIL_CREATE=1 RTC_SHIP_LOG_DIR="$D/logs" \
        "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' ) >"$D/out" 2>&1; echo $?)
is "p5 a failing gh release create fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  with gh's own error in the output" "$(cat "$D/out")" "HTTP 422"

# p6 — after publishing, ASK the release what it holds (fa-ship listed it); an uploaded asset the
# release does not hold fails the ship rather than reading as published.
set_assets() {  # set_assets <dir> <globs> — declare release assets in the worktree's config
  python3 - "$1/wt/rtc-ship.json" "$2" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["assets"] = sys.argv[2]
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
  ( cd "$1/wt" && git add -A && git commit -qm 'declare assets' )
}
D="$TMP/p6"; rehearse "$D"; set_assets "$D" "dist/*.tar.gz"
is "p6 a ship with an asset ships" "0" "$(ship "$D" 0.2.0 'second')"
has "  and lists what the release holds" "$(cat "$D/out")" "asset: rehearsal-0.2.0.tar.gz"
D="$TMP/p6b"; rehearse "$D"; set_assets "$D" "dist/*.tar.gz"
rc=$( ( cd "$D/wt" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 RTC_PLUGIN_CACHE="$D/cache" \
        RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION=0.2.0 \
        GH_VIEW_DROP=rehearsal-0.2.0.tar.gz RTC_SHIP_LOG_DIR="$D/logs" "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' ) >"$D/out" 2>&1; echo $?)
is "p6b an asset missing from the published release fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  naming the missing asset" "$(cat "$D/out")" "rehearsal-0.2.0.tar.gz"

# p7 — a FAILED backup keeps the worktree. cleanup runs as `cleanup || …`, which switches set -e off
# for its whole body, so a failed mkdir/cp printed "backed up" and went on to `worktree remove --force`.
D="$TMP/p7"; rehearse "$D"
( cd "$D/wt" && mkdir -p sub && echo 'the only copy' > sub/ledger.md && printf 'sub/\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm 'ignore sub' )
printf 'blocker\n' > "$TMP/not-a-dir"
rc=$(ship_c "$D" RTC_BACKUP_DIR="$TMP/not-a-dir/bk")
is "p7 a ship whose backup cannot be written still ships (the release outranks the tidy)" "0" "$rc"
is "  but the worktree is KEPT" "0" "$([ -d "$D/wt" ] && echo 0 || echo 1)"
is "  with its only copy intact" "the only copy" "$(cat "$D/wt/sub/ledger.md" 2>/dev/null)"
has "  and the kept worktree is announced" "$(cat "$D/out")" "backup failed"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
