#!/usr/bin/env bash
# tests/test_ship_tag_gate.sh — tag_gate: the COMMITTED tree the tag lands on must carry the ship
# version on every declared surface.
#
# Why: 2026-11-28, free-agents v0.65.0 — the release rebase dropped the version-bump commit, every
# surface still AGREED (on 0.64.2), version_gate passed, and tag v0.65.0 landed on a commit reading
# 0.64.2: invisible to version-keyed installers until the tag was moved (broken-tag exception).
# The door reads the WORKTREE before the rebase; tag_gate reads `git show <ref>:<path>` AFTER the
# rebase and again on the ref about to be tagged, and compares every surface to the version being
# shipped — not just to each other.
#
# Cases: committed_ok, wrong_version_refused, bump_dropped_refused, changelog_regressed_refused,
#        version_file_positive_and_regressed, roadmap_positive_and_regressed,
#        extra_surface_positive_and_regressed, declared_absent_refused, full_ship_still_tags.
# Rig: tests/lib/rehearsal.sh (sourced; the same is/has/summary idiom as the sibling suites).
#
# Usage: bash tests/test_ship_tag_gate.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_ship_tag_gate.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/rehearsal.sh"

tg() {  # tg <dir> <ref> <version> — run the standalone --tag-gate mode against the rig worktree
  local d=$1
  ( cd "$d/wt" && "$ROOT/bin/rtc-ship.sh" --tag-gate "$d/wt" "$2" "$3" ) >"$d/tg-out" 2>&1
  echo $?
}

commit_in_wt() {  # commit_in_wt <dir> <msg>
  ( cd "$1/wt" && git add -A && git -c user.email=t@t -c user.name=t commit -qm "$2" )
}

with_full_surfaces() {  # with_full_surfaces <dir> — declare VERSION/ROADMAP/package.json, all at 0.2.0
  local d=$1
  ( cd "$d/wt" || exit 1
    cat > rtc-ship.json <<'JSON'
{
  "tag_prefix": "v",
  "default_branch": "main",
  "manifest": ".claude-plugin/plugin.json",
  "changelog": "CHANGELOG.md",
  "version_file": "VERSION",
  "roadmap": "docs/ROADMAP.md",
  "extra_version_surfaces": [{"path": "package.json", "kind": "json"}],
  "assets": "",
  "refresh_plugin": "rehearsal",
  "require_default_branch_checkout": false
}
JSON
    printf '0.2.0\n' > VERSION
    mkdir -p docs && printf '## Current released version\n\n`0.2.0`. See `CHANGELOG.md`.\n' > docs/ROADMAP.md
    printf '{\n  "name": "rehearsal",\n  "version": "0.2.0"\n}\n' > package.json
    git add -A && git -c user.email=t@t -c user.name=t commit -qm surfaces )
}

echo "== the committed branch carries the ship version: gate passes (and fails on a wrong arg) =="
A="$TMP/ok"; rehearse "$A"
is "committed 0.2.0 surfaces: tag-gate HEAD 0.2.0 exits 0" "0" "$(tg "$A" HEAD 0.2.0)"
has "  prints the surface table" "$(cat "$A/tg-out")" "tag_gate @ HEAD"
is "planted negative: same tree, wrong version 0.3.0 exits 1" "1" "$(tg "$A" HEAD 0.3.0)"
has "  names the mismatch" "$(cat "$A/tg-out")" "plugin.json says 0.2.0 at HEAD, shipping v0.3.0"

echo "== the R5 shape: the bump commit dropped (reset --hard), committed tree reads 0.1.0 =="
B="$TMP/dropped"; rehearse "$B"
git -C "$B/wt" reset -q --hard HEAD~1          # what a rebase that dropped the bump leaves behind
is "dropped bump: tag-gate HEAD 0.2.0 exits 1" "1" "$(tg "$B" HEAD 0.2.0)"
has "  names the manifest mismatch" "$(cat "$B/tg-out")" "plugin.json says 0.1.0"
has "  names the changelog mismatch" "$(cat "$B/tg-out")" "CHANGELOG.md top is 0.1.0"

echo "== only the changelog regressed: refused, naming the changelog =="
C="$TMP/cl"; rehearse "$C"
( cd "$C/wt" && printf '# Changelog\n\n## 0.1.0\n\nfirst\n' > CHANGELOG.md && commit_in_wt "$C" cl )
is "changelog-only regression: exits 1" "1" "$(tg "$C" HEAD 0.2.0)"
has "  names it" "$(cat "$C/tg-out")" "CHANGELOG.md top is 0.1.0 at HEAD, shipping v0.2.0"

echo "== version_file / roadmap / extra surface: agree -> pass; any one regressed -> refuse =="
D="$TMP/full"; rehearse "$D"; with_full_surfaces "$D"
is "all declared surfaces at 0.2.0: exits 0" "0" "$(tg "$D" HEAD 0.2.0)"
E="$TMP/vf"; rehearse "$E"; with_full_surfaces "$E"
( cd "$E/wt" && printf '0.1.0\n' > VERSION && commit_in_wt "$E" vf )
is "VERSION regressed: exits 1" "1" "$(tg "$E" HEAD 0.2.0)"
has "  names it" "$(cat "$E/tg-out")" "VERSION says 0.1.0 at HEAD, shipping v0.2.0"
F="$TMP/rm"; rehearse "$F"; with_full_surfaces "$F"
( cd "$F/wt" && printf '## Current released version\n\n`0.1.0`. See `CHANGELOG.md`.\n' > docs/ROADMAP.md && commit_in_wt "$F" rm )
is "roadmap regressed: exits 1" "1" "$(tg "$F" HEAD 0.2.0)"
has "  names it" "$(cat "$F/tg-out")" "docs/ROADMAP.md says 0.1.0 at HEAD, shipping v0.2.0"
G="$TMP/ex"; rehearse "$G"; with_full_surfaces "$G"
( cd "$G/wt" && printf '{\n  "name": "rehearsal",\n  "version": "0.1.0"\n}\n' > package.json && commit_in_wt "$G" ex )
is "extra surface regressed: exits 1" "1" "$(tg "$G" HEAD 0.2.0)"
has "  names it" "$(cat "$G/tg-out")" "package.json says 0.1.0 at HEAD, shipping v0.2.0"

echo "== a declared surface absent at the ref: failure, never a pass =="
H="$TMP/absent"; rehearse "$H"
( cd "$H/wt" && python3 - <<'PY'
import json
p = "rtc-ship.json"
c = json.load(open(p))
c["version_file"] = "NO-SUCH-FILE"
json.dump(c, open(p, "w"), indent=2)
PY
  commit_in_wt "$H" absent )
is "declared-but-absent surface: exits 1" "1" "$(tg "$H" HEAD 0.2.0)"
has "  names the absent file" "$(cat "$H/tg-out")" "NO-SUCH-FILE is declared but ABSENT at HEAD"

echo "== plain repo (manifest \"\") anchors on version_file — no crash, regression refused =="
J="$TMP/plain"; rehearse "$J"
( cd "$J/wt" && python3 - <<'PY'
import json
p = "rtc-ship.json"
c = json.load(open(p))
c["manifest"] = ""
c["version_file"] = "VERSION"
json.dump(c, open(p, "w"), indent=2)
PY
  printf '0.2.0\n' > VERSION
  commit_in_wt "$J" plain )
is "plain repo, VERSION 0.2.0: exits 0 (empty manifest key is not a surface)" "0" "$(tg "$J" HEAD 0.2.0)"
( cd "$J/wt" && printf '0.1.0\n' > VERSION && commit_in_wt "$J" regressed )
is "plain repo, VERSION regressed: exits 1" "1" "$(tg "$J" HEAD 0.2.0)"
has "  names it" "$(cat "$J/tg-out")" "VERSION says 0.1.0 at HEAD, shipping v0.2.0"

echo "== wiring: a healthy full ship still tags, and the gate ran at both call sites =="
I="$TMP/ship"; rehearse "$I"
rc=$(ship "$I" 0.2.0 'second')
is "healthy ship exits 0" "0" "$rc"
is "  origin got the v0.2.0 tag" "v0.2.0" "$(git -C "$I/origin.git" tag -l v0.2.0)"
n=$(grep -c 'tag_gate @' "$I/out")
is "  tag_gate ran at both call sites (post-rebase + pre-tag), saw $n" "2" "$n"

summary
