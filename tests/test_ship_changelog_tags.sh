#!/usr/bin/env bash
# tests/test_ship_changelog_tags.sh — the ship refuses a CHANGELOG that has LOST or DUPLICATED a
# released entry, and warns (without blocking) about older tags that never had one.
#
# Why: a version bump can rename the TOP entry in place, so the entry of the release just
# published disappears while every "top heading == manifest" check stays green (motion-pipeline
# v0.7.1 renamed the 0.7.0 entry, 2026-11-22; waypoints carried two [0.20.1] and two [0.20.0]
# headings, 2026-11-25). The door now pins, against the repo's published tags:
#   HARD  the version being shipped has exactly ONE entry
#   HARD  the newest published tag older than it has exactly ONE entry (the rename-in-place case)
#   WARN  every older published tag without an entry, and any other duplicated heading
#
# Cases: renamed_previous_refused, duplicate_new_refused, duplicate_previous_refused,
# older_gap_warns_and_ships, fenced_example_ships, fenced_old_heading_no_warn,
# real_duplicate_after_fence_refused, healthy_changelog_ships_silently.
# Rig: tests/lib/rehearsal.sh (sourced; the same is/has/summary idiom as the sibling suites).
#
# Usage: bash tests/test_ship_changelog_tags.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_ship_changelog_tags.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/rehearsal.sh"

# with_changelog <dir> <printf-format> — commit a crafted CHANGELOG into the rig's worktree
with_changelog() {
  ( cd "$1/wt" && printf '%b' "$2" > CHANGELOG.md && git add CHANGELOG.md \
      && git -c user.email=t@t -c user.name=t commit -qm "changelog fixture" )
}
# tag_origin <dir> <tag>... — publish tags on the rig's origin (on its main, like a real release)
tag_origin() { local d=$1; shift; for t in "$@"; do git -C "$d/origin.git" tag "$t" main; done; }

echo "== the previous release's entry was renamed in place: refused at the door =="
A="$TMP/cl-renamed"; rehearse "$A"; tag_origin "$A" v0.1.0
with_changelog "$A" '# Changelog\n\n## 0.2.0\n\nsecond (the 0.1.0 entry was renamed into this one)\n'
rc=$(ship "$A" 0.2.0 'renamed')
is "renamed previous entry: ship exits 1" "1" "$rc"
has "  stderr names the lost release" "$(cat "$A/out")" "no entry for the published release v0.1.0"
is "  origin got NO v0.2.0 tag" "" "$(git -C "$A/origin.git" tag -l v0.2.0)"

echo "== the version being shipped appears twice: refused =="
B="$TMP/cl-dupnew"; rehearse "$B"; tag_origin "$B" v0.1.0
with_changelog "$B" '# Changelog\n\n## 0.2.0\n\nsecond\n\n## 0.2.0\n\nstub\n\n## 0.1.0\n\nfirst\n'
rc=$(ship "$B" 0.2.0 'dup new')
is "duplicated 0.2.0 heading: ship exits 1" "1" "$rc"
has "  stderr says it appears more than once" "$(cat "$B/out")" "has 2 entries for 0.2.0"
is "  origin got NO v0.2.0 tag" "" "$(git -C "$B/origin.git" tag -l v0.2.0)"

echo "== the previous release appears twice: refused =="
C="$TMP/cl-dupprev"; rehearse "$C"; tag_origin "$C" v0.1.0
with_changelog "$C" '# Changelog\n\n## 0.2.0\n\nsecond\n\n## 0.1.0\n\nstub\n\n## 0.1.0\n\nfirst\n'
rc=$(ship "$C" 0.2.0 'dup prev')
is "duplicated previous heading: ship exits 1" "1" "$rc"
has "  stderr says it appears more than once" "$(cat "$C/out")" "has 2 entries for 0.1.0"

echo "== an OLDER tag without an entry warns but does not block =="
W="$TMP/cl-oldgap"; rehearse "$W"; tag_origin "$W" v0.0.9 v0.1.0
with_changelog "$W" '# Changelog\n\n## 0.2.0\n\nsecond\n\n## 0.1.0\n\nfirst\n'
rc=$(ship "$W" 0.2.0 'old gap')
is "older gap: ship still exits 0" "0" "$rc"
has "  the warning names the old tag" "$(cat "$W/out")" "⚠ CHANGELOG.md has no entry for older published tag(s): v0.0.9"
is "  and the release really happened" "v0.2.0" "$(git -C "$W/origin.git" tag -l v0.2.0)"

echo "== a fenced EXAMPLE of the shipped/previous heading is not an entry: ships =="
# A CHANGELOG documenting the heading format inside a code fence (``` or ~~~) must not count those
# lines as entries — before the fix this was a false HARD ("has 2 entries for 0.2.0"). The ````
# line inside the ~~~ fence is LONGER than the opener, so only the same-char rule keeps it open;
# the heading after it is the SHIPPED version, so a wrong close always yields 2 entries for 0.2.0
# (leaking 0.1.0 instead was masked: the stray ~~~ then reopened and hid the real 0.1.0 entry).
F="$TMP/cl-fenced"; rehearse "$F"; tag_origin "$F" v0.1.0
with_changelog "$F" '# Changelog\n\n## 0.2.0\n\nheadings look like:\n\n```markdown\n## 0.2.0\n## [0.1.0] — 2026-01-01\n```\n\n~~~\n````\n## 0.2.0\n~~~\n\n## 0.1.0\n\nfirst\n'
rc=$(ship "$F" 0.2.0 'fenced')
is "fenced example headings: ship exits 0" "0" "$rc"
is "  no duplicate-entry refusal" "0" "$(grep -c 'entries for' "$F/out")"
is "  tag created" "v0.2.0" "$(git -C "$F/origin.git" tag -l v0.2.0)"

echo "== a fenced copy of an OLD heading does not warn as a repeat =="
G="$TMP/cl-fenced-old"; rehearse "$G"; tag_origin "$G" v0.0.9 v0.1.0
with_changelog "$G" '# Changelog\n\n## 0.2.0\n\nsecond\n\n   ```\n## 0.0.9\n   ```\n\n## 0.1.0\n\nfirst\n\n## 0.0.9\n\nzeroth\n'
rc=$(ship "$G" 0.2.0 'fenced old')
is "fenced old heading: ship exits 0" "0" "$rc"
is "  no repeated-heading warning" "0" "$(grep -c 'repeats heading' "$G/out")"

echo "== a REAL duplicate after a closed fence is still refused (the fence must close) =="
K="$TMP/cl-fence-closed"; rehearse "$K"; tag_origin "$K" v0.1.0
with_changelog "$K" '# Changelog\n\n## 0.2.0\n\n```\nexample\n```\n\n## 0.2.0\n\nstub\n\n## 0.1.0\n\nfirst\n'
rc=$(ship "$K" 0.2.0 'fence closed')
is "duplicate after a closed fence: ship exits 1" "1" "$rc"
has "  stderr says it appears more than once" "$(cat "$K/out")" "has 2 entries for 0.2.0"

echo "== a healthy CHANGELOG ships with no warning (positive control) =="
H="$TMP/cl-healthy"; rehearse "$H"; tag_origin "$H" v0.1.0
rc=$(ship "$H" 0.2.0 'healthy')
is "healthy changelog: ship exits 0" "0" "$rc"
is "  no CHANGELOG-tag warning printed" "0" "$(grep -c 'older published tag' "$H/out")"
is "  tag created" "v0.2.0" "$(git -C "$H/origin.git" tag -l v0.2.0)"

summary
