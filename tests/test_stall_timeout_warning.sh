#!/usr/bin/env bash
# tests/test_stall_timeout_warning.sh — a gate whose per-test --timeout is >= the stall window
# gets a ⚠ phase line BEFORE it runs: the watchdog always kills the gate first, so a
# pytest-timeout dump at that timeout can never print — the warning names both numbers up front.
#
# Cases: warns_when_ge, quiet_when_below, space_form, largest_wins, preflight_scanned,
# rc_unchanged.
# Rig: tests/lib/stall_rig.sh (sourced; each case runs --test-only under a 30 s owned guard).
#
# Usage: bash tests/test_stall_timeout_warning.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_stall_timeout_warning.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/stall_rig.sh"

TMP=$(mktemp -d)
stall_rig_init "$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset RTC_STALL_SECONDS RTC_STALL_POLL RTC_STALL_KILL_GRACE RTC_BASELINE

echo "== --timeout=900 with the default 600 s stall window warns =="
mkrepo "$TMP/wg" '{"tag_prefix":"v","test_cmd":"true --timeout=900"}'
stall_gate "$TMP/wg"
out=$(cat "$TMP/wg/log/out")
is "warns_when_ge: rc unchanged (gate passed)" "0" "$RIG_RC"
has "warns_when_ge: the phase line names both numbers" "$out" \
    "tests (config): per-test --timeout=900s ≥ stall window 600s"

echo "== --timeout=300 stays quiet =="
mkrepo "$TMP/qb" '{"tag_prefix":"v","test_cmd":"true --timeout=300"}'
stall_gate "$TMP/qb"
lacks "quiet_when_below: no warning" "$(cat "$TMP/qb/log/out")" "per-test --timeout"

echo "== the space form '--timeout 900' is read too =="
mkrepo "$TMP/sf" '{"tag_prefix":"v","test_cmd":"true --timeout 900"}'
stall_gate "$TMP/sf"
has "space_form: warns" "$(cat "$TMP/sf/log/out")" "per-test --timeout=900s ≥ stall window 600s"

echo "== the largest of several --timeout values wins; --timeout-method is not misread =="
mkrepo "$TMP/lw" '{"tag_prefix":"v","test_cmd":"true --timeout=300 --timeout-method=thread --timeout 900"}'
stall_gate "$TMP/lw"
has "largest_wins: 900 not 300" "$(cat "$TMP/lw/log/out")" "per-test --timeout=900s ≥ stall window 600s"
lacks "largest_wins: no garbage from --timeout-method" "$(cat "$TMP/lw/log/out")" "per-test --timeout=s"

echo "== a pre-flight.sh carrying --timeout=900 warns under its own label =="
mkrepo "$TMP/pf" '{"tag_prefix":"v","test_cmd":"true"}'
printf '#!/usr/bin/env bash\n# second venv suite: pytest --timeout=900 --timeout-method=thread\nexit 0\n' > "$TMP/pf/.rtc/pre-flight.sh"
chmod +x "$TMP/pf/.rtc/pre-flight.sh"
stall_gate "$TMP/pf"
out=$(cat "$TMP/pf/log/out")
has "preflight_scanned: warns with the pre-flight label" "$out" \
    "pre-flight gates: per-test --timeout=900s ≥ stall window 600s"
is "preflight_scanned: rc 0" "0" "$RIG_RC"

echo "== a gate with no --timeout: quiet, rc 0 =="
mkrepo "$TMP/rc" '{"tag_prefix":"v","test_cmd":"true"}'
stall_gate "$TMP/rc"
is "rc_unchanged: rc 0" "0" "$RIG_RC"
lacks "rc_unchanged: no warning" "$(cat "$TMP/rc/log/out")" "per-test --timeout"

rig_summary
