# Changelog

## 0.5.0

**Pushed is not shipped.** The ship loop used to end at "confirmed live in the installed
copy", which turns out to stop one step short of the thing that matters and two steps
short of leaving a usable record. It now runs: verify → bump → commit → push → **tag** →
**release, when appropriate** → refresh the installed copy → confirm it is live there →
**dogfood it**.

- **Tag every version bump.** A push without a tag leaves no immutable reference to what
  went out, so whoever bisects the next regression has a version number pointing at a
  moving branch. Tags are cheap, so this one is unconditional.
- **Cut a release when appropriate — and "appropriate" now carries a criterion**, because
  without one the phrase collapses into always-or-never at the reader's whim. A release is
  appropriate when it is how a consumer *learns about or obtains* the change: the artifact
  updates from the release surface, or the change is user-facing enough that its notes are
  the changelog anyone actually reads. Not for an internal refactor, a fixture, or a typo.
- **Dogfood the change through the installed copy, against real state.** This is a separate
  check from the one before it, and conflating them is the usual miss: confirming the
  version asks *did the new code arrive*, dogfooding asks *does it do the thing*. A change
  can be live and inert, or live and wrong, and both are indistinguishable from a correct
  version string. If you added a command, run it; if you changed a pass, perform the pass.
- **Bump the version in every place that states it**, not just the manifest — a version
  that disagrees with itself is worse than one that was never bumped.

### Authorization got narrower, not wider
The new steps *are* public actions: a pushed tag and a cut release are both visible and
awkward to retract, and a release notifies and indexes. So the standing confirm-before-
publishing rule now reaches them explicitly, and the up-front pass asks for the ship loop
as a **depth** — through push, through tag, or through release — rather than treating "you
may push" as clearance for everything downstream of the push. Both entry points ask it
that way: `autopilot` at kickoff (where nobody is present to widen it later) and
`run-to-completion` in the attended up-front pass. Where the depth stops, the loop stops:
the remaining steps become a recorded gate. Being unable to tag or release is a gate like
any other and never a reason to redefine the item as done at the push.

### Also
- `close-out-the-run` now verifies the ship loop reached its end, and asks a run that
  stopped early to name the step it stopped at. It *references* the loop rather than
  restating it — the existing test that keeps the procedure owned by exactly one skill
  still passes, and caught the first attempt at this edit.
- 16 new assertions across `tests/test_skills.sh` (Case D) and `tests/test_nudge.sh`
  (Case D), covering all three new steps, the release criterion, the depth rule, and the
  gate-not-done fallback. Mutation-tested 10/10.

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
