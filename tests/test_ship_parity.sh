#!/usr/bin/env bash
# tests/test_ship_parity.sh — fa-ship.sh parity: the features the port dropped, each RED before its fix.
#
# Part of the ship-loop rehearsal (the rig and its rationale: tests/lib/rehearsal.sh).
# Usage: bash tests/test_ship_parity.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

# ---------------------------------------------------------------------------------------------
# fa-ship.sh parity (2026-10-28). A call-site sweep of the script rtc-ship.sh replaced found
# features the port dropped while its header and CHANGELOG still claimed them. Each case below
# was RED before its fix.
# ---------------------------------------------------------------------------------------------

# p1 — the REBASE. fa-ship rebased the worktree onto origin/main before the gates; rtc-ship's header
# said so and had no `git rebase` call, so a branch behind main passed every gate and then died at
# `merge --ff-only`.
D="$TMP/p1"; rehearse "$D"
( cd "$D/main" && echo later > later.txt && git add later.txt \
    && git -c user.email=t@t -c user.name=t commit -qm 'main moved on' && git push -q origin main )
is "p1 a branch BEHIND the default branch is rebased and ships" "0" "$(ship "$D" 0.2.0 'second')"
is "  the shipped tag holds main's newer commit" "1" \
   "$(git -C "$D/main" log --oneline v0.2.0 2>/dev/null | grep -c 'main moved on')"
is "  and the bump" "1" "$(git -C "$D/main" log --oneline v0.2.0 2>/dev/null | grep -c 'bump')"

# p1b — a conflicting rebase stops the ship BEFORE anything irreversible, and leaves no half-rebase.
D="$TMP/p1b"; rehearse "$D"
( cd "$D/main" && printf '# Changelog\n\n## 0.1.1\n\nmain edit\n' > CHANGELOG.md && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm 'conflicting edit' && git push -q origin main )
rc=$(ship "$D" 0.2.0 'second')
is "p1b a conflicting rebase fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  and says it was the rebase" "$(cat "$D/out")" "rebase onto origin/main failed"
is "  before any gate ran" "0" "$(grep -c 'version surfaces\|plugin.json :' "$D/out")"
is "  and no tag was made" "" "$(git -C "$D/main" tag -l v0.2.0)"
is "  and the worktree is not left mid-rebase" "" \
   "$(cd "$D/wt" && [ -d "$(git rev-parse --git-path rebase-merge)" ] && echo mid-rebase || echo '')"

# p2 — the version ARGUMENT must match the tree. rtc checked the surfaces against EACH OTHER only;
# a typo'd version merged main locally and then died with no message.
D="$TMP/p2"; rehearse "$D"
rc=$(ship "$D" 0.3.0 'typo')
is "p2 a version argument the tree does not carry fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  naming the argument" "$(cat "$D/out")" "0.3.0"
has "  and what the tree says" "$(cat "$D/out")" "0.2.0"
is "  before main was touched" "0" "$(git -C "$D/main" log --oneline main | grep -c 'bump')"

# p2b — the CHANGELOG half of the door. A repo whose OWN version test ignores the changelog (the
# gate then defers to it) let a version with no entry through to the notes extraction, which died
# after the local merge. free-agents ships exactly this way: its own test_version_consistency.sh.
D="$TMP/p2b"; rehearse "$D"
( cd "$D/wt" && mkdir -p tests && printf '#!/usr/bin/env bash\nexit 0\n' > tests/test_version_consistency.sh \
    && chmod +x tests/test_version_consistency.sh \
    && printf '# Changelog\n\n## 0.1.0\n\nfirst\n' > CHANGELOG.md \
    && git add -A && git commit -qm 'own version test; changelog lacks 0.2.0' )
rc=$(ship "$D" 0.2.0 'second')
is "p2b a version with no CHANGELOG entry fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  saying the entry is missing" "$(cat "$D/out")" "has no entry for 0.2.0"
is "  before main was touched" "0" "$(git -C "$D/main" log --oneline main | grep -c 'own version test')"

# p3 — a failing phase is SHOWN, not discarded. fa-ship's run_logged (2026-10-26, after a packaging
# step "died silently") printed a verdict and the log's tail; rtc ran pre-package >/dev/null.
D="$TMP/p3"; rehearse "$D"; mkdir -p "$D/wt/.rtc"
printf '#!/usr/bin/env bash\necho "building the tarball: missing input foo.txt"\nexit 3\n' > "$D/wt/.rtc/pre-package.sh"
chmod +x "$D/wt/.rtc/pre-package.sh"
( cd "$D/wt" && git add -A && git commit -qm 'failing pre-package' )
rc=$(ship "$D" 0.2.0 'second')
is "p3 a failing pre-package fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  with its own words in the output" "$(cat "$D/out")" "missing input foo.txt"
has "  and an explicit verdict" "$(cat "$D/out")" "FAILED (exit 3)"

# p4 — the logs land where RTC_SHIP_LOG_DIR says (fa-ship: FA_SHIP_LOG_DIR), and a passing phase
# says so with a verdict too.
D="$TMP/p4b"; rehearse "$D"; mkdir -p "$D/wt/.rtc"
printf '#!/usr/bin/env bash\necho "built it"\n' > "$D/wt/.rtc/pre-package.sh"
chmod +x "$D/wt/.rtc/pre-package.sh"
( cd "$D/wt" && git add -A && git commit -qm 'passing pre-package' )
rc=$( ( cd "$D/wt" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 RTC_PLUGIN_CACHE="$D/cache" \
        RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION=0.2.0 \
        RTC_SHIP_LOG_DIR="$D/logs" "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' ) >"$D/out" 2>&1; echo $?)
is "p4b a ship with RTC_SHIP_LOG_DIR ships" "0" "$rc"
is "  and the pre-package log is kept there" "built it" "$(cat "$D/logs/pre-package.log" 2>/dev/null)"
has "  and the passing phase has a verdict" "$(cat "$D/out")" "✓ pre-package"

# p5 — a failing upload is shown too: gh reports API errors on stdout, which went to /dev/null.
D="$TMP/p5"; rehearse "$D"
rc=$( ( cd "$D/wt" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 RTC_PLUGIN_CACHE="$D/cache" \
        RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION=0.2.0 GH_FAIL_CREATE=1 RTC_SHIP_LOG_DIR="$D/logs" \
        "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' ) >"$D/out" 2>&1; echo $?)
is "p5 a failing gh release create fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  with gh's own error in the output" "$(cat "$D/out")" "HTTP 422"

# p6 — after publishing, ASK the release what it holds (fa-ship listed it); an uploaded asset the
# release does not hold fails the ship rather than reading as published.
set_assets() {  # set_assets <dir> <globs> — declare release assets in the worktree's config
  python3 - "$1/wt/rtc-ship.json" "$2" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["assets"] = sys.argv[2]
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
  ( cd "$1/wt" && git add -A && git commit -qm 'declare assets' )
}
D="$TMP/p6"; rehearse "$D"; set_assets "$D" "dist/*.tar.gz"
is "p6 a ship with an asset ships" "0" "$(ship "$D" 0.2.0 'second')"
has "  and lists what the release holds" "$(cat "$D/out")" "asset: rehearsal-0.2.0.tar.gz"
D="$TMP/p6b"; rehearse "$D"; set_assets "$D" "dist/*.tar.gz"
rc=$( ( cd "$D/wt" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 RTC_PLUGIN_CACHE="$D/cache" \
        RTC_BACKUP_DIR="$TMP/bk" RTC_TAG_VISIBILITY_DELAY=0 PUBLISHED_VERSION=0.2.0 \
        GH_VIEW_DROP=rehearsal-0.2.0.tar.gz RTC_SHIP_LOG_DIR="$D/logs" "$ROOT/bin/rtc-ship.sh" "$D/wt" 0.2.0 'second' ) >"$D/out" 2>&1; echo $?)
is "p6b an asset missing from the published release fails the ship" "1" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
has "  naming the missing asset" "$(cat "$D/out")" "rehearsal-0.2.0.tar.gz"

# p7 — a FAILED backup keeps the worktree. cleanup runs as `cleanup || …`, which switches set -e off
# for its whole body, so a failed mkdir/cp printed "backed up" and went on to `worktree remove --force`.
D="$TMP/p7"; rehearse "$D"
( cd "$D/wt" && mkdir -p sub && echo 'the only copy' > sub/ledger.md && printf 'sub/\n' >> .gitignore \
    && git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm 'ignore sub' )
printf 'blocker\n' > "$TMP/not-a-dir"
rc=$(ship_c "$D" RTC_BACKUP_DIR="$TMP/not-a-dir/bk")
is "p7 a ship whose backup cannot be written still ships (the release outranks the tidy)" "0" "$rc"
is "  but the worktree is KEPT" "0" "$([ -d "$D/wt" ] && echo 0 || echo 1)"
is "  with its only copy intact" "the only copy" "$(cat "$D/wt/sub/ledger.md" 2>/dev/null)"
has "  and the kept worktree is announced" "$(cat "$D/out")" "backup failed"


summary
