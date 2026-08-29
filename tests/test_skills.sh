#!/usr/bin/env bash
# Framework-free checks on the shipped skills.
#
# Enforces the three properties that are easy to break by hand-editing a skill:
#   1. frontmatter is valid YAML, and `name` matches the directory
#   2. no OTHER plugin is named anywhere in a skill body (capability terms only),
#      and no machine-specific absolute path leaks into a published file
#   3. the ship loop lives in exactly ONE skill (execute-unattended) — it is
#      finish-discipline, and duplicating it across skills is how it drifts
#
# Requires: python3 with PyYAML (frontmatter parse). Everything else is shell.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
SKILLS="$ROOT/skills"

pass=0; fail=0
check() { if [ "$1" -eq 0 ]; then echo "  PASS: $2"; pass=$((pass+1)); else echo "  FAIL: $2"; fail=$((fail+1)); fi; }
# Print a captured multi-line grep result, indented under its check line.
indent() { while IFS= read -r line; do [ -n "$line" ] && echo "      $line"; done; }

echo "== Case A: frontmatter is valid YAML and name matches directory =="
python3 - "$SKILLS" <<'PY'
import sys, pathlib, re
try:
    import yaml
except ImportError:
    print("  SKIP: PyYAML not installed (pip install pyyaml)"); sys.exit(0)

skills = pathlib.Path(sys.argv[1])
bad = 0
for d in sorted(p for p in skills.iterdir() if p.is_dir()):
    f = d / "SKILL.md"
    if not f.exists():
        print(f"  FAIL: {d.name} has no SKILL.md"); bad += 1; continue
    text = f.read_text()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        print(f"  FAIL: {d.name} has no frontmatter block"); bad += 1; continue
    try:
        meta = yaml.safe_load(m.group(1))
    except Exception as e:
        print(f"  FAIL: {d.name} frontmatter does not parse: {e}"); bad += 1; continue
    if not isinstance(meta, dict):
        print(f"  FAIL: {d.name} frontmatter is not a mapping"); bad += 1; continue
    if meta.get("name") != d.name:
        print(f"  FAIL: {d.name} name field is {meta.get('name')!r}"); bad += 1; continue
    desc = meta.get("description")
    if not isinstance(desc, str) or not (80 <= len(desc) <= 1200):
        print(f"  FAIL: {d.name} description missing or implausible length"); bad += 1; continue
    print(f"  PASS: {d.name} ({len(desc)} char description)")
sys.exit(1 if bad else 0)
PY
r=$?
check $r "all skills have valid frontmatter with matching name"

echo "== Case B: no other plugin named, no machine-specific paths =="
# Capability terms only. This plugin must work with none of these installed, so it
# must not name them; see the independence section of the README.
FOREIGN='get-haiggoh|local-agents|brief-agents|audit-loose-ends|no-hidden-changes|resume-interrupted|measure-twice|mcp-smoke-test|task-observer|superpowers'
hits="$(grep -rniE "$FOREIGN" "$SKILLS" 2>/dev/null)"
r=0; [ -z "$hits" ] || r=1; check $r "no foreign plugin names in skills/"
[ -n "$hits" ] && indent <<<"$hits"

paths="$(grep -rnE '/Users/|/home/[a-z]|~/\.claude/' "$SKILLS" 2>/dev/null)"
r=0; [ -z "$paths" ] || r=1; check $r "no machine-specific absolute paths in skills/"
[ -n "$paths" ] && indent <<<"$paths"

echo "== Case C: the ship loop lives only in execute-unattended =="
# Concept-grepped with several precise patterns rather than one loose word: a
# single broad term ("reinstall") manufactures false positives on unrelated prose.
SHIP='version bump|bump the version|bump its version|git commit|git push|installed cache|installed copy|marketplace'
strays=0
for f in "$SKILLS"/*/SKILL.md; do
  name="$(basename "$(dirname "$f")")"
  [ "$name" = "execute-unattended" ] && continue
  h="$(grep -niE "$SHIP" "$f" 2>/dev/null)"
  if [ -n "$h" ]; then
    echo "      $name: $h"; strays=$((strays+1))
  fi
done
r=0; [ "$strays" -eq 0 ] || r=1; check $r "ship-loop content confined to execute-unattended"
r=0; grep -qiE 'installed copy|installed cache' "$SKILLS/execute-unattended/SKILL.md" 2>/dev/null || r=1
check $r "execute-unattended does carry the confirm-live step"

echo "== Case D: every skill declares when NOT to use it =="
missing=0
for f in "$SKILLS"/*/SKILL.md; do
  # Accept any explicit scope-bounding section or clause; the original skill uses
  # "When NOT to apply", the phase skills use "When NOT to use this".
  grep -qiE 'when NOT to (use|apply)|Do NOT use|Do not trigger' "$f" || { echo "      $(basename "$(dirname "$f")")"; missing=$((missing+1)); }
done
r=0; [ "$missing" -eq 0 ] || r=1; check $r "all skills bound their own scope"

echo "== Case E: ungate-queue stays narrow, and the gated tiers agree across skills =="
# The whole point of v0.3.0 is that this pass removes a gate and STOPS. These greps
# fail if a future edit quietly restores "act immediately" behaviour, or if the tier
# vocabulary drifts apart between the pass that writes it and the triage that reads it.
UQ="$SKILLS/ungate-queue/SKILL.md"
TR="$SKILLS/triage-for-autonomy/SKILL.md"

r=0; grep -qiE 'record and return|removing the gate is the whole job|STOPS there' "$UQ" || r=1
check $r "ungate-queue states the record-and-return boundary"

r=0; grep -qiE 'first gate is yours|Only the FIRST gate' "$UQ" || r=1
check $r "ungate-queue limits itself to the first gate"

# An earlier revision told this skill to do the work in the same sitting. That
# instruction is the regression this case exists to catch.
stray="$(grep -niE 'convert answers into progress in the same sitting|either do it now' "$UQ")"
r=0; [ -z "$stray" ] || r=1; check $r "ungate-queue no longer tells you to do the work"
[ -n "$stray" ] && indent <<<"$stray"

# Tier vocabulary must exist in BOTH files, or one side writes markers the other cannot read.
missing=""
for tier in G1 G2 G3 G4 ENV; do
  grep -q "$tier" "$UQ" || missing="$missing ungate-queue:$tier"
  grep -q "$tier" "$TR" || missing="$missing triage:$tier"
done
r=0; [ -z "$missing" ] || r=1; check $r "ungate tiers G1-G4 and ENV appear in both skills"
[ -n "$missing" ] && echo "      missing:$missing"

r=0; grep -qiE 'not equally gated|cheapest first|cheapest-to-release' "$TR" || r=1
check $r "triage ranks the gated pile rather than treating it as flat"

r=0; grep -qiE 'read the stored tier|read it and move on|Re-judge only when' "$TR" || r=1
check $r "triage reads a persisted tier instead of re-deriving it"

# The tier must ride in the queue's EXISTING gate-reason field: a second store of
# gate state is the failure mode this wording guards against.
r=0; grep -qiE 'field the queue already has|gate reason the queue already stores' "$UQ" "$TR" || r=1
check $r "the tier is stored in the existing gate-reason field, not a parallel record"

echo; echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
