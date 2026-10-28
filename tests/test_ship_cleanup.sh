#!/usr/bin/env bash
# tests/test_ship_cleanup.sh — cleanup after a confirmed release: the reap, and what it must never sweep.
#
# Part of the ship-loop rehearsal (the rig and its rationale: tests/lib/rehearsal.sh).
# Usage: bash tests/test_ship_cleanup.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

D="$TMP/u1"; rehearse "$D"
( cd "$D/wt" && git push -q origin feat/ship )      # the topic branch reached the remote too
is "a confirmed release reaps the shipped worktree" "0" "$(ship_c "$D")"
is "  the worktree directory is gone" "" "$([ -d "$D/wt" ] && echo present || echo '')"
is "  the branch is gone locally" "" "$(git -C "$D/main" branch --list feat/ship)"
is "  the MERGED REMOTE ref is gone too" "" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x feat/ship || echo '')"
has "  and each step is reported" "$(cat "$D/out")" "cleanup: removed worktree"
has "  including the remote deletion" "$(cat "$D/out")" "cleanup: deleted origin/feat/ship"
is "  and the release still reports live" "1" "$(grep -c 'is live' "$D/out")"
is "  with nothing precious, no backup is taken" "0" "$(bk | wc -l | tr -d ' ')"

D="$TMP/u2"; rehearse "$D"
( cd "$D/wt" && git push -q origin feat/ship )
is "RTC_SKIP_CLEANUP=1 keeps the worktree" "0" "$(ship_c "$D" RTC_SKIP_CLEANUP=1)"
is "  and the branch" "feat/ship" "$(branches "$D/main" | grep -x feat/ship || echo '')"
is "  and the remote ref" "feat/ship" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x feat/ship || echo '')"
is "  and the skip is announced, naming the route" "1" \
   "$(grep -c 'cleanup: skipped (RTC_SKIP_CLEANUP=1)' "$D/out")"

# A merged branch that ANOTHER worktree still has checked out must survive both sweeps: a
# concurrent session may be standing in it. This is the guard that makes the routine safe to run
# unattended, and it is tested by planting exactly that worktree.
D="$TMP/u3"; rehearse "$D"
( cd "$D/main" && git branch other/merged && git push -q origin other/merged \
    && git worktree add -q "$D/wt2" other/merged )
is "a merged branch held by ANOTHER worktree survives" "0" "$(ship_c "$D")"
is "  locally" "other/merged" "$(branches "$D/main" | grep -x other/merged || echo '')"
is "  and on the remote" "other/merged" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x other/merged || echo '')"
is "  and its worktree survives" "0" "$([ -d "$D/wt2" ] && echo 0 || echo 1)"
is "  and the default branch is never swept locally" "main" "$(branches "$D/main" | grep -x main || echo '')"
# Pinned separately from the local one: `git branch -d` already refuses to delete a checked-out or
# current branch, so the LOCAL skip is belt-and-braces and deleting it from the script changes
# nothing observable. The REMOTE skip is the load-bearing one — `git push origin --delete` knows
# nothing about local worktrees or the default branch, so removing it really does delete origin/main.
is "  and never the default branch on the remote either" "main" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x main || echo '')"

summary
