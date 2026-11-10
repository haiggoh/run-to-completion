#!/usr/bin/env bash
# tests/test_gate_baseline.sh — RTC_BASELINE=1 re-runs a failed gate on origin/<default> in a
# throwaway worktree and labels the failed lines branch-only vs pre-existing. Diagnosis only:
# the gate still fails, and no worktree is left behind — also when the baseline itself stalls.
#
# Cases: baseline_reports_but_still_fails, baseline_off_by_default, baseline_leaves_no_worktree.
# Rig: tests/lib/stall_rig.sh (sourced; each gate runs --test-only under a 30 s owned guard).
#
# Usage: bash tests/test_gate_baseline.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_gate_baseline.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/stall_rig.sh"

TMP=$(mktemp -d)
stall_rig_init "$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset RTC_STALL_SECONDS RTC_STALL_POLL RTC_STALL_KILL_GRACE RTC_BASELINE

# A scratch repo with a bare origin: origin/HEAD (master) carries test_cmd "echo FAILED t::a;
# exit 1"; the checked-out topic branch carries "echo FAILED t::a; echo FAILED t::b; exit 1".
# The working tree is left on topic, so --test-only gates the branch state and the baseline
# worktree at origin/master runs the default-branch command.
mkbaserepo() {  # mkbaserepo <dir>
  local d=$1 bare="$1/bare.git"
  git init -q --bare "$bare"
  mkdir -p "$d/w/.claude-plugin" "$d/w/tests" "$d/w/.rtc" "$d/w/home/.local/bin"
  printf '{"name":"g","version":"0.1.0"}\n' > "$d/w/.claude-plugin/plugin.json"
  printf '# Changelog\n\n## 0.1.0\n\nx\n' > "$d/w/CHANGELOG.md"
  printf 'log/\n' > "$d/w/.gitignore"
  printf '{"tag_prefix":"v","test_cmd":"echo FAILED t::a; exit 1"}\n' > "$d/w/rtc-ship.json"
  ( cd "$d/w" && git init -q && git add -A \
      && git -c user.email=t@t -c user.name=t commit -qm base \
      && git remote add origin "$bare" && git push -q origin HEAD:master \
      && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master \
      && git checkout -qb topic \
      && printf '{"tag_prefix":"v","test_cmd":"echo FAILED t::a; echo FAILED t::b; exit 1"}\n' > rtc-ship.json \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm topic )
}
wtcount() { git -C "$1/w" worktree list 2>/dev/null | wc -l | tr -d ' '; }
# print the lines of the named "label:" section of an output file
sect() { awk -v s="$1" '$0==s":"{want=1;next} /^[a-z-]+:$/{want=0} want' "$2"; }

echo "== RTC_BASELINE=1 labels the failed lines; the gate still fails =="
mkbaserepo "$TMP/bl"
before=$(wtcount "$TMP/bl")
stall_gate "$TMP/bl/w" RTC_BASELINE=1 RTC_STALL_SECONDS=30 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "the gate still fails with exactly the test-failure rc 1 (baseline did not change it)" "1" "$RIG_RC"
bo=$(sect branch-only "$TMP/bl/w/log/out")
pe=$(sect pre-existing "$TMP/bl/w/log/out")
has "output has a branch-only section" "$(cat "$TMP/bl/w/log/out")" "branch-only:"
has "branch-only names t::b" "$bo" "t::b"
lacks "branch-only omits t::a" "$bo" "t::a"
has "output has a pre-existing section" "$(cat "$TMP/bl/w/log/out")" "pre-existing:"
has "pre-existing names t::a" "$pe" "t::a"
lacks "pre-existing omits t::b" "$pe" "t::b"
is "no worktree left behind" "$before" "$(wtcount "$TMP/bl")"

echo "== off by default: no labels, no extra worktree =="
mkbaserepo "$TMP/off"
before=$(wtcount "$TMP/off")
stall_gate "$TMP/off/w" RTC_STALL_SECONDS=30 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
lacks "no branch-only section without RTC_BASELINE" "$(cat "$TMP/off/w/log/out")" "branch-only:"
is "no worktree left behind" "$before" "$(wtcount "$TMP/off")"

echo "== the worktree is cleaned up even when the baseline itself stalls =="
mkbaserepo "$TMP/stall"
# origin/master's test_cmd now sleeps, so the BASELINE run is the one that stalls
( cd "$TMP/stall/w" && git checkout -q master \
    && printf '{"tag_prefix":"v","test_cmd":"exec sleep 300"}\n' > rtc-ship.json \
    && git add -A && git -c user.email=t@t -c user.name=t commit -qm sleep \
    && git push -q origin HEAD:master && git checkout -q topic )
before=$(wtcount "$TMP/stall")
stall_gate "$TMP/stall/w" RTC_BASELINE=1 RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 RTC_STALL_KILL_GRACE=1
is "the stalled BASELINE did not leak its 124 into the gate rc (still 1)" "1" "$RIG_RC"
has "the baseline run happened" "$(cat "$TMP/stall/w/log/out")" "baseline:"
is "no worktree left behind after a stalled baseline" "$before" "$(wtcount "$TMP/stall")"

rig_summary
