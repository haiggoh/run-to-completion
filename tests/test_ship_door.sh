#!/usr/bin/env bash
# tests/test_ship_door.sh — the SHIP path refuses a canonical checkout (and any non-work-tree)
# at the door with exit 2, before a single git step runs: shipping a canonical checkout fails
# its git steps silently and exits 0 (waypoint harden-run-to-completion-rtc; summon-skills
# 2026-11-11) — nothing pushed, tagged or released, only caught by ls-remote.
#
# The read-only modes (--test-only, --versions-only, --bump-versions) write no branch state and
# STAY ALLOWED on the canonical checkout: the door guards the 3-arg ship mode only.
#
# Cases: ship_canonical_refused (+ origin untouched), ship_trailing_slash_refused,
# ship_symlink_refused (repo identity, not path spelling), ship_nonrepo_refused,
# ship_missing_dir_refused, versions_only_canonical_allowed, ship_from_worktree_proceeds.
# Rig: tests/lib/rehearsal.sh (sourced; the same is/has/summary idiom as the sibling suites).
#
# Usage: bash tests/test_ship_door.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_ship_door.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/rehearsal.sh"

ship_to() {  # ship_to <dir> <target> <version> <title> — a 3-arg ship with the rig's stubs on PATH,
             # run from the rig root so the TARGET argument, not the caller's cwd, is under test
  local d=$1 t=$2 v=$3 title=$4
  mkdir -p "$d/logs"
  ( CALLS="$d/calls" PATH="$d/bin:$PATH" RTC_SKIP_TESTS=1 \
      RTC_PLUGIN_CACHE="$d/cache" RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 \
      PUBLISHED_VERSION=0.1.0 RTC_SHIP_LOG_DIR="$d/logs" \
      bash "$ROOT/bin/rtc-ship.sh" "$t" "$v" "$title" ) >"$d/out" 2>&1
  echo $?
}

echo "== the door: shipping the canonical checkout itself is refused with exit 2 =="
D="$TMP/door"; rehearse "$D"
before_main=$(git -C "$D/origin.git" rev-parse refs/heads/main)
rc=$(ship_to "$D" "$D/main" 0.1.0 'canonical')
is "shipping the canonical checkout exits 2 (door)" "2" "$rc"
has "  stderr names the canonical checkout" "$(cat "$D/out")" "is the canonical checkout"
is "  origin got NO tag (nothing shipped)" "" "$(git -C "$D/origin.git" tag -l)"
is "  origin main is untouched" "$before_main" "$(git -C "$D/origin.git" rev-parse refs/heads/main)"

echo "== a trailing slash to the canonical checkout is refused the same way =="
rc=$(ship_to "$D" "$D/main/" 0.1.0 'canonical')
is "trailing-slash target exits 2" "2" "$rc"
has "  stderr names the canonical checkout" "$(cat "$D/out")" "is the canonical checkout"

echo "== a symlink to the canonical checkout is refused (identity, not spelling) =="
ln -s "$D/main" "$D/mlink"
rc=$(ship_to "$D" "$D/mlink" 0.1.0 'canonical')
is "symlinked canonical checkout exits 2" "2" "$rc"
has "  stderr names the canonical checkout" "$(cat "$D/out")" "is the canonical checkout"

echo "== a non-repo directory is refused as not inside a git work tree =="
mkdir -p "$D/plain"
rc=$(ship_to "$D" "$D/plain" 0.1.0 'canonical')
is "non-repo target exits 2" "2" "$rc"
has "  stderr says not inside a git work tree" "$(cat "$D/out")" "is not inside a git work tree"

echo "== a target that cannot be cd'd into is refused, not run in the caller's cwd =="
rc=$(ship_to "$D" "$D/does-not-exist" 0.1.0 'canonical')
is "missing target directory exits 2" "2" "$rc"
has "  stderr says not inside a git work tree" "$(cat "$D/out")" "is not inside a git work tree"

echo "== the read-only modes stay allowed on the canonical checkout =="
( cd "$D/main" && HOME="$TMP/bk" bash "$ROOT/bin/rtc-ship.sh" --versions-only "$D/main" ) >"$D/vout" 2>&1
rc=$?
is "--versions-only on the canonical checkout is not the door (exit 0)" "0" "$rc"

echo "== a linked worktree sails past the door and ships =="
rc=$(ship "$D" 0.2.0 'second')
is "shipping the worktree exits 0" "0" "$rc"
is "  no door refusal in the output" "0" "$(grep -c 'is the canonical checkout' "$D/out")"
is "  the ship really happened (tag exists)" "v0.2.0" "$(git -C "$D/origin.git" tag -l)"

summary
