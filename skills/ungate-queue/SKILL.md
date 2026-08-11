---
name: ungate-queue
description: 'Use when the user wants to work THROUGH the blocked items on a queue with you present — "unblock these", "walk me through what is gated", "let us clear the questions" — or immediately after an unattended run reports items it could not do. Turns each gate reason into the single question that would release the item, one at a time. Do NOT use for unattended execution (autopilot, execute-unattended); this skill exists precisely because the user IS available.'
---

# ungate-queue — walk the gated pile with the user

An unattended run produces two piles. The autonomous pile gets done without the user. This skill is the other half: the gated pile, walked WITH the user. The user’s presence is the whole premise, so nothing here is deferred or guessed.

## One question per item

For each gated item, work out the single smallest question whose answer releases it, and ask that. Not a status report. Not a list of considerations. The one question.

## Map gate reasons to questions

Use this mapping to derive the question:

- **Needs user input:** Ask for the specific missing value or decision. Provide a recommended default.
- **Design or taste decision:** Offer two or three concrete options with trade-offs. State your recommendation first.
- **Needs a supervised interactive session:** Offer to start it now. Say what you will do in it.
- **Needs a download or external fetch:** Confirm it is wanted. State its cost or size.
- **Needs a fresh session state:** Say what state is in the way and what the clean start buys.

## Act immediately

The point is to convert answers into progress in the same sitting. Where the answer makes an item Tier 1, either do it now or record it as ready so an unattended run can take it.

## Batch by cheapness

Ask the questions that are one word to answer first. Momentum matters in an attended pass.

## Respect a non-answer

"Skip that one" is a valid answer. Record it and move on. Do not re-ask in the same pass.

## Any queue

This works on any queue, including one this skill did not create. It needs only an item and a reason it is blocked. If no reason was recorded, deriving it is the first step.

## When NOT to use this

Do not start this pass when the user is away or has just asked for work to be done unattended — the whole method is asking questions, so without someone to answer it degrades into a list of things you decided not to do. That case is `autopilot` (or `execute-unattended` if a run is already under way). Do not use it to score a queue either: deciding what is gated is `triage-for-autonomy`; this skill starts from that verdict.
