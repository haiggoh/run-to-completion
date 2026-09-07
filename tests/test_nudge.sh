#!/usr/bin/env bash
# Framework-free tests for nudge.sh. Requires bash + jq (test-only).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/nudge.sh"

pass=0; fail=0
check() { if [ "$1" -eq 0 ]; then echo "  PASS: $2"; pass=$((pass+1)); else echo "  FAIL: $2"; fail=$((fail+1)); fi; }
ctx()    { jq -r '.hookSpecificOutput.additionalContext' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "jq required for tests"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== Case A: emits one valid JSON object with the nudge =="
OUT="$TMP/a.json"; bash "$HOOK" > "$OUT"
jq . "$OUT" >/dev/null 2>&1; check $? "valid JSON"
r=0; [ "$(jq -s 'length' "$OUT")" = "1" ] || r=1; check $r "exactly one JSON object"
case "$(ctx "$OUT")" in *"run-to-completion:"*) r=0;; *) r=1;; esac; check $r "nudge text present"
case "$(ctx "$OUT")" in *"UP FRONT"*) r=0;; *) r=1;; esac; check $r "ask-up-front instruction present"
case "$(ctx "$OUT")" in *"natural task seam"*) r=0;; *) r=1;; esac; check $r "fold-at-seam instruction present"
case "$(ctx "$OUT")" in *"destructive"*) r=0;; *) r=1;; esac; check $r "does-not-relax-destructive-confirmation caveat present"
case "$(ctx "$OUT")" in *"autopilot"*) r=0;; *) r=1;; esac; check $r "whole-queue entry point named"
case "$(ctx "$OUT")" in *"ungate-queue"*) r=0;; *) r=1;; esac; check $r "attended alternative named"

echo "== Case B: stateless — no systemMessage, no marker files written =="
r=0; [ "$(jq -r '.systemMessage // "none"' "$OUT")" = "none" ] || r=1; check $r "no user-visible banner (model-only)"
HOMEB="$TMP/home_b"; mkdir -p "$HOMEB"
HOME="$HOMEB" bash "$HOOK" >/dev/null
r=0; [ -z "$(find "$HOMEB" -type f 2>/dev/null)" ] || r=1; check $r "writes no state files"

echo "== Case C: hookEventName is SessionStart =="
[ "$(jq -r '.hookSpecificOutput.hookEventName' "$OUT")" = "SessionStart" ]; check $? "hookEventName correct"

echo "== Case D: the nudge carries the ship loop's tail, not just its middle =="
# The always-loaded surface is what a session actually reads, so a nudge that says "push" and stops
# re-teaches the exact habit the skill was extended to break. These pin the three steps past the
# push plus the reason dogfooding is not redundant with the version check before it.
case "$(ctx "$OUT")" in *"TAG it"*) r=0;; *) r=1;; esac; check $r "nudge names tagging"
case "$(ctx "$OUT")" in *"cut a RELEASE"*) r=0;; *) r=1;; esac; check $r "nudge names cutting a release"
case "$(ctx "$OUT")" in *"DOGFOOD"*) r=0;; *) r=1;; esac; check $r "nudge names dogfooding"
case "$(ctx "$OUT")" in *"version string"*) r=0;; *) r=1;; esac; check $r "nudge says a version string is not proof the feature works"
case "$(ctx "$OUT")" in *"DEPTH"*) r=0;; *) r=1;; esac; check $r "nudge asks ship-loop authorization as a depth"
# A release is conditional on purpose; an unconditional "always release" would be wrong.
case "$(ctx "$OUT")" in *"when that is how a consumer"*) r=0;; *) r=1;; esac; check $r "nudge keeps the release step conditional"

echo; echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
