#!/usr/bin/env bash
# tests/test_ship_cleanup_rescue.sh — cleanup rescues precious ignored files and keeps unmerged worktrees.
#
# Part of the ship-loop rehearsal (the rig and its rationale: tests/lib/rehearsal.sh).
# Usage: bash tests/test_ship_cleanup_rescue.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

# HALF ONE of the trap: git collapses a wholly-ignored directory to 'sub/', so the name cannot tell
# a Finder-junk directory from a real one. Inspecting it is the whole rule.
D="$TMP/u4"; rehearse "$D"
( cd "$D/wt" && mkdir -p sub && echo finder > sub/.DS_Store \
    && printf 'sub/\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm 'ignore sub' )
is "a .DS_Store-only ignored dir is noise" "0" "$(ship_c "$D")"
is "  so no backup is taken" "0" "$(bk | wc -l | tr -d ' ')"

# HALF TWO: the same collapsed shape holding junk AND the only copy of something real.
D="$TMP/u5"; rehearse "$D"
( cd "$D/wt" && mkdir -p sub && echo finder > sub/.DS_Store && echo 'the only copy' > sub/ledger.md \
    && printf 'sub/\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm 'ignore sub' )
is "a collapsed dir holding junk AND a real file is NOT noise" "0" "$(ship_c "$D")"
is "  so the real file is rescued" "sub/ledger.md" "$(bk | grep -x 'sub/ledger.md' || echo '')"
has "  and the rescue is reported" "$(cat "$D/out")" "backed up"

# A DIRECTORY component excuses a path; a substring would excuse its neighbours too. 'myvenv/plan.md'
# is a ledger, not a virtualenv — the second half of the same trap.
D="$TMP/u6"; rehearse "$D"
( cd "$D/wt" && mkdir -p myvenv venv && echo plan > myvenv/plan.md && echo x > venv/marker \
    && printf 'myvenv/\nvenv/\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm ignore )
is "the component rule rescues myvenv/plan.md" "0" "$(ship_c "$D")"
is "  and it is backed up" "myvenv/plan.md" "$(bk | grep -x 'myvenv/plan.md' || echo '')"
is "  while venv/marker is cache and is not backed up" "0" "$(bk | grep -c 'venv/marker')"

# The generalized config.local.sh rule: an ignored file the canonical checkout already holds,
# byte for byte, is not information this worktree alone has.
D="$TMP/u7"; rehearse "$D"
( cd "$D/wt" && mkdir -p config && echo same > config/config.local.sh \
    && printf 'config/config.local.sh\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm ignore )
mkdir -p "$D/main/config" && echo same > "$D/main/config/config.local.sh"
is "an ignored file IDENTICAL to the canonical copy is not precious" "0" "$(ship_c "$D")"
is "  so no backup is taken" "0" "$(bk | wc -l | tr -d ' ')"

D="$TMP/u8"; rehearse "$D"
( cd "$D/wt" && mkdir -p config && echo 'worktree copy, edited' > config/config.local.sh \
    && printf 'config/config.local.sh\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm ignore )
mkdir -p "$D/main/config" && echo 'canonical copy differs' > "$D/main/config/config.local.sh"
is "a DIFFERING ignored copy IS precious" "0" "$(ship_c "$D")"
is "  and is backed up" "config/config.local.sh" "$(bk | grep -x 'config/config.local.sh' || echo '')"

# An unmerged worktree is kept, and says why — never removed silently.
D="$TMP/u9"; rehearse "$D"
( cd "$D/main" && git worktree add -q "$D/wt2" -b feat/unmerged )
( cd "$D/wt2" && echo nope > nope.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm unmerged )
is "an unmerged foreign worktree is kept" "0" "$(ship_c "$D")"
is "  its directory survives" "0" "$([ -d "$D/wt2" ] && echo 0 || echo 1)"
is "  and its branch survives" "feat/unmerged" "$(branches "$D/main" | grep -x feat/unmerged || echo '')"
# NOT asserted here: the "kept, and says why" branch belongs to the SHIPPED worktree, and the ship
# loop has always merged it into the default branch by the time cleanup runs — so that message is a
# backstop for a state this harness cannot construct, not a covered path. The foreign-worktree
# assertions above are what the rehearsal can prove.

summary
