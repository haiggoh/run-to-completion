---
name: autopilot
description: 'Use when the user asks to run a whole queue of open work unattended — "autopilot", "run everything you can", "clear what you can while I am away", "full auto on my open items". Orchestrates the complete run as an explicit checklist: triage the queue into tiers, execute the autonomous pile without stopping, then close out with a gated list. Start here rather than at an individual phase when the request covers the whole run.'
---

# autopilot — the entry point for a whole unattended run

This skill orchestrates the complete run. It sequences three phase skills and adds the up-front kickoff. It does not duplicate their content.

## Kickoff

Do this once before triage:

1. **Establish the resource picture.** Find out what you actually have to spend — time, a request or token quota, a cost cap if one exists at all — by checking, not by assuming. Many setups have no cap, and in those the answer is simply "no limit to plan around". Never conclude you are blocked without looking: if the user's prompts are being answered, the pipe is working.
2. **Warm any delegate.** Start any local-execution capability in the background so the first delegation is not a cold start. Capture whatever address or port the warm-up reports.
3. **Ask blocking questions NOW.** Ask every genuinely blocking, matter-of-taste question, including permission for any push, publish, or confirmation-gated action. Do not stop for them again.

## The checklist

Create one tracked todo per phase, in order:
1. Triage (`triage-for-autonomy`)
2. Execute (`execute-unattended`)
3. Close out (`close-out-the-run`)

Work them in sequence. The checklist form matters because an orchestrator can only instruct, not force. A written checklist is what makes the sequence hold across a long run.

## The loop

After finishing a batch, re-triage rather than following the original order blindly. New information changes tiers.

## Hand-offs

If a persistent open-items store exists, that is the queue. If a local-execution capability exists, route delegatable steps to it. If a reconciliation discipline exists, the closing phase uses it. None of these are required for autopilot to work.

## Attended alternative

If the user is available and wants to clear blockers rather than have work done unattended, that is `ungate-queue`, not this.

## When NOT to use this

Use `triage-for-autonomy`, `execute-unattended`, or `close-out-the-run` directly if you are already in a specific phase.
