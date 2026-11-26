#!/usr/bin/env bash
# Framework-free tests for bin/run-in-terminal. Terminal.app is never driven: a fake
# `osascript` and `uname` sit first on PATH (tests/lib/fake_osascript.sh).
# RIT_BIN (test-only) points the suite at another copy, for known-bad mutation runs.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${RIT_BIN:-$HERE/../bin/run-in-terminal}"

pass=0; fail=0
check() { if [ "$1" -eq 0 ]; then echo "  PASS: $2"; pass=$((pass+1)); else echo "  FAIL: $2"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cp "$HERE/lib/fake_osascript.sh" "$FAKEBIN/osascript"; chmod +x "$FAKEBIN/osascript"
printf '#!/bin/sh\necho "${FAKE_UNAME:-Darwin}"\n' > "$FAKEBIN/uname"; chmod +x "$FAKEBIN/uname"
export PATH="$FAKEBIN:$PATH"

# run <case> <args...>: fresh fake state per case; stdout -> $TMP/<case>.out, stderr -> .err, rc -> .rc
run() {
	local c=$1; shift
	export FAKE_OSA_LOG="$TMP/$c.osa" FAKE_OSA_BUSY="$TMP/$c.busy" FAKE_OSA_HISTORY="$TMP/$c.hist"
	"$BIN" "$@" > "$TMP/$c.out" 2> "$TMP/$c.err"; echo $? > "$TMP/$c.rc"
}
rc() { cat "$TMP/$1.rc"; }

echo "== help-runs-nothing =="
run help --help
r=0; [ "$(rc help)" = 0 ] && grep -q 'run-in-terminal' "$TMP/help.out" && [ ! -e "$TMP/help.osa" ] || r=1
check $r "--help exits 0, prints usage, opens no window"

echo "== unknown-arg / missing-value =="
run unk --bogus
r=0; [ "$(rc unk)" = 2 ] && grep -q -- '--bogus' "$TMP/unk.err" || r=1; check $r "unknown flag exits 2 naming it"
( "$BIN" --label > /dev/null 2>&1 & p=$!; sleep 5; kill $p 2>/dev/null && exit 9; wait $p ); got=$?
r=0; [ "$got" = 2 ] || r=1; check $r "a value flag with no value exits 2 (no hang)"

echo "== already-satisfied =="
run sat --command 'echo hi' --verify true
r=0; [ "$(rc sat)" = 0 ] && grep -q '^ALREADY_SATISFIED' "$TMP/sat.out" && [ ! -e "$TMP/sat.osa" ] || r=1
check $r "verify already passing => ALREADY_SATISFIED, no window"

echo "== verified =="
export FAKE_OSA_TOUCH="$TMP/flag"
run ver --command 'echo hi' --verify "[ -f '$TMP/flag' ]" --timeout 20 --label demo
unset FAKE_OSA_TOUCH
r=0; [ "$(rc ver)" = 0 ] && grep -q '^VERIFIED after' "$TMP/ver.out" && grep -q '^WINDOW_ID=42' "$TMP/ver.out" || r=1
check $r "verify flips while the window runs => VERIFIED, WINDOW_ID printed"

echo "== generic-banner / label-apostrophe =="
grep -q '=== Claude opened this window to demo ===' "$TMP/ver.osa"; check $? "banner is generic and carries the label"
r=0; grep -qi 'password' "$TMP/ver.osa" && r=1; check $r "banner does not mention a password"
run apos --command 'echo hi' --verify false --timeout 2 --label "this session's"
# two quoting layers: shlex ('"'"') inside an AppleScript string literal (\" escaped)
grep -qF "this session'\\\"'\\\"'s ===" "$TMP/apos.osa"; check $? "a label with an apostrophe is shell-quoted"

echo "== exited-early-masked =="
printf 'false\nfalse\n' > "$TMP/early.busy"
printf 'starting\ntoken sk-abcdef1234567890XYZ leaked\nbye\n' > "$TMP/early.hist"
export FAKE_OSA_BUSY="$TMP/early.busy" FAKE_OSA_HISTORY="$TMP/early.hist"
"$BIN" --command 'echo hi' --watch 8 > "$TMP/early.out" 2> "$TMP/early.err"; erc=$?
r=0; [ "$erc" = 1 ] && grep -q '^EXITED_EARLY' "$TMP/early.err" || r=1; check $r "window command ended => EXITED_EARLY, exit 1"
r=0; grep -q 'sk-<masked>' "$TMP/early.err" && ! grep -q 'sk-abcdef1234567890XYZ' "$TMP/early.err" || r=1
check $r "the window tail masks token-shaped strings"

echo "== review fixes: env hygiene, timeout, window identity for --verify =="
WATCH=abc run wenv --command 'echo hi' --verify true
r=0; [ "$(rc wenv)" = 0 ] && grep -q ALREADY_SATISFIED "$TMP/wenv.out" || r=1; check $r "an exported WATCH does not change behaviour"
run tmo --command 'echo hi' --timeout ''
r=0; [ "$(rc tmo)" = 2 ] && [ ! -e "$TMP/tmo.osa" ] || r=1; check $r "--timeout '' exits 2 before opening a window"
run tty --command 'echo hi' --verify '[ "$RIT_WINDOW_ID" = 42 ] && [ "$RIT_WINDOW_TTY" = /dev/ttys0FAKE ]' --timeout 6
r=0; [ "$(rc tty)" = 0 ] && grep -q '^VERIFIED' "$TMP/tty.out" && grep -q '^WINDOW_TTY=/dev/ttys0FAKE' "$TMP/tty.out" || r=1
check $r "--verify sees RIT_WINDOW_ID/RIT_WINDOW_TTY; WINDOW_TTY is printed"
run ttypre --command 'echo hi' --verify '[ -n "$RIT_WINDOW_TTY" ]' --timeout 6
r=0; grep -q ALREADY_SATISFIED "$TMP/ttypre.out" && r=1; check $r "the no-window pre-check sees no window tty (cannot ALREADY_SATISFY a window test)"

echo "== non-darwin =="
FAKE_UNAME=Linux run lin --command 'echo hi'
r=0; [ "$(rc lin)" = 2 ] && grep -q 'needs macOS Terminal.app' "$TMP/lin.err" && [ ! -e "$TMP/lin.osa" ] || r=1
check $r "non-macOS exits 2 before opening anything"

echo
echo "run-in-terminal: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
