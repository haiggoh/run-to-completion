#!/usr/bin/env bash
# tests/test_declared_surface.sh — every repo that rtc-ship.sh can ship is COVERED, and the gate
# that covers it actually READ something.
#
# A repo takes one of two paths through the version gate: its OWN tests/test_version_consistency.sh,
# or the declared-surface fallback in rtc-ship.json. The fallback is fine — but only if the config
# declares every version surface the repo actually HAS. A repo with a VERSION file and a ROADMAP
# that declares neither ships with two of its four surfaces unchecked, and the gate still prints
# "version surfaces agree". Nothing about that looks wrong, which is why it needs a test.
#
# The second half of this test is the one that earns its keep: the gate must have READ each surface
# it claims to check. "<none>" means it read nothing and compared nothing — the exact shape of the
# 0.6.7 defect, where the gate resolved its repo root to "/" and reported a consistent tree as
# disagreeing (and, in a repo with no git, a disagreeing tree as consistent).
#
# Usage: bash tests/test_declared_surface.sh
# Env:   RTC_REPOS_ROOT  where the shippable repos live (default $HOME/ClaudeWorkspace). Absent
#                       means the test SKIPS — a stranger's machine has no workspace to audit.
set -uo pipefail
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }

REPOS=${RTC_REPOS_ROOT:-$HOME/ClaudeWorkspace}
if [ ! -d "$REPOS" ]; then
  printf 'skipped: no repo workspace at %s\n' "$REPOS"; exit 0
fi

cfg() {  # cfg <repo> <key> [default]
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
v=d.get(sys.argv[2])
print(sys.argv[3] if v is None else v)' "$1/rtc-ship.json" "$2" "${3:-}" 2>/dev/null
}

audited=0
for dir in "$REPOS"/*/; do
  repo=${dir%/}
  [ -f "$repo/rtc-ship.json" ] || continue
  # A WORKTREE has .git as a FILE, a checkout as a directory. Worktrees are the same repo as their
  # parent: auditing both double-counts, and a worktree's config can be a topic-branch edit.
  [ -f "$repo/.git" ] && continue
  audited=$((audited+1))
  name=$(basename "$repo")

  # --- the gate must PASS on the repo as it stands -------------------------------------------
  out=$("$ROOT/bin/rtc-ship.sh" --versions-only "$repo" 2>&1); rc=$?
  is "$name: the version gate passes" "0" "$rc"
  # --- and must have READ every surface it printed --------------------------------------------
  is "$name: the gate read every surface it named (no <none>)" "0" "$(printf '%s' "$out" | grep -c '<none>')"

  # --- coverage: own test, or every surface on disk is declared --------------------------------
  if [ -x "$repo/tests/test_version_consistency.sh" ]; then
    ok "$name: uses its own consistency test"
  else
    ok "$name: uses the declared-surface fallback"
    # A surface that EXISTS but is not declared is checked by nothing. Compare against the tool's
    # own defaults so a repo relying on a default is not accused of omitting it.
    vf=$(cfg "$repo" version_file "")
    [ -n "$vf" ] || vf=""
    if [ -f "$repo/VERSION" ]; then
      is "$name: has a VERSION file, so version_file must be declared" "VERSION" "$vf"
    else
      is "$name: no VERSION file, so version_file must stay undeclared" "" "$vf"
    fi
    rm_=$(cfg "$repo" roadmap "")
    if [ -f "$repo/docs/ROADMAP.md" ]; then
      is "$name: has docs/ROADMAP.md, so roadmap must be declared" "docs/ROADMAP.md" "$rm_"
    else
      is "$name: no ROADMAP, so roadmap must stay undeclared" "" "$rm_"
    fi
    # No changelog is legitimate (a web app may have none) — but then the config must SAY so,
    # because the default is CHANGELOG.md and an undeclared one is silently skipped.
    cl=$(cfg "$repo" changelog "CHANGELOG.md")
    if [ -f "$repo/CHANGELOG.md" ]; then
      has "$name: the changelog it declares is the one it has" "$cl" "CHANGELOG.md"
    else
      is "$name: no CHANGELOG.md, so changelog must be declared empty" "" "$cl"
    fi
  fi
done

# The audit must have SEEN the repos. An empty loop passes every assertion above by never running
# them, which is how a check like this silently rots: a renamed workspace root turns it into a
# no-op that still exits 0.
# The audit must have SEEN repos — an empty loop passes every assertion above by never running them.
# An EXPLICIT RTC_REPOS_ROOT that yields none is a failure (a set-but-wrong override never falls
# through). The DEFAULT location holding none is another machine's layout: skip, out loud.
# (2026-10-25 review: a fixed floor of 5 failed every machine with a smaller workspace.)
if [ "$audited" -eq 0 ] && [ -z "${RTC_REPOS_ROOT:-}" ]; then
  printf 'skipped: no rtc-ship.json repos under %s (set RTC_REPOS_ROOT to audit elsewhere)\n' "$REPOS"; exit 0
fi
is "the audit found repos to cover" "yes" "$([ "$audited" -ge 1 ] && echo yes || echo "no ($audited)")"
printf '\naudited %d repo(s)\npassed %d, failed %d\n' "$audited" "$pass" "$fail"
[ "$fail" -eq 0 ]
