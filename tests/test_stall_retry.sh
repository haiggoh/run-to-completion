#!/usr/bin/env bash
# tests/test_stall_retry.sh — a STALLED gate is re-run ONCE automatically (stall_retries, default 1;
# RTC_STALL_RETRIES beats rtc-ship.json "stall_retries"; 0 = the 1.3.1 behaviour; an invalid value
# exits 2 naming the key). A stall that passes on retry is LOUD — recovered line + kept
# .attempt1/.attempt1.stall artefacts, tree still stamped green — never silent. A second stall is
# 124 as before; only the stalled gate is re-run, never the whole set.
#
# Cases: recovers_once, stalls_twice_is_124, retry_fails_normally, retries_zero_is_1_3_1,
# env_beats_config, invalid_value_exit_2 (config -1 / "abc" / 1.5, env -1), preflight_only_retried.
# Rig: tests/lib/stall_rig.sh (sourced; each case runs --test-only under a 30 s owned guard).
#
# Usage: bash tests/test_stall_retry.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_stall_retry.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/stall_rig.sh"

TMP=$(mktemp -d)
stall_rig_init "$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset RTC_STALL_SECONDS RTC_STALL_POLL RTC_STALL_KILL_GRACE RTC_BASELINE RTC_STALL_RETRIES

# the first attempt's artefact paths, as printed by the retry line
kept_as() { sed -n 's/.*first attempt kept as //p' "$1" | head -1; }

echo "== a gate that stalls once then passes is retried and LOUD =="
mkrepo "$TMP/ro" '{"tag_prefix":"v","test_cmd":"if [ ! -f \"$GATES_LOG/once\" ]; then touch \"$GATES_LOG/once\"; exec sleep 300; fi; echo ok"}'
stall_gate "$TMP/ro" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
out=$(cat "$TMP/ro/log/out")
is "recovers_once: rc 0 (recovered counts as pass)" "0" "$RIG_RC"
has "recovers_once: the recovered line names the label" "$out" \
    "tests (config) STALLED once — passed on retry"
has "recovers_once: the run summary lists it" "$out" "recovered stalls this run:"
p=$(sed -n 's/.*diagnosis kept in //p' "$TMP/ro/log/out" | head -1); p=${p%)}
if [ -n "$p" ] && [ -f "$p" ]; then ok "recovers_once: .attempt1.stall exists ($p)"
else bad "recovers_once: .attempt1.stall exists" "a real file" "${p:-<none printed>}"; fi
if [ -n "$p" ] && [ -f "$p" ]; then
  is "recovers_once: the first attempt really stalled (STALLED header in attempt1.stall)" \
     "STALLED tests (config)" "$(head -1 "$p" | cut -d: -f1)"
fi
a1=${p%.stall}
if [ -n "$p" ] && [ -f "$a1" ]; then ok "recovers_once: .attempt1 log kept"; else bad "recovers_once: .attempt1 log kept" "$a1" "missing"; fi
shopt -s nullglob
st=("$TMP/ro/.git/rtc-tested/"*)
shopt -u nullglob
if [ ${#st[@]} -gt 0 ]; then ok "recovers_once: tree stamped green"
else bad "recovers_once: tree stamped green" "a stamp under .git/rtc-tested/" "none"; fi

echo "== a gate that stalls twice still exits 124, both attempts kept =="
mkrepo "$TMP/st" '{"tag_prefix":"v","test_cmd":"exec sleep 300"}'
stall_gate "$TMP/st" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
out=$(cat "$TMP/st/log/out")
is "stalls_twice_is_124: rc 124" "124" "$RIG_RC"
has "stalls_twice: a retry was attempted" "$out" "retrying once"
kept=$(kept_as "$TMP/st/log/out"); a1=${kept%% /*}
if [ -n "$a1" ] && [ -f "$a1" ] && [ -f "$a1.stall" ]; then ok "stalls_twice: .attempt1 and .attempt1.stall both kept"
else bad "stalls_twice: .attempt1 and .attempt1.stall both kept" "$a1 + $a1.stall" "${a1:-<none printed>}"; fi

echo "== stall then ordinary failure: rc 1, both attempts' logs kept =="
mkrepo "$TMP/rf" '{"tag_prefix":"v","test_cmd":"if [ ! -f \"$GATES_LOG/once\" ]; then touch \"$GATES_LOG/once\"; exec sleep 300; fi; exit 3"}'
stall_gate "$TMP/rf" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
out=$(cat "$TMP/rf/log/out")
is "retry_fails_normally: rc 1 (not 124)" "1" "$RIG_RC"
has "retry_fails_normally: named as FAILED" "$out" "tests (config) FAILED"
kept=$(kept_as "$TMP/rf/log/out"); a1=${kept%% /*}
if [ -n "$a1" ] && [ -f "$a1" ]; then ok "retry_fails_normally: first attempt's log kept"; else bad "retry_fails_normally: first attempt's log kept" "$a1" "missing"; fi

echo "== stall_retries:0 reproduces the 1.3.1 behaviour =="
mkrepo "$TMP/r0" '{"tag_prefix":"v","test_cmd":"exec sleep 300","stall_retries":0}'
stall_gate "$TMP/r0" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
out=$(cat "$TMP/r0/log/out")
is "retries_zero_is_1_3_1: rc 124" "124" "$RIG_RC"
lacks "retries_zero_is_1_3_1: no retry attempted" "$out" "retrying once"
lacks "retries_zero_is_1_3_1: no attempt1 artefact named" "$out" ".attempt1"

echo "== RTC_STALL_RETRIES beats the config =="
mkrepo "$TMP/eb" '{"tag_prefix":"v","test_cmd":"exec sleep 300","stall_retries":1}'
stall_gate "$TMP/eb" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1 RTC_STALL_RETRIES=0
out=$(cat "$TMP/eb/log/out")
is "env_beats_config: rc 124 (env 0 won over config 1)" "124" "$RIG_RC"
lacks "env_beats_config: no retry attempted" "$out" "retrying once"

echo "== invalid stall_retries values exit 2 naming the key =="
i=0
for body in '{"tag_prefix":"v","test_cmd":"true","stall_retries":-1}' \
            '{"tag_prefix":"v","test_cmd":"true","stall_retries":"abc"}' \
            '{"tag_prefix":"v","test_cmd":"true","stall_retries":1.5}'; do
  i=$((i+1)); d="$TMP/iv$i"
  mkrepo "$d" "$body"
  stall_gate "$d" RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
  is "invalid_value_exit_2 [$body]: rc 2" "2" "$RIG_RC"
  has "invalid_value_exit_2 [$body]: names the key" "$(cat "$d/log/out")" "stall_retries"
done
mkrepo "$TMP/ive" '{"tag_prefix":"v","test_cmd":"true","stall_retries":1}'
stall_gate "$TMP/ive" RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1 RTC_STALL_RETRIES=-1
is "invalid env RTC_STALL_RETRIES=-1: rc 2" "2" "$RIG_RC"
has "invalid env: names the env var" "$(cat "$TMP/ive/log/out")" "RTC_STALL_RETRIES"

echo "== only the stalled gate is retried: pre-flight recovers, main ran exactly once =="
mkrepo "$TMP/po" '{"tag_prefix":"v","test_cmd":"echo main-run >> \"$GATES_LOG/main.count\"; true"}'
printf '#!/usr/bin/env bash\nif [ ! -f "$GATES_LOG/pf-once" ]; then touch "$GATES_LOG/pf-once"; exec sleep 300; fi\necho pf-ok\n' > "$TMP/po/.rtc/pre-flight.sh"
chmod +x "$TMP/po/.rtc/pre-flight.sh"
stall_gate "$TMP/po" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
out=$(cat "$TMP/po/log/out")
is "preflight_only_retried: rc 0" "0" "$RIG_RC"
has "preflight_only_retried: the pre-flight recovered line" "$out" \
    "pre-flight gates STALLED once — passed on retry"
n=$(wc -l < "$TMP/po/log/main.count" 2>/dev/null | tr -d ' '); [ -n "$n" ] || n=0
is "preflight_only_retried: main suite ran EXACTLY once" "1" "$n"

echo "== a recovered stall with the tree changed mid-run still keeps the artefacts (M4) =="
mkrepo "$TMP/tc" '{"tag_prefix":"v","test_cmd":"if [ ! -f \"$GATES_LOG/once\" ]; then touch \"$GATES_LOG/once\"; exec sleep 300; fi; echo dirty >> dirty.txt; echo ok"}'
stall_gate "$TMP/tc" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
out=$(cat "$TMP/tc/log/out")
is "tree_changed_recovery: rc 0" "0" "$RIG_RC"
has "tree_changed_recovery: recovered line" "$out" "STALLED once — passed on retry"
has "tree_changed_recovery: NOT stamped (tree changed mid-run)" "$out" "NOT stamped"
p=$(sed -n 's/.*diagnosis kept in //p' "$TMP/tc/log/out" | head -1); p=${p%)}
if [ -n "$p" ] && [ -f "$p" ]; then ok "tree_changed_recovery: .attempt1.stall kept despite the tree change ($p)"
else bad "tree_changed_recovery: .attempt1.stall kept despite the tree change" "a real file" "${p:-<none printed>}"; fi
shopt -s nullglob
st=("$TMP/tc/.git/rtc-tested/"*)
shopt -u nullglob
if [ ${#st[@]} -eq 0 ]; then ok "tree_changed_recovery: no stamp written"; else bad "tree_changed_recovery: no stamp written" "none" "${#st[@]} stamp(s)"; fi

echo "== gate_once resolves stall_retries BEFORE forking (M3): invalid value, no gate launched =="
(
  eval "$(rig_one_fn "$ROOT/bin/rtc-ship.sh" gate_once)"
  eval "$(rig_one_fn "$ROOT/bin/rtc-ship.sh" watch_maybe_retry)"
  # Stub for dynamic dispatch: gate_once calls stall_retries by name, which static analysis
  # cannot see — that indirect invocation is the point of this stub.
  # shellcheck disable=SC2329
  stall_retries() { echo "✖ stub stall_retries: must be a non-negative integer, got 'x'" >&2; return 1; }
  gate_once "unit" "$TMP/unit-gate.log" "true"
  echo "rc=$?"
) > "$TMP/unit.out" 2>"$TMP/unit.err"
is "gate_once with invalid stall_retries returns 2" "rc=2" "$(cat "$TMP/unit.out")"
if [ -f "$TMP/unit-gate.log" ]; then bad "gate_once forked nothing on invalid config" "no log file" "$TMP/unit-gate.log exists"; else ok "gate_once forked nothing on invalid config"; fi
has "  and the error names the key" "$(cat "$TMP/unit.err")" "stall_retries"

rig_summary
