#!/usr/bin/env bash
# Tests for hooks/check-tag-visibility.py — the shipping loop's tag-visibility fallback.
# Network-free: --self-test asserts the diagnosis taxonomy and tag parsing; the usage and
# exit-code contract is checked against a stubbed URL argument shape.
set -uo pipefail
export LC_ALL=C

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/hooks/check-tag-visibility.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

echo "check-tag-visibility.py"

out="$(python3 "$SCRIPT" --self-test 2>&1)"
case "$out" in
  *"self-test OK"*) ok "the diagnosis taxonomy self-test holds" ;;
  *) bad "the diagnosis taxonomy self-test holds" "$out" ;;
esac

python3 "$SCRIPT" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then
  ok "no arguments is a usage error (exit 2)"
else
  bad "no arguments is a usage error (exit 2)" "exit 2"
fi

python3 "$SCRIPT" only-one-argument >/dev/null 2>&1
if [ "$?" -eq 2 ]; then
  ok "one argument is a usage error (exit 2)"
else
  bad "one argument is a usage error (exit 2)" "exit 2"
fi

# The github.com -> raw.githubusercontent conversion must produce a fetchable URL shape.
conv="$(python3 - "$SCRIPT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ctv", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(mod.manifest_url_for("https://github.com/haiggoh/free-agents.git"))
PY
)"
case "$conv" in
  https://raw.githubusercontent.com/haiggoh/free-agents/HEAD/.claude-plugin/plugin.json)
    ok "the git->raw manifest URL conversion is correct" ;;
  *) bad "the git->raw manifest URL conversion is correct" "$conv" ;;
esac

printf 'passed %s, failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
