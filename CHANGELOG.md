# Changelog

## 0.4.0

**Blocks are not all one thing, and gating now anticipates instead of only reacting.**
Completes the `run-to-completion` half of a design pass agreed with the user; the
`waypoints` half shipped separately as that plugin's `0.6.0`. Written so a stranger's
queue benefits without needing that specific tracker.

- **Four kinds of block, distinguished by what RELEASES them**, because each needs a
  different mechanism and a different owner: a **person** (`G1`–`G4`, released by
  asking); a **queue item** (`WAIT`, new); a **recurring world condition** (`ENV`);
  and an **external party** (`EXT`, new).
- `WAIT` items are kept out of the human-gated pile entirely. Nobody is needed — they
  release themselves — so filing them with the questions tells the user they owe
  answers they do not owe. On a real queue **15 of 26** blocked items were this,
  cutting the apparent question-pile by more than half. Record the **milestone**, not
  just the target: "when that item is done" is frequently not the trigger.
- `ENV` is now **split by check cost**. A precondition readable from local state may
  be checked every run; one needing an outbound network call must never be, because
  that is real spend for an almost-always-negative answer. Stated explicitly: do not
  build a release-poller.
- `EXT` **must be earned.** "Blocked on a third party" is a conclusion rather than an
  observation, and it decays — so the marker now requires a recorded note of the
  options we control and why each fails. Unearned, `EXT` is where items go to die.
- Two distinctions that shrink the gated pile for free: **scheduled is not blocked**
  (a date is not a gate — model it as a future surface date), and **a bankable
  question can hide inside a `WAIT`** (ask that one, record it, leave the item
  waiting).
- **Anticipatory gating:** when an item can already be seen to end at a gate, do the
  part before the gate on purpose and stop there. Most gated items are ordinary work
  followed by one question, so skipping the whole item forfeits autonomous progress
  nobody else will make. This is now the standard move, not an exception.
- Items are **retiered in the store**, not merely annotated with a gate reason.

## 0.3.0

**`ungate-queue` is now gate-removal only.** It had drifted into doing the work it
unblocked, which defeats its purpose: this is the pass that spends *user attention*
rather than compute, and that is exactly what makes it the affordable pass when
compute is scarce or metered — but only while it stays cheap.

- `ungate-queue`: added an explicit **record-and-return** boundary. Ask the one
  question, write the answer onto the item, retier it, move on. Removed the old
  "Act immediately / convert answers into progress in the same sitting" section
  that licensed the drift.
- `ungate-queue`: it now handles **only the first gate** per item. A second blocker
  behind the first is recorded, not chased.
- `ungate-queue` + `triage-for-autonomy`: the gated pile is **no longer flat**. Items
  are sorted by how cheaply they can be released — **G1** (one permanent answer),
  **G2** (a setup step an existing script performs), **G3** (a custom installation
  needing real work), **G4** (needs a human throughout; attended work, not an
  ungating candidate) — plus **ENV** for recurring external preconditions that can
  never be permanently removed and must not be re-reasoned as if they could.
- An item that is not gated now but expects a gate later is **promoted into the
  actionable queue** with a note, rather than held back. Partial release is progress.
- The tier is **persisted as a short marker on the existing gate-reason field**, so
  triage reads it instead of re-deriving it every run, and there is exactly one
  record of gate state. No field was added to any queue's schema.
- Ordering: tier dominates, ordinary priority breaks ties **within** a tier. A
  high-priority G3 does not jump ahead of a G1.
- `autopilot`: says plainly that the attended pass hands back newly-actionable items
  rather than finished ones, and to re-triage after an ungating pass.
- `close-out-the-run`: the gated list is ordered cheapest-to-release and carries the
  tier; attended-only and recurring-condition items are called out as such, not as
  failures to unblock.
- SessionStart nudge: reflects the narrowed scope.
- Tests: new **Case E** guards the boundary wording, the first-gate limit, the
  absence of the old do-the-work instruction, tier-vocabulary agreement across both
  skills, and the single-record storage choice. All seven checks were mutation-tested.

## 0.2.0

Added the unattended-run phase skills: `autopilot`, `triage-for-autonomy`,
`execute-unattended`, `close-out-the-run`, `ungate-queue`.

## 0.1.0

Initial release: the `run-to-completion` skill and the stateless SessionStart nudge.
