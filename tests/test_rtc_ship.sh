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
# Exactly the worktree-taking invocation shapes: the plain one and the --no-reap variant.
# A new flag that takes <worktree-dir> must be added here, or this count goes red on purpose.
is "--help prints a usage block" "$(grep -c 'rtc-ship.sh <worktree-dir>' "$TMP/help")" "2"
# The shebang is not help: usage()'s old awk had only `NR>1`, so line 1 printed with its '#'
# stripped and --help led with '!/usr/bin/env bash' (found 2026-10-28).
is "--help's first line is the banner, not the shebang" "1" "$(head -1 "$TMP/help" | grep -c 'rtc-ship.sh —')"
is "--help never prints a '!'-led line" "0" "$(grep -c '^!' "$TMP/help")"

# --help must document EVERY mode flag the dispatcher accepts. --versions-only was handled and
# absent from the usage block (found 2026-10-31). Flags are DERIVED from the dispatch `case`, so a
# new mode cannot be added undocumented; an empty extraction is itself a failure.
flags=$(sed -n '/^case "${1:-}" in/,/^esac/p' "$ROOT/bin/rtc-ship.sh" | grep -oE '^  --[a-z-]+\)' | tr -d ' )')
is "dispatch flags extracted (non-empty)" "$([ -n "$flags" ] && echo yes)" "yes"
for f in $flags; do
  is "--help documents $f" "1" "$([ "$(grep -cw -- "rtc-ship.sh $f" "$TMP/help")" -ge 1 ] && echo 1 || echo 0)"
done

# --help must document EVERYTHING the script reads. `usage()` used to print a hardcoded line range,
# so any env var added past line 31 was live and invisible — 0.6.11 shipped its tag-visibility gate
# exactly that way. Assert the LAST documented env var too, so a range regression fails here.
for v in RTC_MAIN RTC_SKIP_TESTS RTC_TEST_WORKERS RTC_SKIP_REFRESH RTC_TAG_VISIBILITY \
         RTC_TAG_VISIBILITY_TRIES RTC_TAG_VISIBILITY_DELAY RTC_SKIP_CLEANUP RTC_BACKUP_DIR; do
  # -w matters: RTC_TAG_VISIBILITY must not be "documented" by a line about its _TRIES sibling
  is "--help documents $v" "1" "$(grep -cw -- "$v" "$TMP/help")"
done
# and the LAST line of the header really is printed (the fixed-range bug's signature)
is "--help prints to the end of the header, not a fixed line range" \
   "1" "$(grep -c 'RTC_BACKUP_DIR' "$TMP/help")"
after=$(md5 -q "$ROOT/CHANGELOG.md" 2>/dev/null || echo x)
is "--help writes nothing" "$before" "$after"

# The declared-surface FALLBACK, exercised on a scratch copy of this repo's surfaces with no
# tests/ dir — this repo now has its own tests/test_version_consistency.sh, which the gate prefers,
# so running against $ROOT would test the other path. The copy also means nothing here ever writes
# to the real tree (these cases used to edit and restore $ROOT's own plugin.json and CHANGELOG).
FB="$TMP/fb"; mkdir -p "$FB/.claude-plugin"
cp "$ROOT/.claude-plugin/plugin.json" "$FB/.claude-plugin/"; cp "$ROOT/CHANGELOG.md" "$ROOT/rtc-ship.json" "$FB/"
"$ROOT/bin/rtc-ship.sh" --versions-only "$FB" >"$TMP/v" 2>&1
is "a consistent tree passes the gate" "$?" "0"
is "the gate reports both surfaces it checked" "$(grep -c 'plugin.json\|CHANGELOG' "$TMP/v")" "2"

# A split must FAIL, and name the offending surface.
python3 - "$FB/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["version"] = "9.9.9"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
"$ROOT/bin/rtc-ship.sh" --versions-only "$FB" >"$TMP/split" 2>&1
rc=$?
is "a split fails the gate" "$rc" "1"
is "the failure names the disagreeing surface" "$(grep -c 'changelog top is' "$TMP/split")" "1"
cp "$ROOT/.claude-plugin/plugin.json" "$FB/.claude-plugin/"

# An UNREADABLE changelog must fail too — an empty extraction is a failure, never a pass.
# (The first run of this script let a planted split through for exactly this reason.)
printf '# Changelog\n\nno numbered heading here\n' > "$FB/CHANGELOG.md"
"$ROOT/bin/rtc-ship.sh" --versions-only "$FB" >"$TMP/nohdr" 2>&1
is "an unreadable changelog fails the gate" "$?" "1"
is "and says so rather than passing silently" "$(grep -c 'no numbered heading' "$TMP/nohdr")" "1"

# And THIS repo, through its own test: consistent passes.
"$ROOT/bin/rtc-ship.sh" --versions-only "$ROOT" >"$TMP/own" 2>&1
is "this repo passes the gate through its own consistency test" "$?" "0"
is "and the gate really used that test" "$(grep -c 'a planted split fails' "$TMP/own")" "1"

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

# The gate must resolve its repo root even where there is NO git repo. The installed plugin cache
# is a plain directory, and free-agents' release tarball extracts into one too. `git rev-parse
# --show-toplevel` failing there left `top` EMPTY, so both surfaces were read through "/" and came
# back "<none>" — a perfectly consistent tree reported as disagreeing. (Found by dogfooding the
# installed 0.6.6: its own suite passed while this gate called 0.6.6 split against itself.)
NG="$TMP/nongit"; mkdir -p "$NG/.claude-plugin"
cp "$ROOT/.claude-plugin/plugin.json" "$NG/.claude-plugin/"
ngv=$(python3 -c "import json;print(json.load(open('$NG/.claude-plugin/plugin.json'))['version'])")
printf '# Changelog\n\n## %s\n\nconsistent\n' "$ngv" > "$NG/CHANGELOG.md"
"$ROOT/bin/rtc-ship.sh" --versions-only "$NG" >"$TMP/ng" 2>&1
is "the gate works outside a git repo (the installed cache is not one)" "0" "$?"
is "and actually READ the surfaces rather than reporting <none>" \
   "$(grep -c '<none>' "$TMP/ng")" "0"
is "and it agrees with itself" "$(grep -c 'version surfaces agree' "$TMP/ng")" "1"

# A RED suite must fail --test-only non-zero. The 2026-10-28 free-agents 0.47.0 ship attempt
# printed '✖ tests failed' and still exited 0, so a caller scripting off $? read a failed gate
# as a pass. Planted positive: this scratch repo's only test fails on purpose.
RED="$TMP/red"; mkdir -p "$RED/.claude-plugin" "$RED/tests"
git init -q "$RED"
printf '{"version":"0.1.0"}' > "$RED/.claude-plugin/plugin.json"
printf '# Changelog\n\n## 0.1.0\n\nx\n' > "$RED/CHANGELOG.md"
printf 'def test_red():\n    assert False, "deliberately red gate"\n' > "$RED/tests/test_red.py"
( cd "$RED" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
"$ROOT/bin/rtc-ship.sh" --test-only "$RED" >"$TMP/red-out" 2>&1
is "a red suite fails --test-only" "$?" "1"
is "and says the tests failed" "1" "$(grep -c 'tests failed' "$TMP/red-out")"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
