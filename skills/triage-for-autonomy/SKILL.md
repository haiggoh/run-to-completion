---
name: triage-for-autonomy
description: 'Use BEFORE starting an unattended run, to score an existing queue of open items — a to-do list, an issue tracker, plan steps, or a persistent open-items store — into what is safe to do now, what is autonomous but heavy, and what is gated on a human. Produces a tier verdict plus a gate reason per item. Do NOT use for executing the items (execute-unattended), for the closing wrap (close-out-the-run), or for walking gated items with the user present (ungate-queue).'
---

# triage-for-autonomy — score the queue before you touch it

Selection is what makes unattended work safe. The failure mode of autonomous execution is not incompetence; it is taste-dependent guesses made while nobody is watching. This skill prevents that by forcing an explicit, recorded verdict on every item before execution begins — so that nothing gets attempted by default.

## The three scoring axes

Apply these three filters to every item in your queue. An item must pass **all three** to be Tier 1.

1. **Not gated on a human:** Does this require user input, a supervised interactive session, a download, or a fresh session state? If yes, it is gated.
2. **Objective decision or spelled-out plan:** Is the outcome defined by objective criteria (a bug fix, a known-correct doc update, a written test procedure)? If it requires design taste, methodology choice, or creative judgment, it is not objective.
3. **Verifiable by observable outcome:** Can you prove it is done by checking a diff, a test result, or a file state? If success is subjective or internal, it is not verifiable.

## The three tiers

Bucket items based on the axes above.

- **Tier 1 — do now:** Fully autonomous, objective, bounded, and verifiable. Examples: documentation fixes with known-correct outcomes, clear bug fixes, test procedures already written out, read-only investigations, and objectively-closeable items.
- **Tier 2 — autonomous but heavy:** Delegatable but liable to sprawl. Examples: benchmarks, research, and measurement tasks. Do these only when Tier 1 is exhausted and budget remains.
- **Gated — do not start:** Needs user input, a supervised session, a download, is a design/taste decision, or needs fresh session state.

## Gate reason is a required output

For every gated item, record **which category blocks it**. This is not a note; it is a required field. The gate reason is what makes the closing wrap and any subsequent unblocking pass nearly free. Without it, you must re-analyze the item later to understand why it stopped.

## Reading the queue

Read the queue through its documented list interface. Do not parse its storage format directly. This ensures your triage does not break when the store’s internal structure changes.

## Ordering and re-triage

Set priority on only the top few Tier 1 picks. Strategic, not bulk. Re-ranking everything is churn. Re-triage is cheap: re-rank after finishing a batch rather than committing to one order up front. New information changes tiers.

## Worked example

| Item | Tier | Gate Reason |
| :--- | :--- | :--- |
| Fix typo in README | Tier 1 | None |
| Refactor auth module | Gated | Design/taste decision |
| Run benchmark suite | Tier 2 | None (heavy) |
| Download dataset X | Gated | Needs download |
| Close issue #42 | Tier 1 | None |

## When NOT to use this

Skip triage entirely for a single task, or a queue of one: there is nothing to rank, and scoring it is pure overhead. Skip it too when the user has already named the item they want done — they have made the selection, and re-deriving it is second-guessing rather than triage.

Then: use `execute-unattended` to run the Tier 1 items, `close-out-the-run` to reconcile when the run ends, and `ungate-queue` to walk gated items with the user present.
