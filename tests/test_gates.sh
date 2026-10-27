#!/usr/bin/env bash
# tests/test_gates.sh — the suite gates (`rtc-ship.sh --test-only`): worker count and pre-flight.
#
# Two defects this pins (2026-10-27, measured on free-agents' ships):
#   1. rtc-ship.json's `test_workers` was documented in --help yet never read — only the env var and
#      a hardcoded 12 reached pytest. A config key that silently does nothing is a lie in the config.
#   2. .rtc/pre-flight.sh ran to completion BEFORE the main suite started, although the two cover
#      disjoint files — ~2 minutes of every ship spent waiting. They now run concurrently.
#
# pytest is stubbed at $HOME/.local/bin/pytest (the path gates() calls) under a scratch HOME, so the
# assertions are about what the gate ASKED for, not about any real suite.
#
# Usage: bash tests/test_gates.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_gates.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset RTC_TEST_WORKERS

# A scratch repo with consistent version surfaces. Each case gets a fresh one: gates() stamps a tree
# that passed, and a stamped tree skips every gate — reuse would test the stamp, not the gate.
mkrepo() {  # mkrepo <dir> [test_workers-json-value]
  local d=$1 tw=${2:-}
  mkdir -p "$d/.claude-plugin" "$d/tests" "$d/.rtc" "$d/home/.local/bin"
  printf '{"name":"g","version":"0.1.0"}\n' > "$d/.claude-plugin/plugin.json"
  printf '# Changelog\n\n## 0.1.0\n\nx\n' > "$d/CHANGELOG.md"
  if [ -n "$tw" ]; then printf '{"tag_prefix":"v","test_workers":%s}\n' "$tw" > "$d/rtc-ship.json"
  else printf '{"tag_prefix":"v"}\n' > "$d/rtc-ship.json"; fi
  # The stub records its argv and, for the overlap case, drops a marker pre-flight can wait for.
  cat > "$d/home/.local/bin/pytest" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GATES_LOG/pytest.argv"
: > "$GATES_LOG/main.started"
echo "1 passed in 0.01s"
STUB
  chmod +x "$d/home/.local/bin/pytest"
  ( cd "$d" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
}
gate() {  # gate <dir> [env...] — run --test-only under the scratch HOME; prints rc
  local d=$1; shift
  mkdir -p "$d/log"
  ( cd "$d" && env HOME="$d/home" GATES_LOG="$d/log" "$@" \
      bash "$ROOT/bin/rtc-ship.sh" --test-only "$d" >"$d/log/out" 2>&1; echo $? )
}
workers() { sed -n -E 's/.*-n ([^ ]+).*/\1/p' "$1/log/pytest.argv" | head -1; }

echo "== worker count: env > rtc-ship.json > 12 =="
mkrepo "$TMP/w-default"
is "no config, no env: the default 12" "0" "$(gate "$TMP/w-default")"
is "  and pytest got -n 12" "12" "$(workers "$TMP/w-default")"

mkrepo "$TMP/w-cfg" 4
is "test_workers in rtc-ship.json passes" "0" "$(gate "$TMP/w-cfg")"
is "  and REACHES pytest (was inert: always 12)" "4" "$(workers "$TMP/w-cfg")"

mkrepo "$TMP/w-env" 4
is "RTC_TEST_WORKERS beats the config" "0" "$(gate "$TMP/w-env" RTC_TEST_WORKERS=6)"
is "  and pytest got -n 6" "6" "$(workers "$TMP/w-env")"

mkrepo "$TMP/w-badcfg" '"lots"'
is "a non-numeric test_workers FAILS the gate" "1" "$(gate "$TMP/w-badcfg")"
has "  naming the key" "$(cat "$TMP/w-badcfg/log/out")" "test_workers"
is "  and never reaches pytest" "0" "$( [ -f "$TMP/w-badcfg/log/pytest.argv" ] && echo 1 || echo 0)"

mkrepo "$TMP/w-badenv"
is "a non-numeric RTC_TEST_WORKERS fails too" "1" "$(gate "$TMP/w-badenv" RTC_TEST_WORKERS=0)"
has "  naming the variable" "$(cat "$TMP/w-badenv/log/out")" "RTC_TEST_WORKERS"

echo "== pre-flight runs CONCURRENTLY with the main suite =="
# Deterministic, not timing-based: pre-flight waits (bounded) for the marker only a RUNNING main
# suite can create. Run serially, the marker cannot appear while pre-flight waits, so it fails.
mkrepo "$TMP/pf"
cat > "$TMP/pf/.rtc/pre-flight.sh" <<'PF'
#!/usr/bin/env bash
for _ in $(seq 1 100); do [ -e "$GATES_LOG/main.started" ] && { echo overlapped; exit 0; }; sleep 0.1; done
echo "pre-flight finished before the main suite started" >&2; exit 1
PF
chmod +x "$TMP/pf/.rtc/pre-flight.sh"
( cd "$TMP/pf" && git add -A && git -c user.email=t@t -c user.name=t commit -qm pf )
is "pre-flight and main overlap, and the gate passes" "0" "$(gate "$TMP/pf")"
has "  pre-flight's phase line is reported" "$(cat "$TMP/pf/log/out")" "pre-flight gates: pass"

mkrepo "$TMP/pf-red"
printf '#!/usr/bin/env bash\necho "venv gate red"; exit 1\n' > "$TMP/pf-red/.rtc/pre-flight.sh"
chmod +x "$TMP/pf-red/.rtc/pre-flight.sh"
( cd "$TMP/pf-red" && git add -A && git -c user.email=t@t -c user.name=t commit -qm pf )
is "a red pre-flight still fails the gate" "1" "$(gate "$TMP/pf-red")"
has "  and its output is shown, not swallowed by the background run" \
    "$(cat "$TMP/pf-red/log/out")" "venv gate red"
stamps=$(find "$TMP/pf-red/.git/rtc-tested" -type f 2>/dev/null | wc -l | tr -d ' ')
is "  and the tree is NOT stamped as passed" "0" "$stamps"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
