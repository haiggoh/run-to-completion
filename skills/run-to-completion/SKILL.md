---
name: run-to-completion
description: Use when the work already in view in THIS conversation is an elaborate multi-step plan or spans several open projects AND most of the needed information is gathered, or when the user signals "autonomous" / "continuous" / "full auto" / "run to completion" / "keep going without stopping". Proactively offer to execute that plan continuously, without pausing between steps, resolving routine decisions yourself instead of asking. Do not trigger for a single straightforward task or when requirements are still unclear — offer this mode, don't force it. For a whole standing QUEUE of open items to be cleared unattended, start at autopilot instead.
---

# Run to Completion

## When to offer this

Offer continuous, autonomous execution when **both** are true:

1. The work ahead is an elaborate multi-step plan, or spans several open projects/tasks.
2. You've reached a point where you have all — or most — of the information you need to proceed (requirements are clear enough that further step-by-step check-ins would mostly just slow things down).

Also offer it whenever the user explicitly signals it: "autonomous", "continuous", "full auto", "run to completion", "keep going", "don't stop to ask me".

This is an **offer**, not something to silently start doing. Say what you're proposing and let the user opt in — they may prefer to review each step.

## If the user takes the mode

1. **Ask blocking questions up front.** (Attended runs differ from unattended ones here: because the user is *present*, prefer surfacing and clearing gates as early as possible — an answer is cheap now and unblocks work immediately. An unattended `autopilot` run does the opposite, asking only about the run itself and turning per-item questions into gates. Same plugin, opposite instinct, decided by whether anyone is there to answer.) Before starting, surface any genuinely blocking, matter-of-taste question you can already foresee (naming, structural choices, scope boundaries) — get those resolved once, before execution begins. If the plan will end in a push, publish, or repo-create (anything that would normally need the destructive/public-action confirmation below), ask for that permission's scope as part of this same up-front pass — don't wait until you hit it late in the run and stall the loop.
2. **Run the plan to completion without stopping between steps.** Don't pause after each task to report progress and wait; keep moving through the plan.
3. **Fold in interruptions at task seams.** If the user sends a mid-run message, or you discover something that would normally prompt a check-in, don't break stride mid-task — resolve it at the next natural seam between tasks.
4. **Reserve stops for truly unweighable decisions.** Most forks in the road have a reasonable default with clear pros/cons — decide and note your reasoning in the response rather than stopping to ask. Only stop for a decision that genuinely cannot be weighed without the user's input (e.g. a subjective preference with no "better" answer, or something irreversible and consequential).

## What this does NOT relax

Autonomy under this skill covers **routine step-by-step continuation** — it is not a license to skip the separate, standing rule about confirming destructive or hard-to-reverse actions (deleting data, force-pushing, dropping tables, publishing/pushing to shared or public destinations, modifying shared infrastructure). Those confirmations still apply at full strength inside a run-to-completion session, unless the user has explicitly authorized that specific action's scope.

## When NOT to apply

- A single, straightforward task — there's nothing to "run through."
- Requirements are still unclear or exploratory ("what could we do about X?") — clarify first; offering autonomy on an underspecified task just means confidently building the wrong thing faster.
- The user has not opted in and hasn't signaled they want this mode — keep checking in as normal.
