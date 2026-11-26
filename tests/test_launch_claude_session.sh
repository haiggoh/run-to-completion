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
# a temp Claude config: pre-trust writes HERE, never to the real ~/.claude.json
CFG="$CLAUDE_CONFIG_DIR/.claude.json"; echo '{"projects":{}}' > "$CFG"
trusted() { python3 -c 'import json,os,sys; d=json.load(open(sys.argv[1])); print((d.get("projects",{}).get(os.path.realpath(sys.argv[2])) or {}).get("hasTrustDialogAccepted"))' "$CFG" "$1"; }
LEARNED="$CLAUDE_CONFIG_DIR/launch-claude-session/launch-route.json"
SECRET='sk-planted-0123456789abcdef'

SH='{"pid":10,"comm":"/bin/zsh","args":["/bin/zsh"]}'
CL='{"pid":20,"comm":"claude","args":["claude"]}'
GW='{"pid":30,"comm":"gw","args":["gw","agent","claude","--select-key"]}'
LOGIN='{"pid":40,"comm":"-zsh","args":["-zsh"]}'
printf '[%s,%s,%s,%s]\n' "$SH" "$CL" "$GW" "$LOGIN" > "$TMP/anc-wrap.json"
printf '[%s,%s,%s]\n' "$SH" "$CL" "$LOGIN" > "$TMP/anc-direct.json"
printf '[%s]\n' "$LOGIN" > "$TMP/anc-outside.json"

# lcs <case> <ancestry> <login_clean> <creds:yes|no|url> <args...>
lcs() {
	local c=$1 anc=$2 li=$3 cr=$4; shift 4
	# hermetic: drop the CALLER's route variables (the suite may run inside a real session).
	# grep -E, not sed '\|' — BSD sed has no alternation in basic regex, which once left these set.
	( for v in $(env | cut -d= -f1 | grep -E '^(ANTHROPIC_|CLAUDE_CODE_USE_|CLOUD_ML_REGION$|VERTEX_REGION_|OPENAI_|AWS_)'); do unset "$v"; done
	  if [ "$cr" = yes ]; then export ANTHROPIC_AUTH_TOKEN="$SECRET" ANTHROPIC_BASE_URL=https://gw.example.test/v1; fi
	  if [ "$cr" = url ]; then export ANTHROPIC_BASE_URL=http://localhost:4141; fi
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
rm -f "$LEARNED"; lcs lnx direct false yes --dry-run --route launcher
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
# Fake run-in-terminal: optional session registration, optional decoy, transcript lines, rc/stderr.
# Env: FAKE_DRV_LOG, FAKE_LIVE_PID, FAKE_DRV_CWD, FAKE_DRV_RC, FAKE_DRV_ERR, FAKE_DRV_NOSESSION,
#      FAKE_DECOY_PID, FAKE_DRV_TRANSCRIPT (JSON lines for session s-test).
cat > "$TMP/driver" <<'DRV'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DRV_LOG"
python3 - <<'PY2'
import json, os, re, time
c = os.environ['CLAUDE_CONFIG_DIR']; d = os.path.join(c, 'sessions'); cwd = os.environ['FAKE_DRV_CWD']
now = int(time.time() * 1000) + 2000
def reg(name, pid, sid):
    json.dump({'pid': int(pid), 'sessionId': sid, 'cwd': cwd, 'kind': 'interactive', 'startedAt': now},
              open(os.path.join(d, name), 'w'))
if os.environ.get('FAKE_DECOY_PID'):
    reg('decoy.json', os.environ['FAKE_DECOY_PID'], 's-decoy')
if not os.environ.get('FAKE_DRV_NOSESSION'):
    reg('x.json', os.environ['FAKE_LIVE_PID'], 's-test')
t = os.environ.get('FAKE_DRV_TRANSCRIPT')
if t:
    pd = os.path.join(c, 'projects', re.sub(r'[^A-Za-z0-9]', '-', os.path.realpath(cwd))); os.makedirs(pd, exist_ok=True)
    open(os.path.join(pd, 's-test.jsonl'), 'w').write(t)
PY2
echo "WINDOW_ID=42"; echo "WINDOW_TTY=/dev/ttysWIN"
[ -n "${FAKE_DRV_ERR:-}" ] && echo "$FAKE_DRV_ERR" >&2
rc=${FAKE_DRV_RC:-0}; [ "$rc" = 0 ] && echo "VERIFIED after 0s"
exit "$rc"
DRV
chmod +x "$TMP/driver"
export FAKE_DRV_LOG="$TMP/drv.log" FAKE_LIVE_PID=$$ FAKE_DRV_CWD="$TMP/work" LCS_TEST_DRIVER="$TMP/driver"
# test-only tty map: the launched session ($$) sits on the window tty, a decoy ($PPID) elsewhere
export LCS_TEST_TTY_MAP="$$:ttysWIN,$PPID:ttysOTHER"
clean_sessions() { rm -f "$CLAUDE_CONFIG_DIR"/sessions/*.json; rm -rf "$CLAUDE_CONFIG_DIR/projects"; }

clean_sessions; lcs st wrap false yes --start-timeout 5
r=0; [ "$(rc st)" = 0 ] && grep -q '^STARTED pid=.* session=s-test route=inherit lane=gw.example.test' "$TMP/st.out" || r=1
check $r "a registered session => STARTED with route and lane"
r=0; grep -qF "$SECRET" "$TMP/drv.log" && r=1; check $r "the driver's command line carries no credential value"
r=0; ls "${TMPDIR:-/tmp}"/launch-claude-session-env-* > /dev/null 2>&1 && r=1; check $r "no env file is left behind"

echo "== review fixes: verdict honesty =="
REAL='{"type":"assistant","message":{"model":"claude-x","content":[{"type":"text","text":"OK"}]}}'
SYN='{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 422"}]}}'
clean_sessions; FAKE_DRV_TRANSCRIPT="$SYN" lcs syn wrap false yes --start-timeout 5 --prompt hi --wait-reply 3
r=0; [ "$(rc syn)" = 1 ] && grep -q '^NO_REPLY' "$TMP/syn.out" || r=1; check $r "an API-error record is NOT a reply (NO_REPLY, exit 1)"
clean_sessions; FAKE_DRV_TRANSCRIPT="$REAL" lcs rep wrap false yes --start-timeout 5 --prompt hi --wait-reply 5
r=0; [ "$(rc rep)" = 0 ] && grep -q '^REPLIED' "$TMP/rep.out" || r=1; check $r "a real assistant record => REPLIED"
clean_sessions; FAKE_DRV_NOSESSION=1 FAKE_DRV_RC=1 FAKE_DRV_ERR='error: could not drive Terminal.app (Automation permission?)' lcs dfail wrap false yes --start-timeout 5
r=0; [ "$(rc dfail)" = 1 ] && out dfail | grep -q 'Automation permission' || r=1; check $r "a driver failure shows the driver's own message"
clean_sessions; FAKE_DRV_NOSESSION=1 FAKE_DRV_RC=2 FAKE_DRV_ERR='error: --timeout needs a whole number' lcs dusage wrap false yes --start-timeout 5
r=0; [ "$(rc dusage)" = 2 ] || r=1; check $r "a driver usage error exits 2, not NOT_STARTED/1"
lcs badst wrap false yes --start-timeout 0
r=0; [ "$(rc badst)" = 2 ] || r=1; check $r "--start-timeout 0 exits 2"
clean_sessions; FAKE_DECOY_PID=$PPID lcs decoy wrap false yes --start-timeout 5
r=0; [ "$(rc decoy)" = 0 ] && grep -q 'session=s-test' "$TMP/decoy.out" && ! grep -q 's-decoy' "$TMP/decoy.out" || r=1
check $r "a parallel session in the same folder is not mistaken for ours (tty match)"
clean_sessions; FAKE_DRV_NOSESSION=1 FAKE_DECOY_PID=$PPID lcs onlydecoy wrap false yes --start-timeout 5
r=0; [ "$(rc onlydecoy)" = 1 ] && grep -q NOT_STARTED "$TMP/onlydecoy.out" || r=1; check $r "only someone else's session => NOT_STARTED"
r=0; RIT_WINDOW_TTY= "$BIN" --check-started "$TMP/drv.log" "$TMP/work" && r=1; check $r "--check-started without a window tty never passes (no ALREADY_SATISFIED)"

echo "== review fixes: routes =="
rm -f "$LEARNED"; lcs keep1 wrap false yes --route-info; lcs keep2 direct false yes --route-info
r=0; grep -q '"gw"' "$LEARNED" || r=1; check $r "a direct-launched run does not overwrite the learned launcher"
lcs ord outside true no --dry-run
r=0; grep -qF 'gw agent claude' "$TMP/ord.out" || r=1; check $r "outside a session: learned launcher BEFORE the login"
lcs oenv outside true yes --dry-run
r=0; grep -qF '<0600 env file>' "$TMP/oenv.out" || r=1; check $r "outside a session with route variables set: inherit them"
lcs url direct true url --dry-run
r=0; grep -qF '<0600 env file>' "$TMP/url.out" && grep -q 'localhost:4141' "$TMP/url.out" || r=1
check $r "a token-less base URL is inherited, not swapped for the login"
CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" lcs cfg direct true no --dry-run
r=0; grep -qF "export CLAUDE_CONFIG_DIR=" "$TMP/cfg.out" || r=1; check $r "CLAUDE_CONFIG_DIR is carried into the window"
FB="$TMP/fakeclaude"; mkdir -p "$FB"; printf '#!/bin/sh\necho "{\\"loggedIn\\": true}"\n' > "$FB/claude"; chmod +x "$FB/claude"
PATH="$FB:$PATH" lcs seam direct false yes --dry-run --route login
r=0; [ "$(rc seam)" = 2 ] || r=1; check $r "LCS_TEST_LOGIN_CLEAN=false wins over a logged-in claude on PATH"
lcs dash wrap false yes --dry-run --route launcher --prompt=-x -- --effort high
r=0; grep -qF 'gw agent claude -- --effort high -- "$(cat <prompt file>)"' "$TMP/dash.out" || r=1
check $r "launcher route: the prompt is separated from claude flags by --"

echo "== pre-trust (an untrusted folder stalls the session at the trust prompt) =="
mkdir -p "$TMP/w-trust" "$TMP/w-notrust" "$TMP/w-dry"
clean_sessions
( export FAKE_DRV_CWD="$TMP/w-trust"; lcs pt1 wrap false yes --cwd "$TMP/w-trust" --start-timeout 5 )
r=0; grep -q '^PRE_TRUSTED' "$TMP/pt1.out" && [ "$(trusted "$TMP/w-trust")" = True ] || r=1; check $r "the target folder is pre-trusted before the window opens"
r=0; ls "$CFG".bak.pre-trust-* > /dev/null 2>&1 || r=1; check $r "the config is backed up before the trust write"
clean_sessions; ( export FAKE_DRV_CWD="$TMP/w-trust"; lcs pt2 wrap false yes --cwd "$TMP/w-trust" --start-timeout 5 )
grep -q '^ALREADY_TRUSTED' "$TMP/pt2.out"; check $? "a trusted folder reports ALREADY_TRUSTED"
clean_sessions; ( export FAKE_DRV_CWD="$TMP/w-notrust"; lcs pt3 wrap false yes --cwd "$TMP/w-notrust" --start-timeout 5 --no-pre-trust )
r=0; [ "$(trusted "$TMP/w-notrust")" = None ] || r=1; check $r "--no-pre-trust leaves the folder untouched"
lcs pt4 wrap false yes --cwd "$TMP/w-dry" --dry-run
r=0; grep -q 'pre-trust' "$TMP/pt4.out" && [ "$(trusted "$TMP/w-dry")" = None ] || r=1; check $r "--dry-run reports the pre-trust and writes nothing"
cp "$CFG" "$CFG.good"; echo 'not json' > "$CFG"
clean_sessions; ( export FAKE_DRV_CWD="$TMP/w-dry"; lcs pt5 wrap false yes --cwd "$TMP/w-dry" --start-timeout 5 )
r=0; [ "$(rc pt5)" = 1 ] && out pt5 | grep -q -- '--no-pre-trust' && ! grep -q '^STARTED' "$TMP/pt5.out" || r=1
check $r "a failed trust write stops before the window, naming --no-pre-trust"
mv "$CFG.good" "$CFG"

echo
echo "launch-claude-session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
