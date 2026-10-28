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
| `writing-execution-plans` | planning | An additive layer on top of a general plan-writing skill, for plans a **different** executor runs (handoff, successor session, delegated model, unattended run) or that cross permission boundaries or touch live state: authority matrix, forced Phase 0 preflight, receipts with a known-bad discriminant, side-effect classification, adversarial review. It does not restate decomposition or test steps. |
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

### Putting `rtc-ship.sh` on PATH

The ship tool lives at `~/.local/bin/rtc-ship.sh`, and `install/link-shortcuts.sh`
installs it as a **shim** — a small generated file that resolves the installed plugin
copy on every call — rather than a symlink:

```
bash install/link-shortcuts.sh --dry-run   # show what would change, write nothing
bash install/link-shortcuts.sh             # back up anything replaced, then install
bash install/link-shortcuts.sh --force     # also replace a file this plugin did not write
```

Because it resolves per call, a plugin update takes effect with **no re-wiring**, and a
branch switch in a workspace checkout changes nothing live. Re-running is safe: when the
path already carries the `# haiggoh-shim v1` header it changes nothing. Ask it where it
resolved with `~/.local/bin/rtc-ship.sh --which`.

Anything replaced is copied to `~/.claude/backups/run-to-completion-link-<timestamp>/`
with its mode preserved, and a plain file this plugin did not write is **refused** rather
than overwritten unless you pass `--force`.

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

## Shipping a release: `bin/rtc-ship.sh`

    rtc-ship.sh <worktree> <version> "<title>"     the full ship loop
    rtc-ship.sh <worktree> <version> "<title>" --no-reap    same, but keep the worktree and branches
    rtc-ship.sh --test-only <worktree>            gates only, ship nothing
    rtc-ship.sh --versions-only <worktree>        the version gate alone (fast, pre-commit)
    rtc-ship.sh --which-config                    the config this repo uses

The loop runs nine phases in a fixed order: **door check** (the `<version>` you typed is the one
the manifest carries, and the CHANGELOG has an entry for it) → **rebase** on
`origin/<default-branch>` (a conflict is aborted and stops the ship) → **gates** (the repo's suite
plus `.rtc/pre-flight.sh`, with the version surfaces checked in lockstep) → **merge**
(fast-forward) → **tag** (annotated; title and notes from the `CHANGELOG.md` entry) → **visibility**
(the published manifest must already declare the new version — a pushed tag is not yet a released
one) → **release** (with the packaged assets, read back from GitHub afterwards) → **installed-copy
refresh** (read back and verified) → **cleanup** (reap what shipped — see below).

The gates cannot be skipped by forgetting to run a script — they are *in* it, and the version gate
runs after the rebase and **before the merge**, which is the only place it is still meaningful: the
version bump lands *after* the test suite has run, so a split is introduced between "tests green"
and "PR opened", and only a re-check catches it.

Every phase that can fail on its own words — the rebase, `pre-package`, the upload — keeps its full
output in `RTC_SHIP_LOG_DIR` (default `${TMPDIR:-/tmp}/rtc-ship-logs/<repo>-<version>`) and prints a
✓/✖ verdict; a failure also prints the last 15 lines of what the step said. A phase whose output
goes to `/dev/null` cannot be judged: "ran quietly" and "died having done nothing" look identical.

A repo configures the tool with two things, both inside the repo and both committed:

- **`rtc-ship.json`** — data: `tag_prefix` (`v` on most of our repos), which version surfaces
  exist (`version_file`, `roadmap`), asset globs, the plugin to refresh, `default_branch`, and
  `reap` (set `false` to permanently skip the post-release cleanup — see below).
- **`.rtc/{pre-flight,pre-package,post-release}.sh`** — commands only that repo has. **Opt-in by
  presence**: a repo with no `.rtc/` directory is fully supported.

Two guards make a *silent* half-ship impossible, because both produced a release that looked
complete and was not:

- **An asset glob that matches nothing fails the ship.** `compgen -G` exits non-zero on no match
  and `|| true` used to swallow it, so a release published **with an asset missing** while the loop
  reported success — the worst shape of failure, because nothing looks wrong until someone tries
  to install from it.
- **A failing `.rtc/post-release.sh` fails the ship.** That hook is where a repo verifies the
  refresh it just performed; warning and continuing let a release whose installed copy is still the
  old version print "done — v1.2.3 is live".
- **The release is read back.** After the upload, the loop lists the assets GitHub actually holds
  and fails if a declared one is missing — the upload's exit code is a claim, the served list is
  the outcome.
- **The refresh itself is verified.** `get-haiggoh apply` exits 0 having copied nothing when the
  manifest it reads is still the old version (a CDN propagation window, a stale marketplace
  cache), so a green exit code is not proof. The installed version is read back and compared, and
  a mismatch fails the ship naming both versions.
- **The tag must be VISIBLE, not merely pushed.** A push returns before the host serves the new
  state, so installers can still resolve the previous version while the loop reports success —
  measured on 0.6.7, where the release was live and `get-haiggoh` copied nothing. The loop polls
  the published manifest and refuses to create the release until it declares `$V`, leaving a pushed
  tag and no release, which is clean to redo.

`tests/test_ship_*.sh` rehearse the whole loop — merge, tag, push, release, refresh, cleanup —
against a **local origin with a stubbed `gh`**, so the irreversible half is covered without
publishing anything. The rig is `tests/lib/rehearsal.sh`; the cases are split across six files
so the gate runs them in parallel.

After the release is confirmed live, the loop **reaps what it shipped**: the worktree and its branch
are removed (locally *and* on the remote), every other local branch already contained in the default
branch is deleted — except one a worktree still has checked out, because a concurrent session may be
standing in it — and the same set of remote-tracking refs is pushed away, since `git fetch --prune`
cannot clean a branch that was never deleted there.

Pruning merged branches is good practice beyond tidiness: a merged branch is a dead name that
still looks alive, every `git branch` listing grows noisier, and a stale name gets mistaken for
work in progress — measured here, two fully-merged, tagged, shipped worktrees (`fa-wt-config`,
`rtc-wt-glob`) sat unreaped for weeks because no tool was willing to remove them.

Reaping is the **default**, and any one of three opt-outs skips the whole cleanup step — always
**announced in the output**, never silently:

- `--no-reap` — transient: keep the worktree and branches for **this ship only**;
- `"reap": false` in `rtc-ship.json` — permanent, committed with the repo (a value that is not
  a boolean fails the ship **before** anything irreversible runs);
- `RTC_SKIP_CLEANUP=1` — the environment route, for scripted invocations.

Nothing is lost to a judgement call. What may be reaped without a backup is decided in
`cleanup_extra()`, and its rules are harmonised with watch-your-step's `worktree remove` guard —
deliberately **duplicated rather than shared**, because the two repos have no dependency on each other
and this is the *automatic* path: an auto-reaper that leans on a guard written for manual commands is
safe only while that guard happens to be installed.

- `.DS_Store` and `*.pyc` are noise anywhere;
- a path is excused by a **directory component**, never a substring — `venv/x` is cache, but
  `myvenv/plan.md` is a ledger;
- a directory git **collapsed** because everything in it is ignored (`!! sub/`) is *inspected*, never
  judged by its name, because the name cannot separate a Finder-junk directory from one holding the
  only copy of something;
- an ignored file **byte-identical** to the same path in the canonical checkout is not information
  this worktree alone holds;
- anything else is **backed up to a timestamped directory** first — `RTC_BACKUP_DIR` moves it —
  because a removed worktree once took an uncommitted handover with it. A backup that cannot be
  written (an unwritable directory, a full disk) **keeps the worktree** and says so; it never
  proceeds to the removal.

An unmerged, dirty, or canonical-checkout tree is kept, and says why. A cleanup failure never fails a
confirmed release: the release outranks the tidy.

`default_branch` is resolved from config, then the remote's own `origin/HEAD`, and only then
assumed to be `main` — echoprism uses `master`, and a hardcoded `main` would mis-ship it. In prose,
"merge to main" means **this repo's default branch**, never a branch literally named `main`.
