#!/usr/bin/env bash
# tests/test_ship_exit_codes.sh — the SHIP path (not just --test-only) carries the exit-code
# vocabulary: a stalled gate exits 124 (the timeout(1) convention), an ordinary gate failure
# exits 1, and usage/config errors keep exit 2. The change is additive: any caller that treats
# non-zero as failure keeps working.
#
# Cases: ship_stall_exits_124, ship_fail_exits_1, test_only_stall_exits_124 (surface parity pin).
# Rig: tests/lib/stall_rig.sh (sourced; every full ship run is under a 30 s guard THE TEST OWNS —
# without the watchdog a stalled gate would hang the suite forever).
#
# The full ship path is exercised against a scratch repo with a local bare origin, so the
# rebase/version-gate door checks run for real and the run stops at the failed gate — before
# any merge, push or tag can happen.
#
# Usage: bash tests/test_ship_exit_codes.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_ship_exit_codes.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/stall_rig.sh"

TMP=$(mktemp -d)
stall_rig_init "$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset RTC_STALL_SECONDS RTC_STALL_POLL RTC_STALL_KILL_GRACE RTC_BASELINE RTC_SKIP_TESTS

# A scratch repo with a local bare origin, committed clean, surfaces pinned at 9.9.9.
mkshiprepo() {  # mkshiprepo <dir> <rtc-ship.json-body>
  local d=$1 body=$2
  mkdir -p "$d/.claude-plugin"
  printf '{"name":"g","version":"9.9.9"}\n' > "$d/.claude-plugin/plugin.json"
  printf '# Changelog\n\n## [9.9.9] — 2026-11-10 — probe\n\nx\n' > "$d/CHANGELOG.md"
  printf 'log/\nshiplogs/\n' > "$d/.gitignore"
  printf '%s\n' "$body" > "$d/rtc-ship.json"
  ( cd "$d" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init \
      && git init -q --bare "$d-origin.git" && git remote add origin "$d-origin.git" \
      && git push -q origin main )
}

ship_full() {  # ship_full <dir> [env=val...] — FULL ship path under a 30 s owned guard; sets RIG_RC
  local d=$1; shift
  mkdir -p "$d/log" "$d/shiplogs" "$d/home"
  ( cd "$d" && exec env HOME="$d/home" GATES_LOG="$d/log" RTC_SHIP_LOG_DIR="$d/shiplogs" "$@" \
      bash "$ROOT/bin/rtc-ship.sh" "$d" 9.9.9 "probe" >"$d/log/out" 2>&1 </dev/null ) &
  RIG_GPID=$!
  STALL_RIG_GROUPS="$STALL_RIG_GROUPS $RIG_GPID"
  ( sleep 30; kill -TERM -- "-$RIG_GPID" 2>/dev/null; sleep 2; kill -KILL -- "-$RIG_GPID" 2>/dev/null ) &
  RIG_GUARD=$!
  wait "$RIG_GPID"; RIG_RC=$?
  kill -TERM -- "-$RIG_GUARD" 2>/dev/null
  wait "$RIG_GUARD" 2>/dev/null
  return "$RIG_RC"
}

echo "== a stalled gate on the FULL ship path exits 124, not 1 =="
mkshiprepo "$TMP/stall" '{"tag_prefix":"v","test_cmd":"exec sleep 300","default_branch":"main","require_default_branch_checkout":false}'
ship_full "$TMP/stall" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "the ship's rc is the stall code 124" "124" "$RIG_RC"
has "rtc-ship's output says STALLED" "$(cat "$TMP/stall/log/out")" "STALLED"

echo "== an ordinary gate failure on the full ship path still exits 1 =="
mkshiprepo "$TMP/fail" '{"tag_prefix":"v","test_cmd":"exit 1","default_branch":"main","require_default_branch_checkout":false}'
ship_full "$TMP/fail"
is "the ship's rc is 1 (additive: non-zero callers unaffected)" "1" "$RIG_RC"

echo "== surface parity: --test-only on the same stall also exits 124 =="
mkshiprepo "$TMP/to" '{"tag_prefix":"v","test_cmd":"exec sleep 300","default_branch":"main"}'
stall_gate "$TMP/to" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "--test-only's rc is the stall code 124" "124" "$RIG_RC"

rig_summary
