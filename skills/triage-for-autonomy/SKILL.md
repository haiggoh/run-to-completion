---
name: triage-for-autonomy
description: 'Use BEFORE starting an unattended run, to score an existing queue of open items — a to-do list, an issue tracker, plan steps, or a persistent open-items store — into what is safe to do now, what is autonomous but heavy, and what is gated on a human. Produces a tier verdict plus a gate reason per item, and ranks the gated pile by how cheaply each item could be released so an attended pass asks the best questions first. Do NOT use for executing the items (execute-unattended), for the closing wrap (close-out-the-run), or for walking gated items with the user present (ungate-queue).'
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
- **Gated — do not start:** Needs user input, a supervised session, a download, is a design/taste decision, or needs fresh session state. Gated is a *destination for this run*, not a permanent verdict — see below.

## Gate reason is a required output

For every gated item, record **which category blocks it**. This is not a note; it is a required field. The gate reason is what makes the closing wrap and any subsequent unblocking pass nearly free. Without it, you must re-analyze the item later to understand why it stopped.

## Gated items are not equally gated

Do not leave the gated pile as one flat bucket. Two items can both be blocked while one needs a single yes/no and the other needs a human present for every step of the work. Sorting the gated pile by **how cheaply it can be released** is what lets an attended pass ask the highest-value questions first instead of walking the list in arbitrary order.

Sort gated items into these, cheapest first:

- **G1** — one answered question removes the gate permanently.
- **G2** — the gate is a setup step an existing script or documented command already performs.
- **G3** — the gate needs a custom installation: real work, tried and tested.
- **G4** — no answer releases it; it needs a human interacting throughout, so it is attended work, not an ungating candidate.
- **ENV** — a recurring external precondition (an application running, a network joined, a device attached). Never permanently removable, so never re-reasoned as if it were.
- **WAIT** — blocked on **another item in this same queue** reaching a milestone. Not a question for anyone: it releases itself when its target lands. Record the target *and the milestone* — "when that item is done" is frequently not the trigger, because what you are waiting for is often a specific point partway through. If the tracker has a dedicated state for this, use it rather than prose in a gate reason: a target it can re-check is a mechanism, whereas the same fact in prose is a note nobody re-reads.
- **EXT** — blocked on an external party (a vendor, an upstream project, an unreleased version). **This marker must be EARNED.** "Blocked on a third party" is a conclusion, not an observation, and it decays: attach a recorded note of the options *we* control and why each fails — re-test the blocker, stop depending on the broken part, work around it locally, fork or patch, file a PR, file a bug report. Filing is an active step, not waiting. Without that note EXT is where items go to die: a single stale line from months ago keeps an item parked long after the real fix became ours.

### Two distinctions that remove items from the gated pile for free

**Scheduled is not blocked.** An item waiting only for a *date* to come round is not gated: when the date arrives the work is fully autonomous and nobody is needed. Model it as ordinary work with a future surface date, not as a gate. This needs no new mechanism and it shrinks the pile the user thinks they owe answers on.

**Split ENV detection by check cost.** A recurring precondition readable from local state — a process running, an uptime, a log line, a file present — costs nothing to check, so it may be checked automatically every run. A precondition that needs an **outbound network call** (has an upstream release landed?) must never be automatic or per-run: that is real spend for an almost-always-negative answer. Put those on a slow calendar cadence instead. Concretely: do not build a release-poller.

An item that is **not gated now but expects a gate later** is not in this list at all. Score it as an ordinary do-now or heavy item and note where it will stop. Real work that can proceed before the later gate is real work; withholding it keeps available items out of every run.

## Read the stored tier — do not re-derive it

This scoring is the one part of triage that cannot be reduced to a script, so it is the part worth paying for exactly once. If an item already carries a recorded ungate tier, **read it** and move on. Re-judge only when the item itself changed. An ENV marker is permanent by definition: seeing it, you are finished with that item.

Judgment is unavoidable for a newly-triaged or newly-changed item. Spend it there and nowhere else. Keep the sort simple — a rough cheapest-first ordering that is right about G1-before-G3 is worth far more than a precise one you re-derive on every run.

## Tier dominates, priority breaks ties

Ordering across tiers is settled by tier: do-now before heavy, and within gated, G1 before G2 before G3 before G4. WAIT items sort with neither group — see below. An item's ordinary priority still matters, but only **within** a tier. A high-priority G3 does not jump ahead of a G1 — the whole point of the sort is that the cheap release comes first regardless of how much the expensive one matters.

## A self-releasing block is its own category, not a gate

Keep WAIT items **separate from both** the actionable pile and the human-gated pile, and say so in the verdict. They cannot be started now, so they are not actionable; but nobody is needed, so filing them with the questions tells the user they owe answers they do not owe. On a real queue this was not a small effect: 15 of 26 blocked items turned out to be waiting on other queue items, so separating them cut the apparent question-pile by more than half.

They also want re-polling every batch rather than once at triage, because each completed item may release one. That is the execution phase's job, but the *verdict* has to mark them for it.

## A bankable question can hide inside a WAIT

An item can be genuinely WAIT overall — it cannot finish until its target lands — while still holding a question that is answerable **right now**, and banking that answer early is real progress. Mark those explicitly. Without this sub-case the primary marker hides the question, which is the same defect as burying a one-answer gate underneath an attended-work one.

## Reading the queue

Read the queue through its documented list interface. Do not parse its storage format directly. This ensures your triage does not break when the store’s internal structure changes.

## Ordering and re-triage

Set priority on only the top few Tier 1 picks. Strategic, not bulk. Re-ranking everything is churn. Re-triage is cheap: re-rank after finishing a batch rather than committing to one order up front. New information changes tiers.

## Worked example

| Item | Tier | Gate Reason |
| :--- | :--- | :--- |
| Fix typo in README | Tier 1 | None |
| Refactor auth module | Gated | G1: design/taste decision — pick one of two shapes |
| Run benchmark suite | Tier 2 | None (heavy) |
| Download dataset X | Gated | G1: needs download, confirm the size is wanted |
| Install the bundled toolchain | Gated | G2: existing setup command, run once |
| Build a custom launcher | Gated | G3: needs approaches tried and tested |
| Re-do the layout by eye | Gated | G4: needs you steering throughout — attended work |
| Re-test on the office network | Gated | ENV: that network must be joined (recurring, local check) |
| Ship the migration | Waiting | WAIT: needs "publish the release" @ installed and verified |
| Adopt the upstream fix | Gated | EXT: **earned** — re-tested on latest, still broken; PR filed; no local workaround without forking |
| Quarterly key rotation | Do-now | Not gated: scheduled. Future surface date, fully autonomous on arrival |
| Close issue #42 | Tier 1 | None |

The tier lives as a short marker at the front of the gate reason the queue already stores. That keeps one record of gate state rather than two, and any view that prints a gate reason shows the tier for free.

## When NOT to use this

Skip triage entirely for a single task, or a queue of one: there is nothing to rank, and scoring it is pure overhead. Skip it too when the user has already named the item they want done — they have made the selection, and re-deriving it is second-guessing rather than triage.

Then: use `execute-unattended` to run the Tier 1 items, `close-out-the-run` to reconcile when the run ends, and `ungate-queue` to walk gated items with the user present — cheapest tier first. That pass returns items with their gates removed and nothing else done, so they flow straight back into this ranking alongside the ordinary actionable ones. Ungating feeds the same queue; it does not run beside it.
