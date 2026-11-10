#!/usr/bin/env bash
# tests/test_gate_supervision.sh — EVERY gate (config test_cmd, default pytest, .rtc/pre-flight.sh)
# runs stdin-detached and under watch_gate; a stall on any of them is named and ends the gate with
# rc 124. Pre-flight still runs concurrently with the main suite.
#
# Cases: config_gate_stdin_is_dev_null, preflight_stall_is_named, default_pytest_stall_is_named.
# Rig: tests/lib/stall_rig.sh (sourced; each gate runs --test-only under a 30 s owned guard).
#
# Usage: bash tests/test_gate_supervision.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_gate_supervision.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/stall_rig.sh"

TMP=$(mktemp -d)
stall_rig_init "$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset RTC_STALL_SECONDS RTC_STALL_POLL RTC_STALL_KILL_GRACE RTC_BASELINE

# A stub at the path gates() looks first for pytest ($HOME/.local/bin/pytest under the scratch
# HOME), so the default-pytest cases control what "pytest" does without a real suite.
stub_pytest() {  # stub_pytest <dir> <body>
  cat > "$1/home/.local/bin/pytest" <<STUB
#!/usr/bin/env bash
$2
STUB
  chmod +x "$1/home/.local/bin/pytest"
}

echo "== a config gate reading stdin gets EOF, not a hang =="
# The suite holds a FIFO open read-write (no writer ever writes): without </dev/null on the gate
# the read blocks forever; with it the read gets EOF. The evidence lands in the kept harness log
# dir (gates() deletes its own log dir on success, so the assertion cannot read that).
mkrepo "$TMP/stdin" '{"tag_prefix":"v","test_cmd":"read -r x; echo \"got=[$x]\" > \"$GATES_LOG/got\""}'
mkfifo "$TMP/stdin/fifo"
exec 3<>"$TMP/stdin/fifo"
s=$(date +%s)
RIG_STDIN="$TMP/stdin/fifo" stall_gate "$TMP/stdin" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
e=$(date +%s)
exec 3>&-
is "the gate passed" "0" "$RIG_RC"
if [ $((e - s)) -lt 10 ]; then ok "it did not block on the held-open stdin ($((e - s)) s)"
else bad "it did not block on the held-open stdin" "< 10 s" "$((e - s)) s"; fi
is "stdin was EOF (read got nothing)" "got=[]" "$(cat "$TMP/stdin/log/got" 2>/dev/null)"

echo "== a stalled pre-flight gate is named =="
mkrepo "$TMP/pf"
stub_pytest "$TMP/pf" 'echo "1 passed in 0.01s"'
printf '#!/usr/bin/env bash\nexec sleep 300\n' > "$TMP/pf/.rtc/pre-flight.sh"
chmod +x "$TMP/pf/.rtc/pre-flight.sh"
( cd "$TMP/pf" && git add -A && git -c user.email=t@t -c user.name=t commit -qm pf )
stall_gate "$TMP/pf" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "the gate's rc is the stall code 124" "124" "$RIG_RC"
has "the output says STALLED" "$(cat "$TMP/pf/log/out")" "STALLED"
diag=$(sed -n 's/^.*diagnosis in //p' "$TMP/pf/log/out" | head -1)
is "the diagnosis names the label" "STALLED pre-flight gates" "$(head -1 "$diag" 2>/dev/null | cut -d: -f1)"

echo "== a stalled default-pytest gate is named =="
mkrepo "$TMP/py"
stub_pytest "$TMP/py" 'exec sleep 300'
stall_gate "$TMP/py" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "the gate's rc is the stall code 124" "124" "$RIG_RC"
has "the output says STALLED" "$(cat "$TMP/py/log/out")" "STALLED"
diag=$(sed -n 's/^.*diagnosis in //p' "$TMP/py/log/out" | head -1)
is "the diagnosis names the label" "STALLED pytest main" "$(head -1 "$diag" 2>/dev/null | cut -d: -f1)"

rig_summary
