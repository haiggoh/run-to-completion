---
name: close-out-the-run
description: 'Use WHEN an unattended run is ending: the autonomous pile is exhausted, a resource limit is close, or the user has called a stop. Reconcile the durable records the run touched, stop cleanly at the gated boundary instead of churning, and write a wrap that says why each remaining item was left and how to resume it. Do NOT use for scoring the queue (triage-for-autonomy) or for mid-run execution (execute-unattended).'
---

# close-out-the-run — reconcile and leave a clean seam

The run is ending. Your job is to ensure the state is accurate and the handoff is clear.

## The two triggers

Close out when:
1. Clean bounded autonomous work is exhausted (everything left is gated).
2. The resource you are spending is nearly gone.

## Do not churn at the gated boundary

Attempting gated work unsupervised is the single worst way to end a run. It produces low-confidence output that a human must now audit. Stopping is the correct move. State it as a result, not an apology.

## Reconcile durable records

Before stopping, check every item the run touched:
- Every item carries an accurate done state and a resolution title that says what actually happened.
- Repositories are committed and pushed.
- Plans and notes agree with reality.
- Nothing is left orphaned or still flagged as pending when it is finished.

A historical record of a completion is worth keeping. A stale pending flag on finished work is a defect to fix. They look similar and are not the same.

## Leave a clean seam

Pause any persistent goal or session-continuation mechanism. Do not leave it running against work you have decided not to do.

## The final wrap

The wrap has a required shape:
1. What closed, what advanced, what shipped.
2. What the run consumed.
3. **A GATED list:** Every remaining item with the reason it could not be done autonomously (needs user input, needs a supervised session, needs a download, is a design/taste decision, needs a fresh session) and the concrete next action that would unblock it.

## Why the gated list matters

It converts "I stopped" into a menu the human can act on in seconds. It is nearly free if triage recorded a gate reason per item.

## Lessons

If the run produced a reusable workflow lesson, record it where your durable notes live and put the follow-up on the queue. Do not turn this into a ceremony performed on a schedule. It is worth doing only when something was actually learned.

## When NOT to use this

This is the closing pass, not a progress update. A milestone wrap between items belongs to `execute-unattended` and should stay short; running the full reconciliation after every item turns the run into bookkeeping. Nor is this the place to score what is left — that is `triage-for-autonomy`, and the gate reasons it recorded are what you are reporting here.
