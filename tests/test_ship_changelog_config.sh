#!/usr/bin/env bash
# tests/test_ship_changelog_config.sh — release notes follow rtc-ship.json's "changelog" key.
# (2026-10-25 review, confirmed 2026-10-31: the notes were read from a hardcoded CHANGELOG.md while the
# gate honoured the key — a CHANGES.md repo silently got generated notes — and the no-changelog path,
# which falls back to `gh --generate-notes`, had no test at all.)
#
# Part of the ship-loop rehearsal (the rig and its rationale: tests/lib/rehearsal.sh).
# Usage: bash tests/test_ship_changelog_config.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

set_changelog() {  # set_changelog <dir> <key-value> [rename-to] — commit the key (and a rename) in the branch
  ( cd "$1/wt" && python3 - "$2" <<'PY'
import json, sys
d = json.load(open("rtc-ship.json")); d["changelog"] = sys.argv[1]
open("rtc-ship.json", "w").write(json.dumps(d, indent=2) + "\n")
PY
    if [ -n "${3:-}" ]; then git mv CHANGELOG.md "$3"; fi
    if [ -z "$2" ] && [ -z "${3:-}" ]; then git rm -q CHANGELOG.md; fi
    git add -A && git -c user.email=t@t -c user.name=t commit -qm changelog-config )
}

D="$TMP/c1"; rehearse "$D"; set_changelog "$D" "CHANGES.md" "CHANGES.md"
is "a repo whose changelog is CHANGES.md ships" "0" "$(ship "$D" 0.2.0 'second')"
has "  with notes from CHANGES.md" "$(grep '^NOTES-BODY:' "$D/calls")" "second"
is "  not generated ones" "0" "$(grep -c -- '--generate-notes' "$D/calls")"

D="$TMP/c2"; rehearse "$D"; set_changelog "$D" ""
is "a repo with no changelog declared ships" "0" "$(ship "$D" 0.2.0 'second')"
is "  with GitHub-generated notes" "1" "$(grep -c -- '--generate-notes' "$D/calls")"
has "  and the gate says the changelog was not checked" "$(cat "$D/out")" "no changelog declared"

summary
