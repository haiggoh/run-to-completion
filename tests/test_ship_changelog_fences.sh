#!/usr/bin/env bash
# tests/test_ship_changelog_fences.sh — every CHANGELOG scan in the ship ignores headings inside
# fenced code blocks (``` / ~~~), and the door reads an entry's body from the line AFTER its heading.
#
# Why: the door's "has an entry" grep, its placeholder check, and the release-notes extraction each
# matched `## x.y.z` anywhere, so a fenced EXAMPLE heading could stand in for a missing entry
# (false PASS), be published as the release body, or truncate the real entry mid-section. The door's
# placeholder check also started the body mid-heading-line, so a dated `## [x] — date` placeholder
# (the form --bump-versions writes) slipped past it and was only caught at tag time, after the gates.
# All three now go through bin/rtc_changelog.py (one fence-aware scanner).
#
# Cases: fenced_heading_is_not_an_entry, dated_placeholder_refused_at_door,
# notes_skip_fenced_example, notes_not_truncated_by_fenced_heading, gate_top_entry_unfenced,
# bump_same_version_fenced, bump_style_source_unfenced, helper_cli_contract.
# Rig: tests/lib/rehearsal.sh (sourced; the same is/has/summary idiom as the sibling suites).
#
# Usage: bash tests/test_ship_changelog_fences.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_ship_changelog_fences.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/rehearsal.sh"

with_changelog() {
  ( cd "$1/wt" && printf '%b' "$2" > CHANGELOG.md && git add CHANGELOG.md \
      && git -c user.email=t@t -c user.name=t commit -qm "changelog fixture" )
}
tag_origin() { local d=$1; shift; for t in "$@"; do git -C "$d/origin.git" tag "$t" main; done; }
notes_of() { git -C "$1/origin.git" tag -l --format='%(contents)' "$2"; }

echo "== a fenced example heading does not count as the missing entry: refused =="
A="$TMP/fx-noentry"; rehearse "$A"; tag_origin "$A" v0.1.0
with_changelog "$A" '# Changelog\n\n## 0.1.0\n\nformat:\n\n```\n## 0.2.0\n```\n'
rc=$(ship "$A" 0.2.0 'no entry')
is "fenced-only 0.2.0: ship exits 1" "1" "$rc"
has "  the door names the missing entry" "$(cat "$A/out")" "has no entry for 0.2.0"
is "  origin got NO v0.2.0 tag" "" "$(git -C "$A/origin.git" tag -l v0.2.0)"

echo "== a DATED placeholder heading is refused at the door, before any gate =="
B="$TMP/fx-dated"; rehearse "$B"; tag_origin "$B" v0.1.0
with_changelog "$B" '# Changelog\n\n## [0.2.0] — 2026-11-27\n\n- (release notes go here)\n\n## [0.1.0]\n\nfirst\n'
rc=$(ship "$B" 0.2.0 'dated')
is "dated placeholder: ship exits 1" "1" "$rc"
has "  refused by the DOOR's placeholder check" "$(cat "$B/out")" "section is still the placeholder"
is "  origin got NO v0.2.0 tag" "" "$(git -C "$B/origin.git" tag -l v0.2.0)"

echo "== release notes come from the real entry, not a fenced example above it =="
C="$TMP/fx-notes"; rehearse "$C"; tag_origin "$C" v0.1.0
with_changelog "$C" '# Changelog\n\nentries look like:\n\n```\n## 0.2.0\nFAKE-EXAMPLE\n```\n\n## 0.2.0\n\nREAL-NOTES\n\n## 0.1.0\n\nfirst\n'
rc=$(ship "$C" 0.2.0 'notes')
is "fenced example above entry: ship exits 0" "0" "$rc"
has "  tag notes carry the real entry" "$(notes_of "$C" v0.2.0)" "REAL-NOTES"
is "  and not the fenced example" "0" "$(notes_of "$C" v0.2.0 | grep -c FAKE-EXAMPLE)"

echo "== a fenced heading INSIDE the entry does not truncate its notes =="
D="$TMP/fx-trunc"; rehearse "$D"; tag_origin "$D" v0.1.0
with_changelog "$D" '# Changelog\n\n## 0.2.0\n\nBEFORE-FENCE\n\n### Fixed\n\nSUB-SECTION\n\n~~~markdown\n## 0.1.9\n~~~\n\nAFTER-FENCE\n\n## 0.1.0\n\nfirst\n'
rc=$(ship "$D" 0.2.0 'trunc')
is "fenced heading in entry: ship exits 0" "0" "$rc"
has "  notes keep a ### sub-section (only ## ends an entry)" "$(notes_of "$D" v0.2.0)" "SUB-SECTION"
has "  notes keep the text after the fence" "$(notes_of "$D" v0.2.0)" "AFTER-FENCE"
is "  and stop at the next entry" "0" "$(notes_of "$D" v0.2.0 | grep -c '^first$')"

echo "== the version gate's top entry is the first UNFENCED heading =="
E="$TMP/fx-gate"; rehearse "$E"; tag_origin "$E" v0.1.0
with_changelog "$E" '# Changelog\n\nformat:\n\n```\n## 9.9.9\n```\n\n## 0.2.0\n\nsecond\n\n## 0.1.0\n\nfirst\n'
rc=$(ship "$E" 0.2.0 'gate')
is "fenced 9.9.9 above the top entry: ship exits 0" "0" "$rc"
is "  no surfaces-disagree refusal" "0" "$(grep -c 'version surfaces disagree' "$E/out")"

# bump_in <dir> <version> <title> — run --bump-versions on the rig's worktree, output to <dir>/bump
bump_in() { ( cd "$1/wt" && "$ROOT/bin/rtc-ship.sh" --bump-versions "$1/wt" "$2" "$3" ) >"$1/bump" 2>&1; echo $?; }
CL="$ROOT/bin/rtc_changelog.py"

echo "== --bump-versions: a fenced heading of the SAME version is not an existing entry =="
F="$TMP/fx-bump-same"; rehearse "$F"
with_changelog "$F" '# Changelog\n\n```\n## [0.2.0] — 2020-01-01\n```\n\n## [0.1.0] — 2020-01-01\n\nfirst\n'
is "bump exits 0" "0" "$(bump_in "$F" 0.2.0 'BUMP-TITLE')"
has "  a new entry was written" "$(cat "$F/bump")" "new top entry"
is "  the real 0.2.0 entry carries the title" "- BUMP-TITLE" "$(python3 "$CL" section "$F/wt/CHANGELOG.md" 0.2.0 | tr -d '\n')"

echo "== --bump-versions: the style source and insertion point are the first UNFENCED heading =="
G="$TMP/fx-bump-style"; rehearse "$G"
with_changelog "$G" '# Changelog\n\n```\n## [9.9.9] — 2020-01-01\n```\n\n## 0.1.0\n\nfirst\n'
is "bump exits 0" "0" "$(bump_in "$G" 0.2.0 'G-TITLE')"
is "  the entry is readable (not inserted inside the fence)" "- G-TITLE" "$(python3 "$CL" section "$G/wt/CHANGELOG.md" 0.2.0 | tr -d '\n')"
is "  heading style copied from the real entry (unbracketed, undated)" "1" "$(grep -c '^## 0\.2\.0$' "$G/wt/CHANGELOG.md")"
is "  the fenced example is untouched" "1" "$(grep -c '^## \[9\.9\.9\] — 2020-01-01$' "$G/wt/CHANGELOG.md")"

echo "== this repo's own tests/test_version_consistency.sh reads the first UNFENCED heading =="
V="$TMP/fx-vc"; mkdir -p "$V/.claude-plugin"
printf '{"name":"x","version":"1.0.0"}\n' > "$V/.claude-plugin/plugin.json"
printf '# Changelog\n\n```\n## 9.9.9\n```\n\n## [1.0.0] — 2026-01-01\n\nfirst\n' > "$V/CHANGELOG.md"
bash "$ROOT/tests/test_version_consistency.sh" "$V" >"$V/out" 2>&1; is "fenced 9.9.9 above 1.0.0: consistent" "0" "$?"
printf '# Changelog\n\n## 9.9.9\n\n## [1.0.0]\n' > "$V/CHANGELOG.md"
bash "$ROOT/tests/test_version_consistency.sh" "$V" >"$V/out" 2>&1; is "  an UNFENCED 9.9.9 on top still fails" "1" "$?"

echo "== bin/rtc_changelog.py CLI contract =="
f="$TMP/cl.md"; printf '## [1.0.0] — 2026-01-01\n\nbody\n\n## 0.9.0\n\nold\n' > "$f"
g="$TMP/cl-fenced.md"; printf '# C\n\n~~~\n## 7.7.7\n~~~\n\n## [1.0.0]\n' > "$g"
is "top prints the first unfenced entry version" "1.0.0" "$(python3 "$CL" top "$g")"
printf '```\n## 7.7.7\n```\n' > "$TMP/cl-only.md"
python3 "$CL" top "$TMP/cl-only.md" >/dev/null 2>&1; is "top with only fenced headings exits 3" "3" "$?"
is "section prints the body from the line after the heading" "body" "$(python3 "$CL" section "$f" 1.0.0 | tr -d '\n')"
python3 "$CL" section "$f" 2.0.0 >/dev/null 2>&1; is "no entry exits 3" "3" "$?"
python3 "$CL" bogus >/dev/null 2>&1; is "unknown subcommand exits 2" "2" "$?"
python3 "$CL" --help >/dev/null 2>&1; is "--help exits 0" "0" "$?"

summary
