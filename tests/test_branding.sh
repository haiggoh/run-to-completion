#!/usr/bin/env bash
# Static-surface + ship-loop branding pins (plan 2026-10-28, §Wave 2 Task 6): the mark is the
# repo's GitHub About emoji (🏃), verbatim, on the plugin's identity surfaces and the shipper's
# user-readable headers. R2: exact strings, never loosened.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0
check() { if [ "$1" = 0 ]; then echo "  ok: $2"; else echo "  FAIL: $2"; fail=1; fi; }

# 1) phase() — every ship step header leads with the mark after the elapsed-seconds stamp
PD="$(/usr/bin/grep -m1 '^phase()' "$ROOT/bin/rtc-ship.sh")"
POUT="$(bash -c "$PD; T0=0; SECONDS=5; phase hello" 2>&1)"
r=0; [ "$POUT" = "[   5s] 🏃 hello" ] || r=1
check $r "phase() headers lead with 🏃 (got: $POUT)"

# 2) the banner/identity line in --help (usage() prints the header comment, one # stripped)
L2="$("$ROOT/bin/rtc-ship.sh" --help | sed -n '2p')"
r=0; case "$L2" in "🏃 rtc-ship.sh — ship one milestone branch"*) ;; *) r=1;; esac
check $r "--help banner leads with 🏃 (got: ${L2:0:50})"

# 3) plugin.json description (R6)
DESC="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["description"])' "$ROOT/.claude-plugin/plugin.json")"
r=0; case "$DESC" in "🏃 "*) ;; *) r=1;; esac
check $r "plugin.json description leads with 🏃 (got: ${DESC:0:40})"

# 4) README h1 (R6)
H1="$(head -1 "$ROOT/README.md")"
r=0; [ "$H1" = "# 🏃 run-to-completion" ] || r=1
check $r "README h1 is '# 🏃 run-to-completion' (got: $H1)"

# 5) R5: a Branding section in EVERY skill file
for d in "$ROOT"/skills/*/; do
  r=0; /usr/bin/grep -q '^## Branding (🏃)$' "$d/SKILL.md" || r=1
  check $r "$(basename "$d")/SKILL.md carries '## Branding (🏃)'"
done

if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; exit 1; fi
