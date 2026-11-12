#!/usr/bin/env bash
# tests/test_stall_dump.sh — a STALLED pytest gate's .stall report also carries the per-test
# timeout dump (pytest-timeout's stack block), so the wedge names its own cause: the watchdog's
# 600 s window usually kills the gate before its 900 s per-test timeout can print, which is why
# the dump is copied out of the full log into the .stall file.
#
# Cases: unit_block (marker found -> header + bounded block; no marker -> empty), dump_copied,
# no_dump_no_section, dump_bounded (500-line dump -> section <= 201 lines, first dump kept).
# Rig: tests/lib/stall_rig.sh (sourced; each stall case runs --test-only under a 30 s owned guard).
#
# Usage: bash tests/test_stall_dump.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_stall_dump.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/stall_rig.sh"

TMP=$(mktemp -d)
stall_rig_init "$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset RTC_STALL_SECONDS RTC_STALL_POLL RTC_STALL_KILL_GRACE RTC_BASELINE

DUMP_HDR='+++++++++++++++++++++++++++++++++++ Timeout ++++++++++++++++++++++++++++++++++++'
DUMP_STK='~~~~~~~~~~~~~~~~~~~~~~~ Stack of MainThread (8335614528) ~~~~~~~~~~~~~~~~~~~~~~~'

echo "== stall_dump_block unit: marker found, none found =="
printf 'line1\nline2\n%s\n%s\n  File "/x", line 1, in <module>\nline-after\n' \
  "$DUMP_HDR" "$DUMP_STK" > "$TMP/with_dump.log"
printf 'line1\nline2\nno markers here\n' > "$TMP/no_dump.log"
eval "$(rig_one_fn "$ROOT/bin/rtc-ship.sh" stall_dump_block)"
out=$(stall_dump_block "$TMP/with_dump.log")
is "unit: first line is the section header" "-- per-test timeout dump --" "$(printf '%s' "$out" | head -1)"
has "unit: second line is the dump header marker" "$(printf '%s' "$out" | sed -n 2p)" " Timeout "
has "unit: the Stack of line is kept" "$out" "Stack of MainThread"
has "unit: lines before the marker are not copied" "$(printf '%s' "$out" | sed -n '1,4p')" "File \"/x\""
lacks "unit: the header is not duplicated" "$(printf '%s' "$out" | grep -c 'per-test timeout dump')" "2"
is "unit: no marker -> empty output" "" "$(stall_dump_block "$TMP/no_dump.log")"
is "unit: missing log -> empty output, rc 0" "0" "$(stall_dump_block "$TMP/does-not-exist.log" >/dev/null; echo $?)"

echo "== a stalled gate whose log carries a dump: the .stall has the section =="
mkrepo "$TMP/dc" '{"tag_prefix":"v","test_cmd":"echo l1; echo l2; echo l3; echo l4; echo l5; echo '\''+++++++++++++++++++++++++++++++++++ Timeout ++++++++++++++++++++++++++++++++++++'\''; echo '\''~~~~~~~~~~~~~~~~~~~~~~~ Stack of MainThread (8335614528) ~~~~~~~~~~~~~~~~~~~~~~~'\''; echo '\''  File \"/x\", line 1, in <module>'\''; exec sleep 300"}'
stall_gate "$TMP/dc" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "dump_copied: the gate's rc is the stall code 124" "124" "$RIG_RC"
diag=$(sed -n 's/^.*diagnosis in //p' "$TMP/dc/log/out" | head -1)
if [ -n "$diag" ] && [ -f "$diag" ]; then ok "dump_copied: the diagnosis file exists ($diag)"
else bad "dump_copied: the diagnosis file exists" "a real file" "${diag:-<none printed>}"; fi
sec=$(sed -n '/-- per-test timeout dump --/,$p' "$diag" 2>/dev/null)
has "dump_copied: the .stall carries the section header" "$sec" "-- per-test timeout dump --"
has "dump_copied: the section keeps the Stack of line" "$sec" "Stack of MainThread"
is "dump_copied: the section starts at the marker (line 2 is the dump header)" "1" \
   "$(printf '%s\n' "$sec" | sed -n 2p | grep -c ' Timeout ')"

echo "== a plain stall without a dump: no section =="
mkrepo "$TMP/nd" '{"tag_prefix":"v","test_cmd":"echo l1; exec sleep 300"}'
stall_gate "$TMP/nd" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "no_dump: rc is 124" "124" "$RIG_RC"
diag=$(sed -n 's/^.*diagnosis in //p' "$TMP/nd/log/out" | head -1)
lacks "no_dump_no_section: the .stall has no dump section" "$(cat "$diag" 2>/dev/null)" "-- per-test timeout dump --"

echo "== a 500-line dump is bounded at 200 lines, first dump kept =="
mkrepo "$TMP/db" '{"tag_prefix":"v","test_cmd":"for i in $(seq 1 250); do echo '\''++++++ Timeout ++++++ frame '\''$i; echo '\''~~~ Stack of T ~~~'\''; done; exec sleep 300"}'
stall_gate "$TMP/db" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "dump_bounded: rc is 124" "124" "$RIG_RC"
diag=$(sed -n 's/^.*diagnosis in //p' "$TMP/db/log/out" | head -1)
sec=$(sed -n '/-- per-test timeout dump --/,$p' "$diag" 2>/dev/null)
n=$(printf '%s\n' "$sec" | grep -c .)
if [ "$n" -le 201 ]; then ok "dump_bounded: section is bounded ($n lines <= 201)"
else bad "dump_bounded: section is bounded" "<= 201 lines" "$n lines"; fi
is "dump_bounded: the FIRST dump is kept (section line 2 is frame 1's header)" \
   "++++++ Timeout ++++++ frame 1" "$(printf '%s\n' "$sec" | sed -n 2p)"
lacks "dump_bounded: the bound cuts before frame 250" "$sec" "frame 250"

rig_summary
