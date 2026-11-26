#!/usr/bin/env bash
# Framework-free tests for bin/launch-claude-session. No real window, no real claude:
# the process tree, the clean login probe and the window driver are replaced through the
# documented test-only seams LCS_TEST_ANCESTRY_JSON / LCS_TEST_LOGIN_CLEAN / LCS_TEST_DRIVER,
# and CLAUDE_CONFIG_DIR points at a temp dir. LCS_BIN (test-only) selects another copy for
# known-bad mutation runs. The fake wrapper is "gw" on purpose (structural detection).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${LCS_BIN:-$HERE/../bin/launch-claude-session}"
pass=0; fail=0
check() { if [ "$1" -eq 0 ]; then echo "  PASS: $2"; pass=$((pass+1)); else echo "  FAIL: $2"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/conf"; mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$TMP/work"
LEARNED="$CLAUDE_CONFIG_DIR/launch-claude-session/launch-route.json"
SECRET='sk-planted-0123456789abcdef'

SH='{"pid":10,"comm":"/bin/zsh","args":["/bin/zsh"]}'
CL='{"pid":20,"comm":"claude","args":["claude"]}'
GW='{"pid":30,"comm":"gw","args":["gw","agent","claude","--select-key"]}'
LOGIN='{"pid":40,"comm":"-zsh","args":["-zsh"]}'
printf '[%s,%s,%s,%s]\n' "$SH" "$CL" "$GW" "$LOGIN" > "$TMP/anc-wrap.json"
printf '[%s,%s,%s]\n' "$SH" "$CL" "$LOGIN" > "$TMP/anc-direct.json"
printf '[%s]\n' "$LOGIN" > "$TMP/anc-outside.json"

# lcs <case> <ancestry> <login_clean> <creds:yes|no> <args...>
lcs() {
	local c=$1 anc=$2 li=$3 cr=$4; shift 4
	# hermetic: drop the CALLER's route variables (the suite may run inside a real session).
	# grep -E, not sed '\|' — BSD sed has no alternation in basic regex, which once left these set.
	( for v in $(env | cut -d= -f1 | grep -E '^(ANTHROPIC_|CLAUDE_CODE_USE_|CLOUD_ML_REGION$|VERTEX_REGION_|OPENAI_|AWS_)'); do unset "$v"; done
	  if [ "$cr" = yes ]; then export ANTHROPIC_AUTH_TOKEN="$SECRET" ANTHROPIC_BASE_URL=https://gw.example.test/v1; fi
	  LCS_TEST_ANCESTRY_JSON="$TMP/anc-$anc.json" LCS_TEST_LOGIN_CLEAN="$li" "$BIN" --cwd "$TMP/work" "$@" ) \
		> "$TMP/$c.out" 2> "$TMP/$c.err"; echo $? > "$TMP/$c.rc"
}
rc()  { cat "$TMP/$1.rc"; }
out() { cat "$TMP/$1.out" "$TMP/$1.err"; }

echo "== cli hygiene =="
"$BIN" --help > "$TMP/h.out" 2>&1; r=$?; rr=0; [ "$r" = 0 ] && grep -q 'launch-claude-session' "$TMP/h.out" || rr=1
check $rr "--help exits 0 with usage"
r=0; [ -e "$LEARNED" ] && r=1; check $r "--help learns/writes nothing"
lcs unk direct false yes --bogus
r=0; [ "$(rc unk)" = 2 ] && grep -q -- '--bogus' "$TMP/unk.err" || r=1; check $r "unknown flag exits 2 naming it"
lcs rbad direct false yes --route sideways
r=0; [ "$(rc rbad)" = 2 ] && grep -q 'sideways' "$TMP/rbad.err" || r=1; check $r "unknown --route exits 2 naming it"

echo "== route-info =="
lcs info wrap false yes --route-info
r=0; [ "$(rc info)" = 0 ] && grep -qF 'route=wrapper launcher=gw agent claude' "$TMP/info.out" || r=1
check $r "--route-info reports the detected wrapper and its launcher words"

echo "== auto routes (dry-run) =="
lcs aw wrap false yes --dry-run
r=0; grep -qF '. <0600 env file>' "$TMP/aw.out" && grep -q "&& claude" "$TMP/aw.out" && grep -q '^inherits:' "$TMP/aw.out" || r=1
check $r "inside a wrapper-launched session, auto INHERITS (env file + plain claude)"
lcs al direct true no --dry-run
r=0; [ "$(rc al)" = 0 ] && grep -q '&& claude' "$TMP/al.out" || r=1; check $r "normal login: auto launches plain claude"
r=0; grep -qF '<0600 env file>' "$TMP/al.out" && r=1; grep -q '^inherits:' "$TMP/al.out" && r=1; check $r "normal login: no env file, nothing inherited"
lcs an direct false no --dry-run
r=0; [ "$(rc an)" = 2 ] && grep -q 'claude auth login' "$TMP/an.err" || r=1; check $r "nothing to inherit and not logged in => exit 2 with the fix"

echo "== explicit routes =="
lcs ln wrap false yes --dry-run --route launcher --prompt hi -- --effort high
r=0; grep -qF 'gw agent claude -- --effort high' "$TMP/ln.out" && grep -qF '"$(cat <prompt file>)"' "$TMP/ln.out" || r=1
check $r "--route launcher replays the launcher words, claude args after --"
lcs lnx direct false yes --dry-run --route launcher
r=0; [ "$(rc lnx)" = 2 ] || r=1; check $r "--route launcher without a detected or learned launcher exits 2"
lcs lgx direct false yes --dry-run --route login
r=0; [ "$(rc lgx)" = 2 ] || r=1; check $r "--route login when the clean probe is not logged in exits 2"
lcs inx direct true no --dry-run --route inherit
r=0; [ "$(rc inx)" = 2 ] || r=1; check $r "--route inherit with no credentials exits 2"

echo "== secrets and the learned file =="
rm -f "$LEARNED"; lcs sec wrap false yes --route-info; lcs sec2 wrap false yes --dry-run --prompt hi
r=0; { out sec; out sec2; cat "$LEARNED" 2>/dev/null; } | grep -qF "$SECRET" && r=1; check $r "the credential value is in no output and not in the learned file"
r=0; [ -f "$LEARNED" ] && [ "$(stat -f %Lp "$LEARNED")" = 600 ] || r=1; check $r "learned route file exists with mode 600"
r=0; grep -q '"kind": "wrapper"' "$LEARNED" && grep -q '"gw"' "$LEARNED" || r=1; check $r "learned file records kind + launcher words"
lcs outl outside false no --dry-run
r=0; [ "$(rc outl)" = 0 ] && grep -qF 'gw agent claude' "$TMP/outl.out" || r=1
check $r "outside any session, auto uses the LEARNED launcher"

echo "== overrides fail loudly =="
LAUNCH_CLAUDE_LEAN_SETTINGS="$TMP/missing.json" lcs lean direct false yes --dry-run --lean
r=0; [ "$(rc lean)" = 2 ] && grep -q 'LAUNCH_CLAUDE_LEAN_SETTINGS' "$TMP/lean.err" || r=1; check $r "set-but-missing lean settings exits 2 naming the variable"
lcs lean2 direct false yes --dry-run --lean
grep -q -- '--strict-mcp-config' "$TMP/lean2.out"; check $? "--lean adds --strict-mcp-config"
LCS_TEST_LOGIN_CLEAN=maybe "$BIN" --dry-run > /dev/null 2> "$TMP/badli.err"; r=$?; rr=0; [ "$r" = 2 ] && grep -q LCS_TEST_LOGIN_CLEAN "$TMP/badli.err" || rr=1
check $rr "an invalid test seam value exits 2 naming it"

echo "== started verdict (fake driver) =="
cat > "$TMP/driver" <<'DRV'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DRV_LOG"
python3 - <<'PY'
import json, os, time
d = os.path.join(os.environ['CLAUDE_CONFIG_DIR'], 'sessions')
json.dump({'pid': int(os.environ['FAKE_LIVE_PID']), 'sessionId': 's-test', 'cwd': os.environ['FAKE_DRV_CWD'],
           'kind': 'interactive', 'startedAt': int(time.time() * 1000) + 2000}, open(os.path.join(d, 'x.json'), 'w'))
PY
echo "VERIFIED after 0s"
DRV
chmod +x "$TMP/driver"
FAKE_DRV_LOG="$TMP/drv.log" FAKE_LIVE_PID=$$ FAKE_DRV_CWD="$TMP/work" LCS_TEST_DRIVER="$TMP/driver" lcs st wrap false yes --start-timeout 5
r=0; [ "$(rc st)" = 0 ] && grep -q '^STARTED pid=.* session=s-test route=inherit lane=gw.example.test' "$TMP/st.out" || r=1
check $r "a registered session => STARTED with route and lane"
r=0; grep -qF "$SECRET" "$TMP/drv.log" && r=1; check $r "the driver's command line carries no credential value"
r=0; ls "${TMPDIR:-/tmp}"/launch-claude-session-env-* > /dev/null 2>&1 && r=1; check $r "no env file is left behind"

echo
echo "launch-claude-session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
