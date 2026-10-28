#!/usr/bin/env bash
# tests/test_ship_cleanup_optouts.sh — cleanup never touches the canonical checkout or default branch; the opt-outs.
#
# Part of the ship-loop rehearsal (the rig and its rationale: tests/lib/rehearsal.sh).
# Usage: bash tests/test_ship_cleanup_optouts.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

# Shipping the canonical checkout itself must reap nothing: that tree is what every other worktree
# is measured against, so deleting it would take the repo's only clean copy with it. RTC_MAIN is
# pinned because the derivation `git rev-parse --git-common-dir | sed 's#/.git$##'` returns a
# RELATIVE path when $WT is the primary checkout (pre-existing, unrelated to cleanup), which would
# fail the ship before the guard is ever reached.
D="$TMP/u10"; rehearse "$D"; fake_cache "$D" 0.1.0
rc=$( cd "$D/main" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 \
      RTC_SKIP_REFRESH=1 RTC_MAIN="$D/main" RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 \
      PUBLISHED_VERSION=0.1.0 RTC_SHIP_LOG_DIR="$D/logs" bash "$ROOT/bin/rtc-ship.sh" "$D/main" 0.1.0 'canonical' >"$D/out" 2>&1; echo $? )
is "shipping the canonical checkout ships" "0" "$rc"
is "  and does NOT remove it" "0" "$([ -d "$D/main" ] && echo 0 || echo 1)"
is "  and reports why it was not touched" "1" "$(grep -c 'canonical checkout' "$D/out")"

# What this case actually proves, and what it does NOT. Measured 2026-10-27 by deleting each
# safeguard from the script in turn: git refuses to delete a branch that is checked out, and refuses
# to delete the branch a remote's HEAD points at, so both `$DEFAULT_BRANCH` skips are unreachable
# during a real ship — the ship has already required $MAIN to be on $DEFAULT_BRANCH, which puts the
# default branch in `in_wt` and therefore behind the in_wt test. This test pins the OUTCOME (the
# default branch survives even when origin/HEAD points somewhere else, which is the echoprism
# `master` shape and the case where git's own protection stops applying), not either skip line.
# Deleting the remote skip leaves this test green — that is a true negative, documented in the
# script, not a gap in this test.
D="$TMP/u11"; rehearse "$D"
( cd "$D/main" || exit 1
  # origin/HEAD must point at a branch that is (a) NOT the default branch this repo's config names,
  # and (b) deliberately UNMERGED, so the sweep never reaches it. Both matter: if it pointed at a
  # merged branch, `git push --delete` would refuse it as the remote's current branch and the
  # "the sweep still sweeps" assertion could never pass.
  git checkout -q -b trunk
  echo unreleasable > unreleasable.txt
  git add -A && git -c user.email=t@t -c user.name=t commit -qm unreleasable
  git push -q origin trunk
  git checkout -q main
  git -C "$D/origin.git" symbolic-ref HEAD refs/heads/trunk
  # a MERGED topic branch, to prove the sweep still sweeps when it should
  git branch topic && git push -q origin topic )
is "a config-named default branch survives when origin/HEAD points elsewhere" "0" "$(ship_c "$D")"
is "  origin/main is NOT deleted" "main" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x main || echo '')"
is "  while the merged topic branch IS swept" "" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x topic || echo '')"
is "  and the unmerged branch origin/HEAD points at is left alone" "trunk" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x trunk || echo '')"

# The opt-outs. Reaping is the default (every u-test above runs with it on); the user may skip
# it for ONE ship (--no-reap, transient), permanently ("reap": false in rtc-ship.json), or via
# the pre-existing environment route (RTC_SKIP_CLEANUP=1). A skip is ANNOUNCED, never silent:
# a tool that quietly stops tidying looks broken from its own output.
D="$TMP/u12"; rehearse "$D"
( cd "$D/main" && git branch topic/merged )
is "the default ship reaps (baseline for the opt-outs)" "0" "$(ship_c "$D")"
is "  the merged branch is gone" "" "$(branches "$D/main" | grep -x 'topic/merged' || echo '')"

D="$TMP/u13"; rehearse "$D"
( cd "$D/main" && git branch topic/merged )
rc=$(ship "$D" 0.2.0 'second' --no-reap)
is "--no-reap ships" "0" "$rc"
is "  and the merged branch SURVIVES" "topic/merged" "$(branches "$D/main" | grep -x 'topic/merged' || echo '')"
is "  and the shipped worktree survives" "0" "$([ -d "$D/wt" ] && echo 0 || echo 1)"
has "  and the skip is announced" "$(cat "$D/out")" "cleanup: skipped (--no-reap)"

D="$TMP/u14"; rehearse "$D"
( cd "$D/main" && git branch topic/merged )
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["reap"] = False
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
( cd "$D/wt" && git add -A && git commit -qm 'opt out of reaping' )
rc=$(ship_c "$D")
is "a config reap:false ships" "0" "$rc"
is "  and the merged branch SURVIVES" "topic/merged" "$(branches "$D/main" | grep -x 'topic/merged' || echo '')"
is "  and the shipped worktree survives" "0" "$([ -d "$D/wt" ] && echo 0 || echo 1)"
has "  and the skip names the config route" "$(cat "$D/out")" "reap"

D="$TMP/u15"; rehearse "$D"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["reap"] = "flase"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
( cd "$D/wt" && git add -A && git commit -qm 'typo the opt-out' )
rc=$(ship_c "$D")
is "a NON-boolean reap value fails the ship BEFORE any irreversible step" "2" "$rc"
has "  naming the bad value" "$(cat "$D/out")" "flase"
is "  and nothing was published" "0" "$(grep -c 'release published' "$D/out")"

summary
