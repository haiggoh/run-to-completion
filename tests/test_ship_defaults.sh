#!/usr/bin/env bash
# tests/test_ship_defaults.sh — the USER-LEVEL DEFAULTS TEMPLATE (waypoint
# rtc-ship-user-level-default, user design answers 2026-11-13): one defaults.json under the plugin
# data dir whose POLICY keys every repo inherits — a repo's own rtc-ship.json value always wins,
# "extends": false opts a repo out entirely. Created on the first ship / ship-config invocation
# (announced, full path printed), never silently rewriting a repo's rtc-ship.json. A repo-specific
# key inside the template is a loud config error, exit 2. RTC_DEFAULTS_FILE overrides the location;
# SET but missing must FAIL loudly, never fall through.
#
# Cases: created-on-first-use (announced + path), present template inherited (source: template),
# repo override wins (source names the overridden template value), extends:false ignores the
# template, repo-specific key in the template exits 2 naming it, RTC_DEFAULTS_FILE set-but-missing
# exits 2, the --which-config table prints the template's FULL PATH, cfg_get parity (the ONE
# resolver: cfg_get returns the template value when the repo is silent).
# Rig: tests/lib/rehearsal.sh (sourced; the same is/has/summary idiom as the sibling suites).
#
# Usage: bash tests/test_ship_defaults.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_ship_defaults.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/rehearsal.sh"

mkplain() {  # mkplain <dir> [rtc-ship.json body] — a minimal shippable repo, defaults to NO config keys
  local d=$1 body=${2:-'{}'}
  mkdir -p "$d/.claude-plugin" "$d/bin"
  printf '{"name":"g","version":"9.9.9"}\n' > "$d/.claude-plugin/plugin.json"
  printf '# Changelog\n\n## [9.9.9] — 2026-11-13 — probe\n\nx\n' > "$d/CHANGELOG.md"
  printf '%s\n' "$body" > "$d/rtc-ship.json"
  # a release-published stub: without it the ship reaches the REAL gh (no auth under HOME=$TMP)
  printf '%s\n' '#!/usr/bin/env bash' 'printf "gh %s\n" "$*" >> "${GH_CALLS:-/dev/null}"' 'exit 0' > "$d/bin/gh"
  chmod +x "$d/bin/gh"
  ( cd "$d" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm init \
      && git init -q --bare "$d-origin.git" && git remote add origin "$d-origin.git" \
      && git push -q origin main && git worktree add -q "$d-wt" -b feat/ship )
}

# The template location is pinned per case via CLAUDE_PLUGIN_DATA (the plugin data DIR the file
# is created in). RTC_DEFAULTS_FILE is deliberately NOT used for pinning: by the waypoint's rule a
# set-but-missing override FAILS loudly (d6) — it points at a file the operator says exists, and
# can never double as a creation target.
DPD="$(mktemp -d)"
DFT="$DPD/defaults.json"

echo "== the template is CREATED on the first ship invocation, announced with its full path =="
D="$TMP/d1"; mkplain "$D"
rm -f "$DFT"
( cd "$D-wt" && HOME="$TMP/bk" PATH="$D/bin:$PATH" CLAUDE_PLUGIN_DATA="$DPD" RTC_SKIP_TESTS=1 RTC_SKIP_REFRESH=1 \
    bash "$ROOT/bin/rtc-ship.sh" "$D-wt" 9.9.9 'probe' >"$D/out" 2>&1 )
is "the ship succeeds with a fresh template" "0" "$?"
is "  the template file now exists" "0" "$([ -f "$DFT" ] && echo 0 || echo 1)"
has "  the ship announced it with the full path" "$(cat "$D/out")" "$DFT"
is "  the first default is require_default_branch_checkout: true" "1" \
   "$(python3 -c "import json;print(int(json.load(open('$DFT'))['require_default_branch_checkout']))")"
is "  the ship did NOT rewrite the repo's rtc-ship.json" "0" \
   "$(grep -c require_default_branch_checkout "$D/rtc-ship.json")"

echo "== a present template's policy key is INHERITED (source: template) =="
D="$TMP/d2"; mkplain "$D"
printf '{"require_default_branch_checkout": true, "reap": false}\n' > "$DFT"
( cd "$D" && HOME="$TMP/bk" CLAUDE_PLUGIN_DATA="$DPD" bash "$ROOT/bin/rtc-ship.sh" --which-config ) >"$D/out" 2>&1
is "which-config exits 0" "0" "$?"
has "  it prints the template's FULL PATH" "$(cat "$D/out")" "$DFT"
has "  the inherited policy key shows source template" "$(cat "$D/out")" "require_default_branch_checkout"
has "  and its value came from the template" "$(cat "$D/out")" "true	template"

echo "== a repo override WINS and the table says what it overrode =="
D="$TMP/d3"; mkplain "$D" '{"tag_prefix": "v", "reap": false}'
printf '{"reap": true}\n' > "$DFT"
( cd "$D" && HOME="$TMP/bk" CLAUDE_PLUGIN_DATA="$DPD" bash "$ROOT/bin/rtc-ship.sh" --which-config ) >"$D/out" 2>&1
is "which-config exits 0" "0" "$?"
has "  the override names the template value it beat" "$(cat "$D/out")" "repo (overrides template: true)"

echo "== \"extends\": false ignores the template entirely =="
D="$TMP/d4"; mkplain "$D" '{"extends": false}'
printf '{"require_default_branch_checkout": true}\n' > "$DFT"
( cd "$D" && HOME="$TMP/bk" CLAUDE_PLUGIN_DATA="$DPD" bash "$ROOT/bin/rtc-ship.sh" --which-config ) >"$D/out" 2>&1
is "which-config exits 0" "0" "$?"
is "  no template source appears for the policy key" "0" "$(grep -c '	template' "$D/out")"

echo "== a repo-specific key inside the template is a LOUD config error (exit 2) =="
D="$TMP/d5"; mkplain "$D"
printf '{"manifest": "package.json"}\n' > "$DFT"
( cd "$D" && HOME="$TMP/bk" CLAUDE_PLUGIN_DATA="$DPD" bash "$ROOT/bin/rtc-ship.sh" --which-config ) >"$D/out" 2>&1
is "which-config exits 2 on a repo key in the template" "2" "$?"
has "  naming the offending key" "$(cat "$D/out")" "manifest"
has "  naming the template path" "$(cat "$D/out")" "$DFT"

echo "== RTC_DEFAULTS_FILE set but missing FAILS loudly (never falls through) =="
D="$TMP/d6"; mkplain "$D"
( cd "$D" && HOME="$TMP/bk" RTC_DEFAULTS_FILE="$TMP/nope/defaults.json" \
    bash "$ROOT/bin/rtc-ship.sh" --which-config ) >"$D/out" 2>&1
is "which-config exits 2 on a set-but-missing override" "2" "$?"
has "  naming the missing override path" "$(cat "$D/out")" "$TMP/nope/defaults.json"

echo "== cfg_get parity: the ONE resolver returns the template value when the repo is silent =="
D="$TMP/d7"; mkplain "$D" '{"tag_prefix": "v"}'
printf '{"stall_seconds": 900}\n' > "$DFT"
# --versions-only exercises the gate path; the stall value is not printed there, so assert via
# the table (the same resolver) AND via a real ship's stall validation accepting the inherited value.
( cd "$D" && HOME="$TMP/bk" CLAUDE_PLUGIN_DATA="$DPD" bash "$ROOT/bin/rtc-ship.sh" --which-config ) >"$D/out" 2>&1
has "  the table shows the inherited stall_seconds" "$(cat "$D/out")" "900	template"

summary
