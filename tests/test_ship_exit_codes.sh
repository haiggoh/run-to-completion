#!/usr/bin/env bash
# tests/test_ship_exit_codes.sh — the SHIP path (not just --test-only) carries the exit-code
# vocabulary: a stalled gate exits 124 (the timeout(1) convention), an ordinary gate failure
# exits 1, and usage/config errors keep exit 2. The change is additive: any caller that treats
# non-zero as failure keeps working.
#
# Cases: ship_stall_exits_124, ship_fail_exits_1, test_only_stall_exits_124 (surface parity pin),
# ship_preflight_stall_exits_124 (gate-kind coverage), docs_pin_the_vocabulary (--help + README),
# success_exits_0_and_usage_exits_2 (the other two ends), plus a nothing-tagged assertion per case.
# Rig: tests/lib/stall_rig.sh (sourced; every full ship run is under a 120 s guard THE TEST OWNS —
# without the watchdog a stalled gate would hang the suite forever; 120 s not 30 s because under
# heavy machine load the door checks alone can eat most of 30 s, and even 60 s proved tight at load ~100).
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
# Optional 3rd arg: body of an executable .rtc/pre-flight.sh hook.
mkshiprepo() {  # mkshiprepo <dir> <rtc-ship.json-body> [pre-flight-body]
  local d=$1 body=$2 pf=${3:-}
  mkdir -p "$d/.claude-plugin"
  printf '{"name":"g","version":"9.9.9"}\n' > "$d/.claude-plugin/plugin.json"
  printf '# Changelog\n\n## [9.9.9] — 2026-11-10 — probe\n\nx\n' > "$d/CHANGELOG.md"
  printf 'log/\nshiplogs/\n' > "$d/.gitignore"
  printf '%s\n' "$body" > "$d/rtc-ship.json"
  if [ -n "$pf" ]; then mkdir -p "$d/.rtc"; printf '%s\n' "$pf" > "$d/.rtc/pre-flight.sh"; chmod +x "$d/.rtc/pre-flight.sh"; fi
  ( cd "$d" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init \
      && git init -q --bare "$d-origin.git" && git remote add origin "$d-origin.git" \
      && git push -q origin main )
}

ship_full() {  # ship_full <dir> [env=val...] — FULL ship path under a 120 s owned guard; sets RIG_RC
  local d=$1; shift
  mkdir -p "$d/log" "$d/shiplogs" "$d/home"
  ( cd "$d" && exec env HOME="$d/home" GATES_LOG="$d/log" RTC_SHIP_LOG_DIR="$d/shiplogs" "$@" \
      bash "$ROOT/bin/rtc-ship.sh" "$d" 9.9.9 "probe" >"$d/log/out" 2>&1 </dev/null ) &
  RIG_GPID=$!
  STALL_RIG_GROUPS="$STALL_RIG_GROUPS $RIG_GPID"
  # 60 s, not 30: under heavy machine load the door checks (fetch/rebase/ps) alone can eat most of
  # 30 s, and the guard must stay strictly above "watchdog fires + tree kill" (~5-10 s after the
  # gate starts), else a slow machine reads as a test failure (rc 143) instead of the ship's rc.
  ( sleep 120; kill -TERM -- "-$RIG_GPID" 2>/dev/null; sleep 2; kill -KILL -- "-$RIG_GPID" 2>/dev/null ) &
  RIG_GUARD=$!
  wait "$RIG_GPID"; RIG_RC=$?
  kill -TERM -- "-$RIG_GUARD" 2>/dev/null
  wait "$RIG_GUARD" 2>/dev/null
  return "$RIG_RC"
}

ship_testonly() {  # ship_testonly <dir> [env=val...] — --test-only under the same 60 s guard
  local d=$1; shift
  mkdir -p "$d/log" "$d/home"
  ( cd "$d" && exec env HOME="$d/home" GATES_LOG="$d/log" "$@" \
      bash "$ROOT/bin/rtc-ship.sh" --test-only "$d" >"$d/log/out" 2>&1 </dev/null ) &
  RIG_GPID=$!
  STALL_RIG_GROUPS="$STALL_RIG_GROUPS $RIG_GPID"
  ( sleep 120; kill -TERM -- "-$RIG_GPID" 2>/dev/null; sleep 2; kill -KILL -- "-$RIG_GPID" 2>/dev/null ) &
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
is "a failed ship tagged NOTHING in the scratch repo" "" "$(git -C "$TMP/stall" tag -l)"

echo "== an ordinary gate failure on the full ship path still exits 1 =="
mkshiprepo "$TMP/fail" '{"tag_prefix":"v","test_cmd":"exit 1","default_branch":"main","require_default_branch_checkout":false}'
ship_full "$TMP/fail"
is "the ship's rc is 1 (additive: non-zero callers unaffected)" "1" "$RIG_RC"
is "a failed ship tagged NOTHING in the scratch repo" "" "$(git -C "$TMP/fail" tag -l)"

echo "== surface parity: --test-only on the same stall also exits 124 =="
mkshiprepo "$TMP/to" '{"tag_prefix":"v","test_cmd":"exec sleep 300","default_branch":"main"}'
ship_testonly "$TMP/to" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "--test-only's rc is the stall code 124" "124" "$RIG_RC"

echo "== a stalled PRE-FLIGHT gate on the full ship path also exits 124 (gate-kind coverage) =="
mkshiprepo "$TMP/pf" '{"tag_prefix":"v","test_cmd":"true","default_branch":"main","require_default_branch_checkout":false}' '#!/usr/bin/env bash
exec sleep 300'
ship_full "$TMP/pf" RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "the ship's rc is 124 when the pre-flight gate stalls" "124" "$RIG_RC"
has "the output names the pre-flight gate as STALLED" "$(cat "$TMP/pf/log/out")" "pre-flight gates STALLED"

echo "== R4: the vocabulary is documented where the verdict is read (--help, README) =="
help=$(bash "$ROOT/bin/rtc-ship.sh" --help 2>&1)
has "--help prints the Exit codes block" "$help" "Exit codes"
has "--help pins the 124 stall code" "$help" "124"
has "--help pins usage/config as exit 2" "$help" "2     usage or config error"
readme=$(cat "$ROOT/README.md")
has "README has the Exit codes section" "$readme" "### Exit codes"
has "README pins the 124 stall code" "$readme" "**124**"

echo "== R5: success exits 0, usage error exits 2 (the other two ends of the vocabulary) =="
mkshiprepo "$TMP/ok" '{"tag_prefix":"v","test_cmd":"true","default_branch":"main"}'
( cd "$TMP/ok" && HOME="$TMP/ok/home" bash "$ROOT/bin/rtc-ship.sh" --versions-only "$TMP/ok" >/dev/null 2>&1 ); rc=$?
is "--versions-only on agreeing surfaces exits 0" "0" "$rc"
( cd "$TMP/ok" && HOME="$TMP/ok/home" bash "$ROOT/bin/rtc-ship.sh" --bogus >/dev/null 2>&1 ); rc=$?
is "an unknown flag exits 2 (usage error)" "2" "$rc"

rig_summary
