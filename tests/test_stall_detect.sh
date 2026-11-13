#!/usr/bin/env bash
# tests/test_stall_detect.sh — a stuck gate is NAMED: the watchdog ends it as a STALLED failure
# with a .stall diagnosis (process tree + log tail, never argv), and the CPU-time parser that
# decides "no progress" reads ps time formats exactly.
#
# Cases: stall_is_named, no_args_leak, tree_cpu_parses_ps_time.
# Rig: tests/lib/stall_rig.sh (sourced; each stall case runs --test-only under a 30 s owned guard).
#
# Usage: bash tests/test_stall_detect.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_stall_detect.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/stall_rig.sh"

TMP=$(mktemp -d)
stall_rig_init "$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset RTC_STALL_SECONDS RTC_STALL_POLL RTC_STALL_KILL_GRACE RTC_BASELINE

echo "== a stalled gate is named and diagnosed =="
mkrepo "$TMP/si" '{"tag_prefix":"v","test_cmd":"for i in $(seq 1 40); do echo line$i; done; echo $$ > \"$GATES_LOG/gate-sleep.pid\"; exec sleep 300"}'
s=$(date +%s)
stall_gate "$TMP/si" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
e=$(date +%s)
# 1.4.2 (same flake family as waypoint rtc-tests-test-gate): the bound measured the WHOLE rig run
# under load and flaked (29 s measured against the old fixed 30 s guard, 2026-11-13 gate run).
# "The DETECTOR ended it, not the guard" is proven structurally by the .stall diagnosis file
# existing below (the guard fires no diagnosis), so the clock bound only needs to catch "never
# ended": keep it under the rig guard (STALL_RIG_GUARD_SECONDS, default 90 s since 1.4.2).
rig_guard=${STALL_RIG_GUARD_SECONDS:-90}
if [ $((e - s)) -lt "$rig_guard" ]; then ok "the stall ended inside the ${rig_guard} s guard ($((e - s)) s)"
else bad "the stall ended inside the ${rig_guard} s guard" "< ${rig_guard} s" "$((e - s)) s"; fi
is "the gate's rc is the stall code 124" "124" "$RIG_RC"
has "rtc-ship's output says STALLED" "$(cat "$TMP/si/log/out")" "STALLED"
has "the phase line names the stalled gate" "$(cat "$TMP/si/log/out")" "tests (config) STALLED — diagnosis in"
diag=$(sed -n 's/^.*diagnosis in //p' "$TMP/si/log/out" | head -1)
if [ -n "$diag" ] && [ -f "$diag" ]; then ok "the printed diagnosis path exists ($diag)"
else bad "the printed diagnosis path exists" "a real file" "${diag:-<none printed>}"; fi
is "its first line names the label" "STALLED tests (config)" \
   "$(head -1 "$diag" 2>/dev/null | cut -d: -f1)"
has "its body lists the tree's command (comm, never args)" \
    "$(cat "$diag" 2>/dev/null)" "sleep"
has "the tail keeps the LAST log line (line40)" "$(cat "$diag" 2>/dev/null)" "line40"
has "  and keeps line11 (exactly 30 lines kept)" "$(cat "$diag" 2>/dev/null)" "line11"
lacks "  and drops line10" "$(cat "$diag" 2>/dev/null)" "line10"
spid=$(cat "$TMP/si/log/gate-sleep.pid" 2>/dev/null)
if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
  bad "the stalled gate's sleep is dead" "no such process" "still alive (pid $spid)"
else
  ok "the stalled gate's sleep is dead"
fi

echo "== the diagnosis never carries argv =="
# The secret rides in ARGV on a silent idle process. (Plan fixture used `sleep 300 SECRET_TOKEN_x`,
# but BSD sleep rejects extra argv and exits 1 — the gate would fail, never stall. python3 -c takes
# extra argv and sleeps: the same leak surface, a fixture that can actually stall. Ruled in ledger.)
mkrepo "$TMP/na" \
  '{"tag_prefix":"v","test_cmd":"exec python3 -c '\''import time; time.sleep(300)'\'' SECRET_TOKEN_x"}'
stall_gate "$TMP/na" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
diag=$(sed -n 's/^.*diagnosis in //p' "$TMP/na/log/out" | head -1)
if [ -n "$diag" ] && [ -f "$diag" ]; then ok "the stall produced a diagnosis ($diag)"
else bad "the stall produced a diagnosis" "file exists" "missing"; fi
lacks "the .stall diagnosis carries no secret argv" \
      "$(cat "$diag" 2>/dev/null)" "SECRET_TOKEN_x"

echo "== tree_cpu parses ps time into centiseconds =="
STUBBIN="$TMP/bin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/ps" <<'STUB'
#!/usr/bin/env bash
# canned `ps -o time=` per -p pid: 111 -> 0:00.01, 222 -> 1:02.50, 333 -> 1-02:03:04
last=""
for a in "$@"; do last=$a; done
case "$last" in
  111) printf '0:00.01\n' ;;
  222) printf '1:02.50\n' ;;
  333) printf '1-02:03:04\n' ;;
esac
STUB
cat > "$STUBBIN/pgrep" <<'STUB'
#!/usr/bin/env bash
# no children ever: the tree is exactly the pid itself
exit 1
STUB
chmod +x "$STUBBIN/ps" "$STUBBIN/pgrep"
parsed=$(
  PATH="$STUBBIN:$PATH"
  eval "$(rig_one_fn "$ROOT/bin/rtc-ship.sh" tree_pids)"
  eval "$(rig_one_fn "$ROOT/bin/rtc-ship.sh" tree_cpu)"
  printf '%s|%s|%s|%s' "$(tree_cpu 111)" "$(tree_cpu 222)" "$(tree_cpu 333)" "$(tree_cpu 999)"
)
is "tree_cpu: '0:00.01' -> 1 cs"          "1"       "$(printf '%s' "$parsed" | cut -d'|' -f1)"
is "tree_cpu: '1:02.50' -> 6250 cs"       "6250"    "$(printf '%s' "$parsed" | cut -d'|' -f2)"
is "tree_cpu: '1-02:03:04' -> 9378400 cs" "9378400" "$(printf '%s' "$parsed" | cut -d'|' -f3)"
is "tree_cpu: a vanished pid contributes 0" "0"     "$(printf '%s' "$parsed" | cut -d'|' -f4)"

rig_summary
