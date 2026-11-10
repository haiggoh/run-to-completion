#!/usr/bin/env bash
# tests/lib/stall_rig.sh — shared rig for the gate-stall-watchdog suites. SOURCED, never run:
# the repo gate collects tests/test_*.sh, and this file lives in lib/ so it is never collected.
#
# Each suite file makes its own mktemp -d and calls stall_rig_init with it; one shared summary
# function computes the exit status. Harness helpers (ok/bad/is/has + mkrepo) follow
# tests/test_gates.sh; `lacks` is added for the no-argv-leak assertions.
#
# Every gate run is wrapped in a 30 s guard THE TEST OWNS: without the watchdog (the red run)
# a stalled gate would otherwise hang the suite forever. set -m gives each background job its
# own process group (verified on this machine's bash 3.2.57), so the guard can TERM/KILL the
# gate's whole tree even after rtc-ship itself is dead, and the EXIT trap reaps any group a
# case left behind.
#
# Stall cases run with RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 and the tests-only
# RTC_STALL_KILL_GRACE=1 (default 5), so a stall case ends in ~5-10 s — far under the suite's
# next-slowest file (134 s at the Phase 0 baseline).
#
# Usage: bash tests/test_stall_detect.sh [--help]   (this file is sourced by those suites)

STALL_RIG_DIR=""
STALL_RIG_GROUPS=""

stall_rig_init() {  # stall_rig_init <suite-tmpdir>
  STALL_RIG_DIR=$1
  set -m
  trap stall_rig_reap EXIT
}

stall_rig_reap() {  # kill every group a gate ran in, then remove the suite's scratch tree
  local p
  for p in $STALL_RIG_GROUPS; do kill -KILL -- "-$p" 2>/dev/null; done
  [ -n "$STALL_RIG_DIR" ] && rm -rf "$STALL_RIG_DIR"
  :
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "stall_rig.sh is sourced by the tests/test_stall_*.sh suites, never run directly" >&2
  exit 2
fi

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "must NOT contain: $3" "found" ;; *) ok "$1" ;; esac; }

rig_summary() {  # the suite's last command: prints the tally; its rc is the suite's exit status
  printf '\npassed %d, failed %d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

# A scratch repo whose rtc-ship.json carries exactly the body given (or the default). Fresh per
# case: gates() stamps a passing tree, and reuse would test the stamp, not the gate.
mkrepo() {  # mkrepo <dir> [rtc-ship.json-body]
  local d=$1 body=${2:-}
  mkdir -p "$d/.claude-plugin" "$d/tests" "$d/.rtc" "$d/home/.local/bin"
  printf '{"name":"g","version":"0.1.0"}\n' > "$d/.claude-plugin/plugin.json"
  printf '# Changelog\n\n## 0.1.0\n\nx\n' > "$d/CHANGELOG.md"
  printf 'log/\n' > "$d/.gitignore"
  if [ -n "$body" ]; then printf '%s\n' "$body" > "$d/rtc-ship.json"
  else printf '{"tag_prefix":"v"}\n' > "$d/rtc-ship.json"; fi
  ( cd "$d" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
}

RIG_GPID=""; RIG_GUARD=""; RIG_RC=""
stall_gate() {  # stall_gate <dir> [env=val...] — run --test-only under the 30 s owned guard; sets RIG_RC
  local d=$1; shift
  mkdir -p "$d/log"
  ( cd "$d" && exec env HOME="$d/home" GATES_LOG="$d/log" "$@" \
      bash "$ROOT/bin/rtc-ship.sh" --test-only "$d" >"$d/log/out" 2>&1 <"${RIG_STDIN:-/dev/null}" ) &
  RIG_GPID=$!
  STALL_RIG_GROUPS="$STALL_RIG_GROUPS $RIG_GPID"
  ( sleep 30; kill -TERM -- "-$RIG_GPID" 2>/dev/null; sleep 2; kill -KILL -- "-$RIG_GPID" 2>/dev/null ) &
  RIG_GUARD=$!
  wait "$RIG_GPID"; RIG_RC=$?
  kill -TERM -- "-$RIG_GUARD" 2>/dev/null
  wait "$RIG_GUARD" 2>/dev/null
  return "$RIG_RC"
}

# Extract ONE top-level function definition from a script, so a case can unit-test it in a
# subshell with stubbed ps/pgrep: sourcing rtc-ship.sh would RUN the ship flow (no source guard).
rig_one_fn() {  # rig_one_fn <script> <name> — print just that function block
  awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{"{p=1} p{print} p&&/^\}$/{exit}' "$1"
}
