# run-to-completion

Claude behavior for **running a queue of open work to completion without stopping** —
and for stopping *well* when the only work left needs a human.

It started as a single rule ("offer to run a big multi-step plan continuously
instead of checking in after every step") and now ships the whole loop as
composable skills: score the queue, execute the autonomous part unattended,
close out with an honest account of what was left and why.

## What you get

| Skill | Phase | Owns |
|---|---|---|
| `autopilot` | whole run | Entry point for "run everything you can while I'm away." Sequences the three phases below as an explicit checklist, plus the up-front kickoff. |
| `triage-for-autonomy` | before | Scores any queue — a to-do list, an issue tracker, plan steps, a persistent open-items store — into **do-now** / **autonomous-but-heavy** / **gated**, recording a gate reason per blocked item, and ranking the gated pile by how cheaply each one could be released. |
| `execute-unattended` | during | Keeping moving: wrap-and-switch the instant something needs a human, reversibility before touching a file, and the ship loop that carries a change all the way out — verified, **dogfooded pre-merge** where the delivery mechanism can consume a local checkout, version-bumped, committed, pushed, **merged to the branch consumers actually resolve**, **tagged**, **released** where that is how a consumer obtains it, refreshed in the *installed* copy, and then **dogfooded** there against real state. |
| `close-out-the-run` | after | Reconcile the durable records the run touched, stop cleanly at the gated boundary instead of churning, and write a wrap whose gated list says why each remaining item was left and how to resume it. |
| `ungate-queue` | attended | The other half: walks the **blocked** pile *with* you, cheapest gate first, turning each gate reason into the one question that releases it — then **records the answer and stops**. It removes gates; it does not do the work it releases. |
| `run-to-completion` | offer | The original rule, for a plan already in view in the conversation: offer continuous execution, ask blocking matter-of-taste questions up front, fold mid-run prompts in at task seams. |

Plus a one-line, stateless **SessionStart hook** that reminds Claude the skills
exist so they fire when the mode becomes relevant. No markers, no first-run pass,
no state written anywhere — purely reactive.

## The shape of a run

```
kickoff  → establish the resource picture, warm any delegate,
           ask every blocking question ONCE
triage   → tier 1 do-now │ tier 2 heavy │ gated (+ reason, + how cheap to release)
execute  → do tier 1, wrap-and-switch on any gate, re-triage between batches
close    → reconcile records, pause rather than churn,
           wrap with a GATED list + how to resume each item
```

The gated list is the highest-value output. It turns "I stopped" into a menu you
can act on in seconds — and it is nearly free, because triage already recorded
why each item was blocked.

## The attended half is deliberately narrow

`ungate-queue` is the pass you run when *you* are in the room. It spends your
**attention**, not compute — which is what makes it the affordable pass when
compute is scarce or metered. That only holds while it stays cheap, so the skill
draws a hard boundary: ask the one question, write the answer onto the item,
retier it, move on. It handles **only the first gate**, and it does not open the
files. The work it releases goes back into the queue for the next `autopilot` run.

To make sure the best questions get asked first, the gated pile is not flat:

| | The gate is… | Worth asking? |
|---|---|---|
| **G1** | one answer away from being gone permanently | first, always |
| **G2** | a setup step an existing script already performs | cheap, yes |
| **G3** | a custom installation needing real work | after G1/G2 |
| **G4** | a human interacting throughout — no answer releases it | attended work, not ungating |
| **ENV** | a recurring external precondition (an app open, a network joined) | ask only "is it true now?" — never solvable |

An item that is *not* gated now but expects a gate later is not on this list at
all: it is promoted straight into the actionable queue with a note saying where it
will stop, because work that can proceed should.

The tier is persisted as a short marker on the front of the gate reason the queue
already stores — so judging is one-time rather than per-run, there is exactly one
record of gate state, and any view that prints a gate reason shows the tier free.

## What this does **not** relax

Autonomy here covers **routine step-by-step continuation**. It is not a license to
skip the standing rule about confirming destructive or hard-to-reverse actions —
deleting data, force-pushing, publishing to a shared or public destination,
changing shared infrastructure. Those confirmations apply at full strength inside
an unattended run, unless you authorized that specific action's scope up front.
`autopilot` deliberately asks for that scope during kickoff so the loop doesn't
stall on it late.

## Pushed is not shipped, and merging to test is backwards

An installer or update command resolves an artifact from the repository's
**default branch**. So a change that is committed and pushed to a working branch
is not yet obtainable — and the steps that come after the push will refresh,
confirm and exercise the *previous* version while reporting success. That green
check is the dangerous part: it is indistinguishable from a real one. The loop
therefore has an explicit step for landing the change on the ref consumers
actually resolve, and `close-out-the-run` looks for work stranded on an unmerged
branch, which reads as finished from the repository side.

The fix is not to merge earlier. Merging *in order to test* makes the default
branch the place unverified work lands, and the pressure to merge fast is exactly
when verification gets skipped. Instead the loop dogfoods twice: **pre-merge**
from the working branch, wherever the delivery mechanism can consume a local
checkout (a local source, a path-based install, a link mode, an editable
install) — which answers *does the behaviour work*; and **post-distribution**
through the real fetch and install path — which answers the different question
*does it work the way a consumer receives it*. Packaging-only failures surface
nowhere but the second.

Find out whether the pre-merge route **links** your checkout or **copies** it
before trusting it, because a copy is the case that wastes an afternoon: the
refresh command is often version-gated, so it reports "already up to date", exits
0, and copies nothing, leaving you testing the old behaviour while every command
succeeds. Verify with an observable change through the installed path, not with an
exit code. And when that bites, do not edit the installed copy to move on — it is
derived state that the next update overwrites silently, so the change can neither
ship nor be trusted. Editing a derived copy to make a test pass means the loop is
wrong, not the permissions.

Where an installer can be pointed at a branch or commit, that is deliberately not
the routine path: a pin written into a published catalog is mutable state where
consumers read it, it keeps succeeding after the branch stops mattering, and
removing it depends on someone remembering. Pinning is for holding consumers at a
known-good version after a bad release.

The ship loop makes this sharper rather than looser, because its own later steps
publish: a merge to the default branch makes the change obtainable by everyone, and
a pushed tag and a cut release are both visible and awkward to retract.
So the scope is asked as a **depth** — cleared through push, through merge to
the default branch, through tag, or through release — instead of a bare yes to
"may you push", which settles nothing about what comes after it. Push and merge
are separate depths because the gap between them is where "shipped" gets claimed
too early: a pushed branch affects nobody, while landing it on the default branch
is what makes the change obtainable. Where the depth stops, the loop stops with it: the
remaining steps are recorded as a gate, and the run says which step it stopped at
rather than calling the item done.

## Independence

Every skill is written in capability terms and names no other plugin. If you have
a persistent open-items store, that's the queue; if you have a local-execution
capability or a free/cheap remote-API lane (or both), delegatable steps route to
whichever fits, including split across both in parallel when independent items
are ready together; if you have a reconciliation discipline, the closing phase
uses it. None of them are required — the skills work on whatever queue you
already keep, including one they didn't create.

## Why

The mode earned its keep across several long multi-part sessions: once
requirements are clear, asking permission before every routine step costs time
without adding signal. Making it a plugin (rather than one project's local
`CLAUDE.md` rule) makes it portable and independently toggleable.

## Install — Claude Code (one-click)

```
/plugin marketplace add haiggoh/get-haiggoh
/plugin install run-to-completion@haiggoh
```

> The marketplace catalog lives in the
> [`get-haiggoh`](https://github.com/haiggoh/get-haiggoh) repo and lists several
> plugins. Add the marketplace once from there, then install `run-to-completion`
> by name. This repo ships the plugin itself, not a marketplace catalog.

## Install — Claude Desktop / claude.ai (copy-paste)

These apps have no plugin marketplace. Open
[`templates/custom-instructions.md`](templates/custom-instructions.md) and paste the
rule block into **Settings → Custom Instructions** (or a Project's instructions).

## Tests

```
bash tests/test_nudge.sh      # hook output contract (needs jq)
bash tests/test_skills.sh     # frontmatter + independence checks
```

## License

MIT © Heiko Brantsch
