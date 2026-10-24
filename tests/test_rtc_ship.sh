#!/usr/bin/env bash
# tests/test_rtc_ship.sh — the generalized ship loop's GATE, in both directions.
#
# The gate is the reason rtc-ship.sh exists: the version bump lands after the suite has run, so a
# split is introduced between "tests green" and "PR opened" and only a re-check catches it. A gate
# that has never been observed to fail is indistinguishable from a decorative one, so both
# directions are tested here.
#
# Usage: bash tests/test_rtc_ship.sh
set -uo pipefail
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --help must print help and write nothing
before=$(md5 -q "$ROOT/CHANGELOG.md" 2>/dev/null || echo x)
"$ROOT/bin/rtc-ship.sh" --help >"$TMP/help" 2>&1
is "--help exits 0" "$?" "0"
is "--help prints a usage block" "$(grep -c 'rtc-ship.sh <worktree-dir>' "$TMP/help")" "1"
after=$(md5 -q "$ROOT/CHANGELOG.md" 2>/dev/null || echo x)
is "--help writes nothing" "$before" "$after"

# --versions-only on THIS repo, which has no VERSION file and no consistency test of its own,
# so it exercises the declared-surface fallback rather than the repo's own script.
"$ROOT/bin/rtc-ship.sh" --versions-only "$ROOT" >"$TMP/v" 2>&1
is "a consistent tree passes the gate" "$?" "0"
is "the gate reports both surfaces it checked" "$(grep -c 'plugin.json\|CHANGELOG' "$TMP/v")" "2"

# A split must FAIL, and name the offending surface.
cp "$ROOT/.claude-plugin/plugin.json" "$TMP/plugin.json"
python3 - "$ROOT/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["version"] = "9.9.9"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
"$ROOT/bin/rtc-ship.sh" --versions-only "$ROOT" >"$TMP/split" 2>&1
rc=$?
is "a split fails the gate" "$rc" "1"
is "the failure names the disagreeing surface" "$(grep -c 'changelog top is' "$TMP/split")" "1"
cp "$TMP/plugin.json" "$ROOT/.claude-plugin/plugin.json"

# An UNREADABLE changelog must fail too — an empty extraction is a failure, never a pass.
# (The first run of this script let a planted split through for exactly this reason.)
cp "$ROOT/CHANGELOG.md" "$TMP/CHANGELOG.md"
printf '# Changelog\n\nno numbered heading here\n' > "$ROOT/CHANGELOG.md"
"$ROOT/bin/rtc-ship.sh" --versions-only "$ROOT" >"$TMP/nohdr" 2>&1
is "an unreadable changelog fails the gate" "$?" "1"
is "and says so rather than passing silently" "$(grep -c 'no numbered heading' "$TMP/nohdr")" "1"
cp "$TMP/CHANGELOG.md" "$ROOT/CHANGELOG.md"

# Both heading styles: bracketed (free-agents) and bare (this repo).
mkdir -p "$TMP/br" "$TMP/bare"
printf '# Changelog\n\n## [1.2.3]\n\n### Added\n- x\n' > "$TMP/br/CHANGELOG.md"
printf '# Changelog\n\n## 1.2.3\n\n### Added\n- x\n' > "$TMP/bare/CHANGELOG.md"
parse_top() { sed -n -E 's/^##+[[:space:]]+\[?([0-9]+\.[0-9]+\.[0-9]+)\]?.*/\1/p' "$1" | head -1; }
is "a bracketed heading parses" "$(parse_top "$TMP/br/CHANGELOG.md")" "1.2.3"
is "a bare heading parses" "$(parse_top "$TMP/bare/CHANGELOG.md")" "1.2.3"

# The default branch is RESOLVED, never assumed. echoprism's is `master`; a hardcoded `main` would
# mis-ship it. "merge to main" in prose means the default branch, never a branch literally named main.
resolve_branch() {    # the same three-step resolution the ship path uses
  local cfg_branch=$1 repo=$2
  if [ -n "$cfg_branch" ]; then echo "$cfg_branch"; return; fi
  git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo main
}
is "a repo whose default is master resolves to master, not main"    "$(resolve_branch "" "$HOME/ClaudeWorkspace/echoprism" 2>/dev/null)" "master"
is "a repo whose default is main resolves to main"    "$(resolve_branch "" "$ROOT")" "main"
is "an explicit config key overrides the remote's HEAD"    "$(resolve_branch "trunk" "$ROOT")" "trunk"

# A repo's own consistency test is preferred over the config fallback.
is "a repo with its own test still passes" \
   "$("$ROOT/bin/rtc-ship.sh" --versions-only "$HOME/ClaudeWorkspace/cost-tracker" >/dev/null 2>&1; echo $?)" "0"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
