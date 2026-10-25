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
    git add -A && git commit -qm first && git remote add origin "$d/origin.git"
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
  ( cd "$d/wt" && CALLS="$d/calls" PATH="$d/bin:$PATH" RTC_SKIP_TESTS=1 \
      RTC_PLUGIN_CACHE="$d/cache" \
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

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
