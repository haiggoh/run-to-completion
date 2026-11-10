#!/usr/bin/env bash
# tests/test_stall_scope.sh — the watchdog's kill is SCOPED to the gate's own tree, and a SET
# but invalid stall override aborts naming its source, never falling back to the default.
#
# Cases: kill_spares_foreign_processes, bad_override_aborts.
# Rig: tests/lib/stall_rig.sh (sourced; each gate runs --test-only under a 30 s owned guard).
#
# Usage: bash tests/test_stall_scope.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_stall_scope.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/stall_rig.sh"

TMP=$(mktemp -d)
stall_rig_init "$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset RTC_STALL_SECONDS RTC_STALL_POLL RTC_STALL_KILL_GRACE RTC_BASELINE

echo "== a stall kill spares processes the gate did not start =="
sleep 300 & FPID=$!
mkrepo "$TMP/ks" '{"tag_prefix":"v","test_cmd":"exec sleep 300"}'
stall_gate "$TMP/ks" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
if [ "$RIG_RC" != 0 ]; then ok "the gate stalled and failed (rc=$RIG_RC)"
else bad "the gate stalled and failed" "rc != 0" "rc=$RIG_RC"; fi
if kill -0 "$FPID" 2>/dev/null; then
  ok "the foreign sleep (the test's own) survived the stall kill"
else
  bad "the foreign sleep survived the stall kill" "still alive" "dead"
fi
kill "$FPID" 2>/dev/null
wait "$FPID" 2>/dev/null

echo "== a SET but invalid override aborts, naming its source =="
mkrepo "$TMP/be"
stall_gate "$TMP/be" RTC_STALL_SECONDS=abc RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
if [ "$RIG_RC" != 0 ]; then ok "a non-numeric RTC_STALL_SECONDS fails the gate (rc=$RIG_RC)"
else bad "a non-numeric RTC_STALL_SECONDS fails the gate" "rc != 0" "rc=$RIG_RC"; fi
has "  naming the variable" "$(cat "$TMP/be/log/out")" "RTC_STALL_SECONDS"
mkrepo "$TMP/bc" '{"tag_prefix":"v","stall_seconds":0,"test_cmd":"echo fast; exit 0"}'
stall_gate "$TMP/bc" RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
if [ "$RIG_RC" != 0 ]; then ok "a zero stall_seconds in rtc-ship.json fails the gate (rc=$RIG_RC)"
else bad "a zero stall_seconds in rtc-ship.json fails the gate" "rc != 0" "rc=$RIG_RC"; fi
has "  naming the config key" "$(cat "$TMP/bc/log/out")" "stall_seconds"

rig_summary
