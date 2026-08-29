---
name: ungate-queue
description: 'Use when the user wants to work THROUGH the blocked items on a queue with you present — "unblock these", "walk me through what is gated", "let us clear the questions" — or immediately after an unattended run reports items it could not do. Turns each gate reason into the single question that would release the item, records the answer on the item, and STOPS there: removing the gate is the whole job, and the work it releases belongs to a later unattended run. Do NOT use for unattended execution (autopilot, execute-unattended), and do NOT slide into doing the work you just unblocked.'
---

# ungate-queue — remove the gate, then stop

An unattended run produces two piles. The autonomous pile gets done without the user. This skill is the other half: the gated pile, walked WITH the user. The user's presence is the whole premise, so nothing here is deferred or guessed.

This pass spends **user attention**, not compute. That is what makes it the right pass to run when compute is scarce or expensive — but only while it stays cheap. The moment it starts doing the work it unblocked, it costs both, and the property that made it worth running is gone.

## The boundary: record and return

Your output is a **changed gate state**, not a changed repository. For each item: ask, record the answer on the item, retier it, move to the next one. Then hand the released pile to a later unattended run.

Concretely, per item you are done when:

1. The answer is **written onto the item itself**, in enough detail that a fresh session could act on it without you in the room.
2. The item's verdict is **updated** through the queue's own interface — no longer gated, or still gated with a smaller reason.
3. You have **moved on**.

You are NOT done-and-continuing. Do not open the files. Do not start the fix "while we are here". If an item is one line of work and the temptation is strong, that is exactly the case to resist: releasing thirty gates in one attended sitting is worth far more than releasing four and fixing one.

**Only the FIRST gate is yours.** An item often has a second blocker behind the first. Remove the one in front, record what is now known about the next, and let the item come back around. Chasing a chain to its end turns one question into a project.

## Rank the gated pile by how cheaply it can be released

Gated is not one flat bucket. Items differ enormously in what an answer buys, so present the cheapest-to-release first. Ask in this order:

- **G1 — one answer, gone forever.** A single answered question removes the gate permanently. Highest value per unit of attention. These are what this pass exists for; ask them first, always.
- **G2 — an installation something already does.** The gate is a setup step an existing script or documented command already performs, so it costs little or nothing to clear. Still cheap, still good.
- **G3 — a custom installation.** Clearing it needs real work: trying approaches, testing, iterating. Genuinely harder, so it must not crowd out G1 and G2. Surface it after them.
- **G4 — not an ungating candidate at all.** The gate is constant multi-step user interaction *while the task runs*. There is no answer that releases it into autonomy; the task simply has to be done attended. Keep these at the back and raise them only if the user explicitly asks. Naming one as attended work is a complete result.
- **ENV — a recurring precondition, not a failure.** An external condition that will be true sometimes and false at other times: an application must be running, a particular network must be joined, a device must be plugged in. These can never be *permanently* removed and must not be reasoned about as though they could be. Mark them once as recurring, and thereafter the only question is "is the condition true right now?" — never "how do we solve this?".

## G5 — already released, with a gate expected later

A distinct state worth naming: **not gated now**, but a known gate is expected before an unattended run could finish it.

Treat it as **ungated**. If real work can proceed before the new gate bites, partial release is progress: promote it into the ordinary actionable queue with a note saying where it will stop. Do not hold an item back because it cannot be finished — that reasoning keeps genuinely available work out of every run.

Note that a well-built queue will **refuse** to store a gate reason on an item it is not calling gated, and it is right to: that record would disagree with itself. So the expected-later gate goes in the item's notes or summary, not in its gate-reason field.

## Persist the tier — judge each item once

Write the ungate tier onto the item as you touch it, as a short leading marker on the recorded gate reason:

```
G1: needs one decision — which of the two output formats
G2: needs the bundled setup command run once
G3: needs a custom launcher built and tested
G4: needs you driving a GUI throughout
ENV: needs that application running (recurring, not solvable)
```

This is deliberately **plain text inside the field the queue already has**. It adds no field to anyone's store, it survives the queue changing underneath you, and any view that prints a gate reason shows the tier for free. Do not build a second record of gate state somewhere else; two records of the same thing will disagree.

The payoff is that scoring becomes one-time rather than per-run: a later triage **reads** the marker instead of re-deriving it, and only re-judges an item that actually changed. An ENV marker in particular means nobody ever re-reasons a recurring precondition as if it were a bug.

## Map gate reasons to questions

For each item, work out the single smallest question whose answer releases it, and ask that. Not a status report. Not a list of considerations. The one question.

- **Needs user input:** Ask for the specific missing value or decision. Provide a recommended default.
- **Design or taste decision:** Offer two or three concrete options with trade-offs. State your recommendation first.
- **Needs a supervised interactive session:** Ask whether it is wanted and record the answer. Say what such a session would do — then leave it to be scheduled, rather than starting it inside this pass.
- **Needs a download or external fetch:** Confirm it is wanted. State its cost or size.
- **Needs a fresh session state:** Say what state is in the way and what the clean start buys.
- **Recurring precondition:** Ask only whether the condition holds now, and mark it ENV so it is never re-litigated.

## Batch by cheapness

Within a tier, ask the questions that are one word to answer first. Momentum matters in an attended pass, and a run of quick answers is what keeps the user in it.

## Respect a non-answer

"Skip that one" is a valid answer. Record it and move on. Do not re-ask in the same pass.

## Any queue

This works on any queue, including one this skill did not create. It needs only an item and a reason it is blocked. If no reason was recorded, deriving it is the first step — and an item with no recorded reason is its own group, because the missing reason is itself the defect.

## Close the pass, do not extend it

End with the ledger, not with work: which items are released and now rankable, which stayed gated and on a smaller reason, which are attended-only, which are waiting on a recurring condition. Then say plainly that the released pile is ready for an unattended run.

## When NOT to use this

Do not start this pass when the user is away or has just asked for work to be done unattended — the whole method is asking questions, so without someone to answer it degrades into a list of things you decided not to do. That case is `autopilot` (or `execute-unattended` if a run is already under way). Do not use it to score a queue either: deciding what is gated is `triage-for-autonomy`; this skill starts from that verdict and refines it. And do not use it as a way into the work itself — an item released here is handed on, never carried forward in the same breath.
