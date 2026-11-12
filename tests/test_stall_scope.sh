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
lacks "  and names ONLY the env source (never the config)" "$(cat "$TMP/be/log/out")" "rtc-ship.json"
mkrepo "$TMP/bc" '{"tag_prefix":"v","stall_seconds":0,"test_cmd":"echo fast; exit 0"}'
stall_gate "$TMP/bc" RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
if [ "$RIG_RC" != 0 ]; then ok "a zero stall_seconds in rtc-ship.json fails the gate (rc=$RIG_RC)"
else bad "a zero stall_seconds in rtc-ship.json fails the gate" "rc != 0" "rc=$RIG_RC"; fi
has "  naming the config key" "$(cat "$TMP/bc/log/out")" "stall_seconds"
lacks "  and names ONLY the config source (never the env var)" "$(cat "$TMP/bc/log/out")" "RTC_STALL_SECONDS"

echo "== precedence: env beats config — the .stall header prints the RESOLVED window =="
mkrepo "$TMP/pr" '{"tag_prefix":"v","stall_seconds":600,"test_cmd":"exec sleep 300"}'
stall_gate "$TMP/pr" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "the gate's rc is the stall code 124" "124" "$RIG_RC"
diag=$(sed -n 's/^.*diagnosis in //p' "$TMP/pr/log/out" | head -1)
has "the resolved window is the env value" "$(head -1 "$diag" 2>/dev/null)" "for 3s"
lacks "  and not the config value" "$(head -1 "$diag" 2>/dev/null)" "for 600s"

echo "== a TERM-ignoring gate is still killed (TERM, then KILL escalation) =="
mkrepo "$TMP/tr" '{"tag_prefix":"v","test_cmd":"./trapper.sh"}'
cat > "$TMP/tr/trapper.sh" <<'TRAP'
#!/usr/bin/env bash
trap '' TERM
echo $$ > "$GATES_LOG/trap.pid"
while :; do sleep 1; done
TRAP
chmod +x "$TMP/tr/trapper.sh"
( cd "$TMP/tr" && git add -A && git -c user.email=t@t -c user.name=t commit -qm trap )
stall_gate "$TMP/tr" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "the gate's rc is the stall code 124" "124" "$RIG_RC"
tpid=$(cat "$TMP/tr/log/trap.pid" 2>/dev/null)
if [ -n "$tpid" ] && kill -0 "$tpid" 2>/dev/null; then
  bad "the TERM-ignoring gate was KILLed after the grace" "no such process" "still alive (pid $tpid)"
else
  ok "the TERM-ignoring gate was KILLed after the grace"
fi

echo "== docs pin the new stall-recovery surface (1.4.0) =="
help=$(bash "$ROOT/bin/rtc-ship.sh" --help 2>&1)
has "--help pins RTC_STALL_RETRIES" "$help" "RTC_STALL_RETRIES"
has "--help pins the stall_retries config key" "$help" "stall_retries"
readme=$(cat "$ROOT/README.md")
has "README stall section pins RTC_STALL_RETRIES" "$readme" "RTC_STALL_RETRIES"
has "README pins the recovered-stall line" "$readme" "STALLED once — passed on retry"
has "README pins the .stall timeout-dump section" "$readme" "per-test timeout dump"
has "README pins the per-test timeout warning" "$readme" "per-test --timeout="
shipmd=$(cat "$ROOT/skills/ship/SKILL.md")
has "ship skill: a STALLED gate is retried once, read .attempt1.stall" "$shipmd" "attempt1.stall"
has "ship skill: never hand-run gates with RTC_SKIP_TESTS=1" "$shipmd" "RTC_SKIP_TESTS=1"

rig_summary
