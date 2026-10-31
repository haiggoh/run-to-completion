#!/usr/bin/env bash
# tests/test_ship_any_checkout.sh — the canonical checkout's state never blocks or gets touched by a
# ship, unless the repo opts in to the strict rule, which the loop recommends until a choice is made.
#
# Part of the ship-loop rehearsal (the rig and its rationale: tests/lib/rehearsal.sh).
# Usage: bash tests/test_ship_any_checkout.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

set_strict() {  # set_strict <dir> <json-value> — commit the key into the branch being shipped
  ( cd "$1/wt" && python3 - "$2" <<'PY'
import json, sys
d = json.load(open("rtc-ship.json")); d["require_default_branch_checkout"] = json.loads(sys.argv[1])
open("rtc-ship.json", "w").write(json.dumps(d, indent=2) + "\n")
PY
    git add rtc-ship.json && git -c user.email=t@t -c user.name=t commit -qm strict )
}
busy_canonical() {  # busy_canonical <dir> — canonical checkout on another branch, mid-edit
  ( cd "$1/main" && git checkout -q -b feature-x && echo "work in progress" >> CHANGELOG.md )
  cp "$1/main/CHANGELOG.md" "$1/canonical-edit.copy"
}

# (a) key ABSENT, canonical busy: ships around it via refs, touches nothing, and nudges
D="$TMP/a"; rehearse "$D"; busy_canonical "$D"
tip=$(git -C "$D/wt" rev-parse HEAD)
is "a busy canonical checkout does not block the ship" "0" "$(ship "$D" 0.2.0 'second')"
is "  the canonical checkout is still on its own branch" "feature-x" "$(git -C "$D/main" branch --show-current)"
is "  and its uncommitted edit is byte-identical" "0" "$(cmp -s "$D/main/CHANGELOG.md" "$D/canonical-edit.copy"; echo $?)"
is "  origin's default branch is the shipped tip" "$tip" "$(git -C "$D/origin.git" rev-parse main)"
is "  the tag points at the shipped tip" "$tip" "$(git -C "$D/origin.git" rev-parse 'v0.2.0^{commit}')"
has "  the release notes come from the SHIPPED changelog" "$(grep '^NOTES-BODY:' "$D/calls")" "second"
is "  not from the canonical checkout's edit" "0" "$(grep -c 'work in progress' "$D/calls")"
has "  and the loop recommends the strict rule" "$(cat "$D/out")" '"require_default_branch_checkout": true'
# On this route the default branch is checked out NOWHERE, so the cleanup sweep's $DEFAULT_BRANCH
# skips are the only thing between it and `git branch -d main` / `git push origin --delete main`
# (before 1.0.0 the ship required main checked out, and those skips were unreachable).
is "  the cleanup sweep keeps the local default branch" "main" "$(branches "$D/main" | grep -x main || echo '')"
is "  and never deletes the default branch on origin" "$tip" "$(git -C "$D/origin.git" rev-parse --verify -q main || echo gone)"
is "  the local default branch is brought up to the shipped tip" "$tip" "$(git -C "$D/main" rev-parse main)"
# `git branch -d` judges "merged" against the upstream, else the CURRENT HEAD — here feature-x — so it
# refused the shipped branch (and would have masked the default-branch skip above). Cleanup decides
# mergedness itself against origin, then deletes; the shipped branch must be gone.
is "  the shipped branch is reaped even though HEAD is another branch" "" "$(branches "$D/main" | grep -x feat/ship || echo '')"
is "  and the canonical checkout's own branch is kept" "feature-x" "$(branches "$D/main" | grep -x feature-x || echo '')"

# (b) strict TRUE, canonical busy: refused before anything is published
D="$TMP/b"; rehearse "$D"; set_strict "$D" true; busy_canonical "$D"
before=$(git -C "$D/origin.git" rev-parse main)
is "strict + a busy canonical checkout REFUSES the ship" "1" "$(ship "$D" 0.2.0 'second')"
has "  naming the setting" "$(cat "$D/out")" "require_default_branch_checkout"
is "  origin's default branch did not move" "$before" "$(git -C "$D/origin.git" rev-parse main)"
is "  and no tag was published" "" "$(git -C "$D/origin.git" tag -l v0.2.0)"

# (c) strict TRUE, canonical clean on default: ships the classic way, fast-forwarding the checkout
D="$TMP/c"; rehearse "$D"; set_strict "$D" true
tip=$(git -C "$D/wt" rev-parse HEAD)
is "strict + a clean canonical checkout on main ships" "0" "$(ship "$D" 0.2.0 'second')"
is "  and the checkout itself is fast-forwarded" "$tip" "$(git -C "$D/main" rev-parse HEAD)"
is "  no recommendation once the choice is made" "0" "$(grep -c 'require_default_branch_checkout' "$D/out")"

# (d) explicit FALSE: permissive, and silent about it
D="$TMP/d"; rehearse "$D"; set_strict "$D" false; busy_canonical "$D"
is "explicit false + a busy canonical checkout ships" "0" "$(ship "$D" 0.2.0 'second')"
is "  without the recommendation" "0" "$(grep -c 'require_default_branch_checkout' "$D/out")"

# (e) an invalid value fails at the door, before anything irreversible
D="$TMP/e"; rehearse "$D"; set_strict "$D" '"yes"'
before=$(git -C "$D/origin.git" rev-parse main)
is "a non-boolean require_default_branch_checkout fails the ship at the door" "2" "$(ship "$D" 0.2.0 'second')"
is "  origin untouched" "$before" "$(git -C "$D/origin.git" rev-parse main)"

# (f) origin's default branch moves AFTER the rebase (pre-flight pushes to it): the ref path must
# refuse rather than overwrite it — a push that is not a fast-forward is never forced
D="$TMP/f"; rehearse "$D"; busy_canonical "$D"
# -b main: the bare origin's HEAD names a nonexistent branch, so a plain clone checks out NOTHING and
# "late" becomes an unrelated root commit whose push fails — the ship then stops on the failing hook,
# not on the guard under test (found 2026-10-31 when this case first went "green" for that reason).
git clone -q -b main "$D/origin.git" "$D/other" && ( cd "$D/other" && echo late > late.txt && git add late.txt \
  && git -c user.email=t@t -c user.name=t commit -qm late )
mkdir -p "$D/wt/.rtc"
printf '#!/usr/bin/env bash\ngit -C "%s" push -q origin HEAD:main\n' "$D/other" > "$D/wt/.rtc/pre-flight.sh"
chmod +x "$D/wt/.rtc/pre-flight.sh"
( cd "$D/wt" && git add .rtc && git -c user.email=t@t -c user.name=t commit -qm racing-preflight )
late=$(git -C "$D/other" rev-parse HEAD)
is "origin moving after the rebase REFUSES the ship" "1" "$(ship "$D" 0.2.0 'second')"
is "  the concurrent commit survives on origin" "$late" "$(git -C "$D/origin.git" rev-parse main)"
has "  and the refusal came from the ancestry guard, not a failing hook" "$(cat "$D/out")" "has moved since the rebase"
is "  and no tag was published" "" "$(git -C "$D/origin.git" tag -l v0.2.0)"

summary
