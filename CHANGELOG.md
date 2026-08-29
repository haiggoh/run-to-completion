# Changelog

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
