#!/usr/bin/env bash
# tests/test_ship_rehearsal.sh — the ship loop's MERGE→TAG→PUSH→RELEASE→REFRESH path, rehearsed.
#
# The other ship test (test_rtc_ship.sh) covers --help and the version gate. That leaves the half of
# the loop that does the irreversible work — merge, tag, push, publish, refresh — with NO coverage,
# which is precisely where a silently skipped step is unrecoverable. This rehearses it end to end
# against a scratch repo with a LOCAL origin and a stubbed `gh`, so the real steps run without
# publishing anything.
#
#
# Split 2026-10-28 into files that run in parallel: this one (merge/tag/release/assets),
# test_ship_refresh.sh, test_ship_cleanup.sh, test_ship_cleanup_rescue.sh,
# test_ship_cleanup_optouts.sh and test_ship_parity.sh. The rig is tests/lib/rehearsal.sh.
#
# Usage: bash tests/test_ship_rehearsal.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

D="$TMP/r1"; rehearse "$D"
is "a clean rehearsal ships (exit 0)" "0" "$(ship "$D" 0.2.0 'second')"
is "the branch was fast-forward MERGED into the default branch" \
   "1" "$(git -C "$D/main" log --oneline main | grep -c 'bump')"
is "an annotated tag was created" "v0.2.0" "$(git -C "$D/main" tag -l v0.2.0)"
is "and PUSHED to the origin" "v0.2.0" "$(git -C "$D/origin.git" tag -l v0.2.0)"
CALLS=$(cat "$D/calls" 2>/dev/null)
has "gh release create was called with the tag" "$CALLS" "gh release create v0.2.0"
has "the release title carries the summary" "$CALLS" "0.2.0 — second"
has "the release notes came from the CHANGELOG entry" "$CALLS" "NOTES-BODY: second"
has "the installed plugin was refreshed" "$CALLS" "get-haiggoh apply --only rehearsal"
has "the loop reports the release as live" "$(cat "$D/out")" "is live"

# A repo hook must be able to FAIL the ship. post-release is where a Homebrew trigger or an
# installed-copy check lives; warning and continuing means a release whose refresh never landed
# still prints "done — v1.2.3 is live".
D="$TMP/r2"; rehearse "$D"
mkdir -p "$D/wt/.rtc"
printf '#!/usr/bin/env bash\necho "installed copy is 9.9.9, not 0.2.0" >&2\nexit 1\n' > "$D/wt/.rtc/post-release.sh"
chmod +x "$D/wt/.rtc/post-release.sh"
# COMMIT it: an untracked hook makes the worktree dirty, and the ship correctly refuses a dirty
# tree — which would make this test pass for the wrong reason.
( cd "$D/wt" && git add -A && git commit -qm 'add post-release hook' )
rc=$(ship "$D" 0.2.0 'second')
is "a FAILING post-release hook fails the ship" "1" "$rc"
has "and says which hook failed" "$(cat "$D/out")" "post-release"
is "and does not claim the release is live" "0" "$(grep -c 'is live' "$D/out")"

# An asset glob that matches NOTHING must not publish a release missing it. `compgen -G` exits
# non-zero on no match and `|| true` swallowed it, so the loop reported success having dropped the
# asset — a release nobody can install, looking exactly like a successful one.
D="$TMP/r3"; rehearse "$D"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["assets"] = "dist/rehearsal-0.2.0.tar.gz dist/does-not-exist-*.tar.gz"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
( cd "$D/wt" && git add -A && git commit -qm 'declare assets' )
rc=$(ship "$D" 0.2.0 'second')
is "an asset glob matching nothing FAILS the ship" "1" "$rc"
has "and names the glob that matched nothing" "$(cat "$D/out")" "does-not-exist"
is "and the release was NOT published" "0" "$(grep -c 'release published' "$D/out")"

# The happy path WITH assets: the release is created carrying them, and the count is reported.
D="$TMP/r4"; rehearse "$D"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["assets"] = "dist/rehearsal-*.tar.gz"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
( cd "$D/wt" && git add -A && git commit -qm 'declare assets' )
is "declared assets ship" "0" "$(ship "$D" 0.2.0 'second')"
has "and the asset is handed to gh release create" "$(cat "$D/calls")" "dist/rehearsal-0.2.0.tar.gz"
has "and the count is reported" "$(cat "$D/out")" "1 asset"

# A STALE build in the canonical checkout must neither break nor leak into the release. Measured
# 2026-10-26 (free-agents 0.46.2): the loop runs the asset step after `cd "$MAIN"`, and an
# unquoted `for g in $(cfg_get assets)` pathname-expanded `dist/free-agents-*.tar.gz` THERE — into
# the previous release's leftover `dist/free-agents-0.46.1.tar.gz` — so compgen in the worktree
# matched nothing and the release failed after the tag was pushed. The relative paths it hands gh
# would have uploaded MAIN's stale files even with the glob fixed, so the paths must be absolute.
D="$TMP/r4b"; rehearse "$D"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["assets"] = "dist/rehearsal-*.tar.gz"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
( cd "$D/wt" && git add -A && git commit -qm 'declare assets' )
mkdir -p "$D/main/dist" && echo stale > "$D/main/dist/rehearsal-0.1.0.tar.gz"   # untracked leftover
is "a stale build in the canonical checkout does not fail the ship" "0" "$(ship "$D" 0.2.0 'second')"
has "gh gets the WORKTREE's asset by absolute path" "$(cat "$D/calls")" "$D/wt/dist/rehearsal-0.2.0.tar.gz"
is "and never the canonical checkout's stale build" "0" "$(grep -c 'rehearsal-0.1.0' "$D/calls")"

# obs 0057: a pre-package phase whose output nobody asserts. The scratch pre-package here is a
# silent no-op — it runs green and builds nothing — and the worktree's dist/ still holds the
# PREVIOUS release's tarball, which satisfies the glob. The ship must FAIL naming the stale
# asset instead of publishing it (measured on free-agents 0.45.2/0.45.3, which glob-matched
# dist/free-agents-0.44.1.tar.gz while packaging had built nothing current).
D="$TMP/r4c"; rehearse "$D"
python3 - "$D/wt/rtc-ship.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["assets"] = "dist/rehearsal-*.tar.gz"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
mkdir -p "$D/wt/.rtc"
mv "$D/wt/dist/rehearsal-0.2.0.tar.gz" "$D/wt/dist/rehearsal-0.1.0.tar.gz"
printf '#!/usr/bin/env bash\n# the silent no-op: runs green, builds nothing\nexit 0\n' > "$D/wt/.rtc/pre-package.sh"
chmod +x "$D/wt/.rtc/pre-package.sh"
( cd "$D/wt" && git add -A && git commit -qm 'stale dist asset, no-op pre-package' )
rc=$(ship "$D" 0.2.0 'second')
is "a stale version-bearing asset FAILS the ship" "1" "$rc"
has "and names the stale asset" "$(cat "$D/out")" "rehearsal-0.1.0"
is "and the release was NOT published" "0" "$(grep -c 'release published' "$D/out")"

# The SHIP path's gate exit code, pinned end to end. With the suite gates ENABLED (the rig's
# RTC_SKIP_TESTS=1 overridden to 0 — env's last assignment wins) and no tests present, the gate
# must fail the ship non-zero BEFORE anything is merged, tagged or published. The 2026-10-28
# free-agents 0.47.0 attempt printed '✖ tests failed' and still exited 0.
D="$TMP/r5"; rehearse "$D"
rc=$(ship_c "$D" RTC_SKIP_TESTS=0)
is "a red/empty suite fails the SHIP path" "1" "$rc"
has "and says the suite failed" "$(cat "$D/out")" "FAILED"
is "and nothing was merged into the default branch" "0" "$(git -C "$D/main" log --oneline main | grep -c 'bump')"
is "and no tag was pushed" "" "$(git -C "$D/origin.git" tag -l v0.2.0)"

summary
