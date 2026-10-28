#!/usr/bin/env bash
# tests/lib/rehearsal.sh — the shared scratch-repo rig for tests/test_ship_*.sh (sourced, not run).
# Split out of test_ship_rehearsal.sh 2026-10-28 so the cases run as parallel FILES; each suite
# that sources this gets its OWN $TMP, so no state is shared between them.
#
# Both directions, as always: a rehearsal that succeeds proves the happy path, and each guard is
# planted with a defect to confirm it can actually FAIL. A guard nobody has seen go red is
# indistinguishable from a decorative one.
#
set -uo pipefail
export LC_ALL=C
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

summary() { printf '\npassed %d, failed %d\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; }
