#!/usr/bin/env bash
# run-to-completion — SessionStart hook.
#
# Stateless: emits ONE JSON object carrying a one-line, MODEL-ONLY nudge
# (hookSpecificOutput.additionalContext). No markers, no reconciliation, no
# user-visible banner — purely REACTIVE, meant to fire the skill at the moment
# an elaborate multi-step task or an explicit autonomy request comes up.
#
# Pure bash (3.2-compatible); no jq/python dependency at runtime.

set -uo pipefail

# --- pure-bash JSON string escaper (bash 3.2 verified) ---
json_escape() {
  local s=$1
  s=${s//\\/\\\\}    # backslash -> \\  (MUST run first)
  s=${s//\"/\\\"}    # "         -> \"
  s=${s//$'\n'/\\n}  # newline   -> \n
  s=${s//$'\t'/\\t}  # tab       -> \t
  s=${s//$'\r'/\\r}  # CR        -> \r
  printf '%s' "$s"
}

NUDGE="run-to-completion: when facing an elaborate multi-step plan or several open projects AND you've reached a phase where you have most of the info you need, OR the user says 'autonomous' / 'continuous' / 'full auto' / 'run to completion' — proactively OFFER to execute continuously and autonomously: no stopping between steps. If they take that mode: ask any genuinely blocking, matter-of-taste questions UP FRONT, then proceed; fold any prompts you would otherwise send mid-run into the next natural task seam instead of stopping; reserve mid-run stops for decisions that truly can't be weighed with pros and cons (otherwise decide and note it). This does NOT relax the separate rule about confirming destructive or hard-to-reverse actions (deletes, force-pushes, publishing) — autonomy covers routine step-by-step continuation, not skipping those checks. If the request covers a whole standing QUEUE of open items to clear unattended (rather than a plan already in view in this conversation), start at the 'autopilot' skill, which sequences triage-for-autonomy then execute-unattended then close-out-the-run as an explicit checklist. If instead the user is present and wants to clear the BLOCKED items, that is 'ungate-queue'."

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
  "$(json_escape "$NUDGE")"
