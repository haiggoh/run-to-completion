#!/usr/bin/env bash
# tests/test_ship_visibility_remotes.sh — the tag-visibility check understands every GitHub remote
# form, and is SKIPPED (announced) for a remote it cannot check, instead of failing the ship.
# (2026-10-25 review, confirmed 2026-10-31: an SSH remote was turned into `github/<owner>/<repo>`
# and 404'd on every poll; a GitLab or local-path remote was polled on raw.githubusercontent.com.)
#
# Part of the ship-loop rehearsal (the rig and its rationale: tests/lib/rehearsal.sh).
# Usage: bash tests/test_ship_visibility_remotes.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rehearsal.sh"

recording_curl() {  # recording_curl <dir> — the stub CDN, logging every URL it was asked for
  printf '%s\n' '#!/usr/bin/env bash' 'printf "curl %s\n" "${@: -1}" >> "$CALLS"' \
    'printf '"'"'{"name":"rehearsal","version":"%s"}\n'"'"' "$PUBLISHED_VERSION"' > "$1/bin/curl"
  chmod +x "$1/bin/curl"
}
remote_as() {  # remote_as <dir> <url> — origin presents as <url>, still resolving to the local bare repo
  git -C "$1/main" config url."$1/origin.git".insteadOf "$2"
  git -C "$1/main" remote set-url origin "$2"
}
want="curl https://raw.githubusercontent.com/haiggoh/rehearsal/main/.claude-plugin/plugin.json"

for form in "git@github.com:haiggoh/rehearsal.git" "ssh://git@github.com/haiggoh/rehearsal.git" \
            "https://github.com/haiggoh/rehearsal"; do
  D="$TMP/v$RANDOM"; rehearse "$D"; recording_curl "$D"; remote_as "$D" "$form"
  is "a $form remote ships" "0" "$(ship "$D" 0.2.0 'second')"
  is "  and polls the right manifest" "1" "$(grep -cxF "$want" "$D/calls")"
done

D="$TMP/vg"; rehearse "$D"; recording_curl "$D"; remote_as "$D" "https://gitlab.com/haiggoh/rehearsal.git"
is "a non-GitHub remote ships" "0" "$(ship "$D" 0.2.0 'second')"
is "  without polling raw.githubusercontent.com" "0" "$(grep -c '^curl ' "$D/calls")"
has "  and says the check was skipped" "$(cat "$D/out")" "visibility check skipped"

D="$TMP/vl"; rehearse "$D"; recording_curl "$D"; git -C "$D/main" remote set-url origin "$D/origin.git"
is "a local-path remote ships" "0" "$(ship "$D" 0.2.0 'second')"
is "  without polling" "0" "$(grep -c '^curl ' "$D/calls")"
has "  and says the check was skipped" "$(cat "$D/out")" "visibility check skipped"

summary
