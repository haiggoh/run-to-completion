#!/usr/bin/env bash
# Ship-mark pins (plan 2026-10-28, amendment 2026-10-30): the ship CLI (rtc-ship.sh) carries 🚢 —
# the literal ship — ONLY at the moments the user named: the invocation line, the tag-push and
# release confirmations, the --help banner, and the finale (🏃🚢 combined). Routine phases
# (tests, rebase, refresh, cleanup) stay UNBRANDED — "testing is too early for the ship".
# The plugin's own surfaces keep 🏃 (its About emoji). R2: exact strings, never loosened.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0
check() { if [ "$1" = 0 ]; then echo "  ok: $2"; else echo "  FAIL: $2"; fail=1; fi; }
SHIP="$ROOT/bin/rtc-ship.sh"

# 1) phase() itself is UNBRANDED — the mark lives on specific call sites, not the emitter
PD="$(/usr/bin/grep -m1 '^phase()' "$SHIP")"
POUT="$(bash -c "$PD; T0=0; SECONDS=5; phase hello" 2>&1)"
r=0; [ "$POUT" = "[   5s] hello" ] || r=1
check $r "phase() emits plain headers (got: $POUT)"

# 2) the banner/identity line in --help leads with the ship — on LINE 1 now that usage() skips
# the shebang (before 0.9.5 line 1 was '!/usr/bin/env bash' and this pin read line 2, encoding the
# bug; the pin moved to 1p with the fix, and test_rtc_ship.sh pins the negative: no '!'-led line)
L1="$("$SHIP" --help | sed -n '1p')"
r=0; case "$L1" in "🚢 rtc-ship.sh — ship one milestone branch"*) ;; *) r=1;; esac
check $r "--help banner leads with 🚢 (got: ${L1:0:50})"

# 3) the named ship moments carry 🚢, verbatim phrasing (user 2026-10-30)
for frag in 'phase "🚢 starting the shipping loop' \
            'phase "🚢 merged, tagged' \
            'phase "🚢 tag ${PREFIX}${V} is VISIBLE' \
            'phase "🚢 release published'; do
  r=0; /usr/bin/grep -qF "$frag" "$SHIP" || r=1
  check $r "ship moment pinned: $frag"
done
# and the finale combines both identities
r=0; /usr/bin/grep -qF 'phase "🏃🚢 done —' "$SHIP" || r=1
check $r "finale combines both marks (🏃🚢)"

# 4) NOTHING ELSE is branded: exactly one 🏃-carrying phase call (the finale), four 🚢 ones
N_RUN=$(/usr/bin/grep -cF 'phase "🏃' "$SHIP")
r=0; [ "$N_RUN" = "1" ] || r=1
check $r "exactly one 🏃 phase call — the finale (got: $N_RUN)"
N_SHIP=$(/usr/bin/grep -cF 'phase "🚢' "$SHIP")
r=0; [ "$N_SHIP" = "4" ] || r=1
check $r "exactly four 🚢 phase calls (got: $N_SHIP)"

# 5) the ship-approval question in the skill layer carries the ship mark, verbatim phrasing
/usr/bin/grep -qF '🚢 are you approving to ship the new release?' "$ROOT/skills/execute-unattended/SKILL.md"
check $? "execute-unattended asks the approval question with 🚢"

# 6) the plugin's own surfaces keep 🏃 (unchanged from 0.9.3)
DESC="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["description"])' "$ROOT/.claude-plugin/plugin.json")"
r=0; case "$DESC" in "🏃 "*) ;; *) r=1;; esac
check $r "plugin.json description still leads with 🏃"
H1="$(head -1 "$ROOT/README.md")"
r=0; [ "$H1" = "# 🏃 run-to-completion" ] || r=1
check $r "README h1 still '# 🏃 run-to-completion'"
for d in "$ROOT"/skills/*/; do
  r=0; /usr/bin/grep -q '^## Branding (🏃)$' "$d/SKILL.md" || r=1
  check $r "$(basename "$d")/SKILL.md carries '## Branding (🏃)'"
done

# 7) autopilot carries its own mark ✈️ (user 2026-10-31), mirroring the ship tool's 🚢: the skill's
# first reply leads with both identities, the way the ship finale combines 🏃🚢
/usr/bin/grep -qF 'lead your first substantive reply with "🏃✈️ autopilot:"' "$ROOT/skills/autopilot/SKILL.md"
check $? "autopilot leads its first reply with 🏃✈️"
# and the README shows each sub-mark exactly ONCE, where its thing is introduced
for mark in "✈️" "🚢"; do
  N=$(/usr/bin/grep -oF "$mark" "$ROOT/README.md" | wc -l | tr -d ' ')
  r=0; [ "$N" = "1" ] || r=1
  check $r "README carries $mark exactly once (got: $N)"
done
r=0; /usr/bin/grep -qF '| ✈️ `autopilot` |' "$ROOT/README.md" || r=1
check $r "README's ✈️ sits on the autopilot row"
r=0; /usr/bin/grep -qF '**🚢 The ship tool, `rtc-ship.sh`.**' "$ROOT/README.md" || r=1
check $r "README's 🚢 sits on the ship-tool paragraph"

if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; exit 1; fi
