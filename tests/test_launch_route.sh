#!/usr/bin/env bash
# Framework-free tests for bin/claude_launch_route.py — launch-route classification from
# fixtures (no real process tree, no real claude). LR_BIN (test-only) points at another copy
# for known-bad mutation runs. The fake wrapper is called "gw" on purpose: detection must be
# structural, never a match on any real gateway's name.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${LR_BIN:-$HERE/../bin/claude_launch_route.py}"
pass=0; fail=0
check() { if [ "$1" -eq 0 ]; then echo "  PASS: $2"; pass=$((pass+1)); else echo "  FAIL: $2"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# fx <name> <json>: write a fixture; cls <name>: classify it into $TMP/<name>.out
fx()  { printf '%s\n' "$2" > "$TMP/$1.json"; }
cls() { python3 "$BIN" --classify "$TMP/$1.json" > "$TMP/$1.out" 2>&1; echo $? > "$TMP/$1.rc"; }
has() { grep -qF -- "$2" "$TMP/$1.out"; }

SH='{"pid":10,"comm":"/bin/zsh","args":["/bin/zsh"]}'
CL='{"pid":20,"comm":"claude","args":["claude"]}'
LOGIN='{"pid":40,"comm":"-zsh","args":["-zsh"]}'
TERM_APP='{"pid":50,"comm":"/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal","args":[]}'
CREDS='{"ANTHROPIC_AUTH_TOKEN":"tok-value-not-printed","ANTHROPIC_BASE_URL":"https://gw.example.test/v1"}'

echo "== wrapper (gateway-launcher shape) =="
fx wrap "{\"ancestry\":[$SH,$CL,{\"pid\":30,\"comm\":\"gw\",\"args\":[\"gw\",\"agent\",\"claude\",\"--select-key\"]},$LOGIN,$TERM_APP],\"env\":$CREDS,\"logged_in_clean\":false}"
cls wrap
r=0; has wrap 'kind=wrapper' && has wrap 'launcher=gw agent claude' && has wrap 'inside_session=True' || r=1
check $r "non-shell parent of claude => wrapper; leading words kept, one-shot flag dropped"
has wrap 'lane=gw.example.test'; check $? "lane is the base-URL host"
r=0; has wrap 'tok-value-not-printed' && r=1; check $r "credential values never printed"

echo "== direct launches =="
fx env "{\"ancestry\":[$SH,$CL,$LOGIN,$TERM_APP],\"env\":$CREDS,\"logged_in_clean\":false}"; cls env
r=0; has env 'kind=env' && has env 'launcher=-' || r=1; check $r "shell parent + credential vars => env"
fx login "{\"ancestry\":[$SH,$CL,$LOGIN],\"env\":{},\"logged_in_clean\":true}"; cls login
has login 'kind=login'; check $? "shell parent, no vars, clean probe logged in => login"
r=0; has login 'lane=anthropic-default' || r=1; check $r "login lane is anthropic-default"
fx none "{\"ancestry\":[$SH,$CL,$LOGIN],\"env\":{},\"logged_in_clean\":false}"; cls none
has none 'kind=none'; check $? "nothing to inherit and not logged in => none"

echo "== review-focus shapes =="
fx tenv "{\"ancestry\":[$SH,$CL,{\"pid\":31,\"comm\":\"/usr/bin/env\",\"args\":[\"env\",\"FOO=1\",\"claude\"]},$LOGIN],\"env\":$CREDS,\"logged_in_clean\":false}"; cls tenv
r=0; has tenv 'kind=env' || r=1; check $r "transparent env/nohup between claude and shell is skipped, not a wrapper"
fx node "{\"ancestry\":[$SH,{\"pid\":21,\"comm\":\"node\",\"args\":[\"node\",\"/opt/x/bin/claude\"]},$LOGIN],\"env\":$CREDS,\"logged_in_clean\":false}"; cls node
r=0; has node 'kind=env' && has node 'inside_session=True' || r=1; check $r "node-hosted claude is recognised"
fx tmux "{\"ancestry\":[$SH,$CL,{\"pid\":32,\"comm\":\"tmux\",\"args\":[\"tmux\"]}],\"env\":$CREDS,\"logged_in_clean\":false}"; cls tmux
has tmux 'kind=env'; check $? "tmux/login-shell parents count as direct"
fx unsafe "{\"ancestry\":[$SH,$CL,{\"pid\":33,\"comm\":\"gw\",\"args\":[\"gw\",\"sk-ABCDEFGHIJKLMNOP1234\",\"claude\"]},$LOGIN],\"env\":$CREDS,\"logged_in_clean\":false}"; cls unsafe
r=0; has unsafe 'kind=wrapper' && has unsafe 'launcher=unavailable (unsafe token)' || r=1; check $r "key-shaped launcher token => launcher unavailable"
r=0; has unsafe 'sk-ABC' && r=1; check $r "the unsafe token is never printed"
fx out "{\"ancestry\":[$LOGIN,$TERM_APP],\"env\":{},\"logged_in_clean\":true}"; cls out
r=0; has out 'inside_session=False' && has out 'kind=login' || r=1; check $r "no claude ancestor => outside a session"

echo "== live collector (read-only, no output of argv) =="
# Any real process tree has >= 2 ancestors; a ps header mis-parse once stopped the walk at 1
# while every fixture above stayed green (2026-11-26).
n=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import claude_launch_route as m; print(len(m.collect_ancestry()))' "$(dirname "$BIN")")
r=0; [ "${n:-0}" -ge 2 ] || r=1; check $r "live ancestry walk returns >= 2 processes (got ${n:-none})"
python3 "$BIN" --detect > "$TMP/live.out" 2>&1; r=$?; rr=0; [ "$r" = 0 ] && grep -q '^kind=' "$TMP/live.out" || rr=1
check $rr "--detect exits 0 with a kind= line"

echo "== cli hygiene =="
python3 "$BIN" --help > "$TMP/h.out" 2>&1; r=$?; [ "$r" = 0 ] && grep -q 'claude_launch_route' "$TMP/h.out"; check $? "--help exits 0 with usage"
python3 "$BIN" --bogus > /dev/null 2> "$TMP/b.err"; r=$?; rr=0; [ "$r" = 2 ] && grep -q -- '--bogus' "$TMP/b.err" || rr=1; check $rr "unknown flag exits 2 naming it"

echo
echo "claude_launch_route: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
