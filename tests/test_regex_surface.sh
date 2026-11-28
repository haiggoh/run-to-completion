#!/usr/bin/env bash
# tests/test_regex_surface.sh — the "regex" EXTRA version surface: a version that lives in SOURCE
# code (Python `__version__ = "x"`, `VERSION = "x"`, any language), declared with a pattern holding
# exactly ONE capture group that must match exactly ONCE. Fixture mirrors joyia-keyswitch: a plain
# repo ("manifest": "", no version file) whose only version surface besides the CHANGELOG is
# keyswitch/__init__.py — with a DECOY in the same file (MIN_CONFIG_VERSION = "0.1.0") that a
# scope-blind "first version-looking string" rewrite would clobber.
#
# Cases: resolver read; bump writes the regex surface byte-exactly, leaves the decoy, and works
# with an EMPTY manifest (plain repo); gate passes after the bump; gate fails naming the file on a
# hand-split; a pattern matching TWICE fails loudly (never picks one); a pattern matching NOTHING
# fails; a pattern without exactly one group, an invalid regex, and a missing pattern are refused
# at load time.
# Rig: tests/lib/rehearsal.sh (sourced; the same is/has/summary idiom as the sibling suites).
#
# Usage: bash tests/test_regex_surface.sh [--help]
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) echo "test_regex_surface.sh: unknown argument $1" >&2; exit 2 ;;
esac
export LC_ALL=C
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
. "$HERE/lib/rehearsal.sh"
RESOLVER="$ROOT/bin/rtc_version_surface.py"

PAT='^__version__ = \"([^\"]+)\"$'
SURFACES="[{\"path\":\"keyswitch/__init__.py\",\"kind\":\"regex\",\"pattern\":\"$PAT\"}]"

init_py() {  # init_py <version> — the module the bump must produce, byte-for-byte
  printf '"""Per-app key failover."""\n\n__version__ = "%s"\n# decoy: same shape, different name — must never be rewritten\nMIN_CONFIG_VERSION = "0.1.0"\n' "$1"
}

mkfx() {  # mkfx <dir> — the keyswitch-shaped plain repo at 0.1.0
  local d=$1
  mkdir -p "$d/keyswitch"
  init_py 0.1.0 > "$d/keyswitch/__init__.py"
  printf '# Changelog\n\n## 0.1.0 — 2026-11-25\n\nx\n' > "$d/CHANGELOG.md"
  cat > "$d/rtc-ship.json" <<JSON
{
  "tag_prefix": "v",
  "default_branch": "main",
  "manifest": "",
  "changelog": "CHANGELOG.md",
  "extra_version_surfaces": $SURFACES
}
JSON
}

echo "== the resolver reads the regex surface =="
D="$TMP/fx1"; mkfx "$D"
out=$(python3 "$RESOLVER" read "$D" "$SURFACES"); rc=$?
is "resolver read exits 0" "0" "$rc"
is "  path and version, tab-separated" "keyswitch/__init__.py	0.1.0" "$out"

echo "== bump on a PLAIN repo (empty manifest) writes the regex surface and leaves the decoy =="
D="$TMP/fx2"; mkfx "$D"
bash "$ROOT/bin/rtc-ship.sh" --bump-versions "$D" 0.2.0 >"$D/bump.out" 2>&1; rc=$?
is "bump exits 0 with \"manifest\": \"\"" "0" "$rc"
is "  __init__.py byte-exact at 0.2.0, decoy untouched" "$(init_py 0.2.0)" "$(cat "$D/keyswitch/__init__.py")"
has "  changelog got a 0.2.0 entry" "$(cat "$D/CHANGELOG.md")" "## 0.2.0"
bash "$ROOT/bin/rtc-ship.sh" --versions-only "$D" >"$D/gate.out" 2>&1; rc=$?
is "gate passes after the bump" "0" "$rc"
has "  gate lists the regex surface" "$(cat "$D/gate.out")" "keyswitch/__init__.py : 0.2.0"

echo "== a hand-split regex surface fails the gate, naming the file =="
D="$TMP/fx3"; mkfx "$D"
init_py 0.0.9 > "$D/keyswitch/__init__.py"
bash "$ROOT/bin/rtc-ship.sh" --versions-only "$D" >"$D/gate.out" 2>&1; rc=$?
is "gate exits non-zero on the split" "1" "$rc"
has "  names the file and both versions" "$(cat "$D/gate.out")" "keyswitch/__init__.py says 0.0.9"

echo "== ambiguity and absence fail loudly =="
D="$TMP/fx4"; mkfx "$D"
printf '__version__ = "0.1.0"\n__version__ = "0.1.0"\n' > "$D/keyswitch/__init__.py"
err=$(python3 "$RESOLVER" read "$D" "$SURFACES" 2>&1); rc=$?
is "a pattern matching TWICE exits non-zero" "1" "$rc"
has "  says it matched 2 times" "$err" "2 times"
printf 'nothing here\n' > "$D/keyswitch/__init__.py"
err=$(python3 "$RESOLVER" read "$D" "$SURFACES" 2>&1); rc=$?
is "a pattern matching NOTHING exits non-zero" "1" "$rc"
has "  says it matched nothing" "$err" "matches nothing"

echo "== malformed declarations are refused before anything is read =="
D="$TMP/fx5"; mkfx "$D"
err=$(python3 "$RESOLVER" read "$D" '[{"path":"keyswitch/__init__.py","kind":"regex","pattern":"__version__ = \"[^\"]+\""}]' 2>&1); rc=$?
is "a pattern with NO capture group exits non-zero" "1" "$rc"
has "  says it needs exactly one group" "$err" "exactly one capture group"
err=$(python3 "$RESOLVER" read "$D" '[{"path":"keyswitch/__init__.py","kind":"regex","pattern":"(a)(b)"}]' 2>&1); rc=$?
is "a pattern with TWO groups exits non-zero" "1" "$rc"
err=$(python3 "$RESOLVER" read "$D" '[{"path":"keyswitch/__init__.py","kind":"regex","pattern":"(unclosed"}]' 2>&1); rc=$?
is "an invalid regex exits non-zero" "1" "$rc"
has "  says the pattern is invalid" "$err" "invalid pattern"
err=$(python3 "$RESOLVER" read "$D" '[{"path":"keyswitch/__init__.py","kind":"regex"}]' 2>&1); rc=$?
is "a regex surface with no pattern exits non-zero" "1" "$rc"
has "  says pattern is required" "$err" "needs \"pattern\""

summary
