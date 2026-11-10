#!/usr/bin/env bash
# tests/test_stall_progress.sh — a gate that is WORKING is never a stall: CPU time advancing
# counts as progress even when nothing prints, and output advancing counts even when no CPU is
# burned. The watchdog declares a stall only when BOTH signals freeze.
#
# Cases: busy_silent_is_not_a_stall, logging_sleep_is_not_a_stall.
# Rig: tests/lib/stall_rig.sh (sourced; each gate runs --test-only under a 30 s owned guard).
#
# Usage: bash tests/test_stall_progress.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_stall_progress.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/stall_rig.sh"

TMP=$(mktemp -d)
stall_rig_init "$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset RTC_STALL_SECONDS RTC_STALL_POLL RTC_STALL_KILL_GRACE RTC_BASELINE

echo "== busy but silent is not a stall =="
mkrepo "$TMP/bs" \
  "{\"tag_prefix\":\"v\",\"test_cmd\":\"python3 -c 'import time\\nt=time.time()\\nwhile time.time()-t<8: pass'\"}"
stall_gate "$TMP/bs" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "a busy silent suite finishes green" "0" "$RIG_RC"
lacks "and is never named a stall" "$(cat "$TMP/bs/log/out")" "STALLED"

echo "== printing while sleeping is not a stall =="
mkrepo "$TMP/ls" \
  '{"tag_prefix":"v","test_cmd":"for i in 1 2 3 4 5 6 7 8; do echo tick; sleep 1; done"}'
stall_gate "$TMP/ls" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "a printing sleeper finishes green" "0" "$RIG_RC"
lacks "and is never named a stall" "$(cat "$TMP/ls/log/out")" "STALLED"

rig_summary
