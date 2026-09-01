---
name: execute-unattended
description: 'Use DURING an unattended run, once triage has produced a do-now pile: keep moving without stopping between items, switch away the instant something needs a human, protect against irreversible edits before touching a file, and carry each shippable change through to confirmed-live. Do NOT use for choosing what to work on (triage-for-autonomy) or for the closing reconciliation (close-out-the-run).'
---

# execute-unattended — keep moving, stop only for gates

This is the execution engine. Your goal is momentum: do not stop between items, and do not half-do anything. Momentum means not pausing to *report* or to ask about routine next steps — it does not mean skipping the confirmations described under "What autonomy does not relax" below. Those are the one class of stop that stays.

## Wrap-and-switch

The moment an item turns out to need user input, stop that item immediately. Move to the next Tier 1 item. Do not wait and do not idle: an unattended run has nobody to answer, so a question asked mid-run buys nothing and costs the rest of the queue. Carry the question to the closing wrap instead, where it becomes a gated-list entry the user can answer in one pass.

When you stop, do three things, not one:

1. **Retier the item in the store**, not just in your notes. A gate you only mention in the wrap is gone as soon as the wrap scrolls past; the store is what the next run reads. If the tracker has a blocked state, set it.
2. **Record the gate reason** — the specific question, not "needs input".
3. **Name the partial progress in that reason.** State what is already done and what the next run should therefore *not* redo. Without this the next run cannot tell a fresh item from a half-finished one, so it starts over — and the first half is paid for twice.

## Work up to a known gate on purpose

Wrap-and-switch above is *reactive*: it fires when an item turns out to need a human. Make it **anticipatory** too. When you can already see that an item ends at a gate, do not skip the item — deliberately do the part that sits **before** the gate, then stop there and record it.

This is the standard move, not an exception squeezed under granularity. Most gated items are not gated end to end; they are a stretch of ordinary work followed by one question. Skipping the whole item because it *finishes* at a question leaves real, autonomous progress on the table, and it is progress nobody else is going to make while the user is away.

The corollary is worth stating plainly: **a known question is a gate, and actionable work sitting before that question is actionable.** Judge an item by where its first blocker is, not by whether it has one.

## Strategic granularity

Split an item into finer sub-tasks only where splitting avoids a stall on something a human must answer. Splitting everything is overhead. Keep tasks atomic enough to verify, but coarse enough to move fast.

## Re-poll the self-releasing blocks after each item

Some blocked items are not waiting on a *person* at all — they are waiting on **another item in the queue** reaching a milestone. Those release themselves, for free, the moment their target lands. So every time you finish an item, check whether finishing it unblocked anything, and pull whatever it released into the pile.

This costs one lookup per completed item and it is the difference between clearing a chain and clearing one link. If the tracker distinguishes this state (a `waiting` tier with a recorded target, rather than prose in a gate reason) the check is mechanical; if it does not, the dependency is buried in text and you will miss the cascade.

Do **not** treat these as questions for the closing wrap. Nothing is owed by the user, so listing them among the things awaiting an answer inflates the pile they think they have to work through.

## Adapt empirically

When the workflow hits friction, adjust in real time rather than stopping. Capture the lesson where your durable notes live so the next run starts better. Do not let friction break the loop.

## Reversibility before any file edit

Apply this rule before touching any file:

- **Tracked by version control and working tree is clean:** Rely on version control. No backup needed.
- **Untracked, uncommitted, or outside version control:** Take a timestamped copy first.
- **Never clobber uncommitted changes you did not make.** They may be a human’s work in progress.

## The ship loop

For any change to a repository or published artifact, follow this ordered list:

1. Verify the change does what it claims.
2. Bump the artifact’s version.
3. Commit.
4. Push.
5. Reinstall or otherwise refresh the consumed copy.
6. Confirm the change is live **in the installed copy, not just in the source tree**.

The last step matters because source and installed copies drift. A change that is only in source has not shipped.

## Milestone wraps

Emit a short status after each completed item and keep going. The wrap is for the human reading later, not a request for permission.

## Budget and resource discipline

As the resource you are spending gets scarce, prefer clean self-contained steps and lean harder on a cheaper delegate. When it is nearly exhausted, stop at a clean seam rather than being cut off mid-item.

## Delegation

Decide per step whether a cheaper delegate does it, and decide it up front rather than mid-grind — an intention to offload later reliably becomes "did it all myself". Default delegatable work to the delegate; keep a step for yourself when it needs judgement the delegate lacks, or when briefing and checking it would cost more than doing it. Verify whatever comes back against your usual verification discipline before building on it.

**Decide before you read the inputs, and watch the distribution.** If you open the material to judge whether delegating is worth it, the expensive part is already spent and delegating afterwards is theatre — so "I have already read it" means the decision came too late, not that you should keep it. And note that "needs my judgement" and "not worth the overhead" between them can excuse *every* step: each call looks fine alone, so the tell is the aggregate. If a run delegates **nothing**, that is the thing to justify, once, explicitly — not a per-step shrug.

## What autonomy does not relax

Destructive or hard-to-reverse actions still need explicit confirmation. This includes deleting data, force-pushing, publishing to a shared or public destination, or changing shared infrastructure. Get that authorization in the up-front question pass so the loop does not stall on it late.

If you reach such an action without having asked, the absence of anyone to answer is **not** permission. Treat it as a gate like any other: record it, leave the destructive step undone, and move on. An unattended run may not upgrade its own authority just because asking is inconvenient — that is the one place where "keep moving" yields.

## When NOT to use this

Do not run this way while the user is actively iterating with you turn by turn: the whole design assumes nobody is reading between items, so suppressing check-ins in a live conversation just removes their steering. Use `triage-for-autonomy` to choose what to work on, and `close-out-the-run` to reconcile when the run ends.
