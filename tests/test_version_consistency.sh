#!/usr/bin/env bash
# test_version_consistency.sh [repo-root] — every version surface of run-to-completion agrees.
#
# Surfaces: .claude-plugin/plugin.json "version" and the top CHANGELOG.md heading (both heading
# styles, `## 1.2.3` and `## [1.2.3]`). rtc-ship.sh's version gate runs this test in preference to
# the surfaces declared in rtc-ship.json. A surface that cannot be read is a FAILURE, never a pass.
#
# Arguments: [repo-root]  check that tree instead of this script's own repo (used by the known-bad
#                         case below, which runs it against a temp copy with a planted split)
# Env: RTC_VC_NO_SELFTEST=1  skip the planted-split self-test (set by the self-test's own child run)
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; -*) echo "usage: $0 [repo-root]" >&2; exit 2 ;; esac
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

mv=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version",""))' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)
cv=$(sed -n -E 's/^##+[[:space:]]+\[?([0-9]+\.[0-9]+\.[0-9]+)\]?.*/\1/p' "$ROOT/CHANGELOG.md" 2>/dev/null | head -1)
echo "  .claude-plugin/plugin.json : ${mv:-<none>}"
echo "  CHANGELOG.md (top entry)   : ${cv:-<none>}"
[ -n "$mv" ] || { echo "✖ no version in plugin.json"; exit 1; }
[ -n "$cv" ] || { echo "✖ no version heading in CHANGELOG.md"; exit 1; }
[ "$mv" = "$cv" ] || { echo "✖ plugin.json $mv ≠ CHANGELOG $cv"; exit 1; }

# Known-bad discriminant: the same check on a copy with a planted split must FAIL, or this test is
# decoration. Runs only for the repo's own tree.
if [ -z "${1:-}" ] && [ "${RTC_VC_NO_SELFTEST:-0}" != 1 ]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/.claude-plugin"; cp "$ROOT/.claude-plugin/plugin.json" "$T/.claude-plugin/"
  { echo "# Changelog"; echo; echo "## 9.9.9"; } > "$T/CHANGELOG.md"
  if RTC_VC_NO_SELFTEST=1 bash "$0" "$T" >/dev/null 2>&1; then
    echo "✖ self-test: a planted split (plugin.json $mv vs CHANGELOG 9.9.9) PASSED"; exit 1
  fi
  echo "  ok: a planted split fails"
fi
echo "✓ version surfaces agree ($mv)"
