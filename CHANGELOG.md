# Changelog

## 0.6.12

### Fixed — `--help` documents the tag-visibility env vars it reads

0.6.11 shipped a live gate that reads three env vars and named none of them in its
own `--help`. The installed copy proved it: zero occurrences of `RTC_TAG_VISIBILITY`
in the help text, while the gate was gating its own release. A script that reads a
variable and does not say so is a lie by omission — the flag works and is invisible to
anyone probing the tool.

## 0.6.11

### Fixed — the tag must be VISIBLE, not merely pushed

`git push` returns **before the host serves the new state**, and the window is real
(measured 2026-10-14: raw + ls-remote served the pre-push state for about a minute).
The refresh step resolves the **published manifest** from that CDN, so a ship that
moved on immediately could print `done — v1.2.3 is live` while every installer still
resolved the previous version.

Measured on 0.6.7, in this repo, by this loop: the tag and the release were pushed and
the loop reported success, while `get-haiggoh apply` read the stale manifest, printed
`0.6.6 (current)` and copied **nothing**. Only a manual retry landed it.

This is the fifth silent-failure class in this loop — after `compgen … || true`
dropping an asset, a `post-release.sh` failure downgraded to a warning, an
unresolvable repo root read as `/`, and a refresh invoked but never verified. Every
one had the same shape: **a step that could fail without failing the ship.**

The loop now polls the published manifest, names what it actually declares, retries
once after a delay, and **refuses to create the release** while installers still see
the old version — so a failure leaves a pushed tag and no release, which is clean to
redo rather than a release nobody can install. `RTC_TAG_VISIBILITY=0` disables it for
a repo whose install path is not a published manifest; `RTC_TAG_VISIBILITY_TRIES` /
`RTC_TAG_VISIBILITY_DELAY` tune the poll.

25 rehearsal assertions. The rehearsal's origin now *presents* as a GitHub URL while
resolving to a local bare repo (`url.<local>.insteadOf`) — which is what the check
parses, and a closer model of the real thing than a local path.

## 0.6.10

### Added — version surfaces and version facts in the ship loop

execute-unattended's ship loop gains the version discipline step 3 needs to be honest,
migrated out of private notes: enumerate the repo's version surfaces rather than
recalling them (extension-less files such as a bare `VERSION` are invisible to
extension-filtered sweeps; a repo's own version-consistency test is the real gate);
check `git tag -l` before adding bullets to a CHANGELOG section, because a fast-forward
merge cannot conflict and a released section silently swallows new bullets; and how to
derive which commit shipped which version — read blobs (`git log --full-history -m`,
or walk `rev-list --first-parent`) instead of trusting a path-filtered log that drops
merge commits, group commits into the NEXT bump at or after them, and date a release
by its own bump commit.

## 0.6.9

### Added — every shippable repo is COVERED, durably

A repo reaches the version gate by one of two routes: its own
`tests/test_version_consistency.sh`, or the declared-surface fallback in
`rtc-ship.json`. The fallback was only ever exercised by two repos, and nothing
checked that a repo using it declared **every** version surface it actually has —
so a repo with a `VERSION` file and a `ROADMAP` that declares neither ships with
two of its four surfaces unchecked while the gate still prints "version surfaces
agree".

`tests/test_declared_surface.sh` audits every repo under `RTC_REPOS_ROOT`
(default `$HOME/ClaudeWorkspace`; absent ⇒ the test skips) and asserts, per repo,
that the gate passes, that it **read** every surface it printed (a `<none>` means
it compared nothing — the 0.6.7 defect shape), and that each surface existing on
disk is either declared or deliberately undeclared. Worktrees are excluded — a
worktree is the same repo as its parent and would double-count.

12 repos audited, 64 assertions. Mutation-checked: a scratch repo carrying an
undeclared `VERSION` file turns it red.

## 0.6.8

### Fixed — the refresh is VERIFIED, not just invoked

`get-haiggoh apply` exits **0 having copied nothing** whenever the manifest it
reads is still the old version — a raw.githubusercontent.com propagation window,
a stale marketplace cache, an unbumped manifest. A green exit code therefore says
nothing about whether the installed copy is now `$V`, and the loop was treating it
as proof. Measured on 0.6.7: the loop printed `done — v0.6.7 is live`, exited 0,
and the installed copy was still 0.6.6 — a release nobody could install until a
manual retry landed it.

The installed version is now read out of the cache and compared, and a mismatch
fails the ship naming both versions. `fa-ship.sh` had this check; generalizing it
into `rtc-ship.sh` dropped it, which is the same shape as the two defects fixed in
0.6.6 — a step that can fail silently, reported as success.

The cache root is overridable (`RTC_PLUGIN_CACHE`) so the rehearsal can point at a
scratch cache: a ship must never read, let alone write, tool-owned plugin state
except through the tool that owns it.

## 0.6.7

### Fixed — the version gate read "/" wherever there was no git repo

`version_gate` resolved its repo root with `git rev-parse --show-toplevel` and
did **not** fall back when that failed — while `cfg_get`, two functions above
it, did. In any directory with no `.git` above it the two therefore disagreed
about where the repo was, and `top` came back **empty**, so every surface was
read through `/`:

    .claude-plugin/plugin.json : <none>
    CHANGELOG.md (top entry)   : <none>
    ✖ no version in .claude-plugin/plugin.json

A perfectly consistent tree reported as disagreeing. This is not only the
installed plugin cache — it is every extracted release tarball, which is exactly
where a user checks a version. Caught by **dogfooding the installed 0.6.6**: its
own suites passed (18/18 rehearsal, 18/18 gate in the repo) while the installed
copy's gate called 0.6.6 split against itself.

Both call sites now share one `resolve_top()`, so they cannot drift apart again,
and the new assertion runs the gate in a scratch directory with no repo at all.
## 0.6.6

### Fixed — a release that looks complete but is not

Two steps in the ship loop could fail without failing the ship, and both of them
had already produced a release that read as successful:

**An asset glob matching nothing published a release missing that asset.**
`compgen -G` exits non-zero on a no-match glob and `|| true` swallowed it, so a
typo'd or never-built glob dropped out of the asset list and
`gh release create` ran without it. Nothing looks wrong until someone installs
from the release. The globs are now resolved in the **main shell** — an `exit`
inside a process substitution only leaves the subshell — and a glob matching
nothing aborts the ship naming the glob.

**A failing `.rtc/post-release.sh` only warned.** That hook is where a repo
verifies the refresh it just performed (the installed copy is at `$V`, the tap
formula points at this release). Warning and continuing let a release whose
refresh silently did nothing still print `done — v1.2.3 is live`, which is the
exact failure this loop exists to prevent: a success message over an unverified
outcome. It now fails the ship and says the release is published but **not
confirmed live**.

### Added — `tests/test_ship_rehearsal.sh`

The other ship test covered `--help` and the version gate, which left the
irreversible half of the loop — merge, tag, push, publish, refresh — with **no
coverage at all**, precisely where a silently skipped step cannot be undone. The
rehearsal builds a scratch repo with a **local bare origin** and stubs
`gh`/`get-haiggoh` to record what the loop asked of them, so every step runs for
real without publishing anything. 18 assertions, both directions: the happy path
proves the loop works, and each guard is planted with a defect to confirm it can
actually go red.

## 0.6.5

### Fixed — a repo with no changelog ships without an empty release

`rtc-ship.json`'s `changelog` may be empty, which is what a **web-app** repo
(echoprism: `package.json`, no `CHANGELOG.md`) needs. The version gate then
checks the manifest alone and says the changelog is unchecked rather than
failing on a file that was never promised, and the release notes fall back to
`gh --generate-notes` instead of being written from nothing.

An earlier version of this same script shipped an **empty** release body once
already (a `sed` failed silently and the notes file was zero bytes), so the
fallback is generated notes rather than an empty file — an empty release is a
release nobody reads. The empty-extraction-is-a-failure rule still holds for a
repo that *declares* a changelog; it is only an undeclared one that is skipped.

Also fixed while here: a leftover `[ -n "$notes" ]` guard from the previous
patch blocked the no-changelog path entirely.

### Verification

Gate verified on a throwaway repo whose only surface is `package.json`: with no
changelog declared it agrees and says so. With one surface there is nothing to
disagree with, which is the correct answer rather than a gap — a split needs at
least two surfaces. `tests/test_rtc_ship.sh` still 15/15.

## [0.6.4] — 2026-10-24 — rtc-ship.sh, the generalized ship loop

### Added — `bin/rtc-ship.sh`, the generalized ship loop

The ship loop lived in `~/.claude/scripts/fa-ship.sh`, hand-rolled for one repo and then copied by
memory into each repo shipped by hand. The costliest failure was never a wrong step — it was a
**skipped** one: the version bump lands *after* the test suite has run, so a split is introduced
between "tests green" and "PR opened", and only a re-check catches it. Measured 2026-10-24:
free-agents 0.43.2 shipped with `VERSION` at 0.43.1 while four other surfaces said 0.43.2.

`rtc-ship.sh <worktree> <version> "<title>"` runs the whole loop, and the gates cannot be skipped
by forgetting to run the script — they are *in* it:

- the version gate after the rebase and **before the merge** (the only place it is still
  meaningful), preferring the repo's own `tests/test_version_consistency.sh` and falling back to
  the surfaces declared in `rtc-ship.json`;
- an empty extraction is a **failure**, never a pass — the first run of this script let a planted
  split through precisely because an unreadable changelog silently skipped its comparison;
- `--test-only`, `--versions-only` (fast, pre-commit), `--which-config`;
- a tree stamp so a tree that already passed is not re-run;
- ff-merge into main, an annotated tag from the CHANGELOG entry, push, release with the repo's
  assets, installed-copy refresh, worktree cleanup.

**Per-repo specifics are data and hooks, not forks.** `rtc-ship.json` at the repo root carries the
tag prefix (most of our repos use `v`), which version surfaces exist, asset globs and the plugin
to refresh. `.rtc/{pre-flight,pre-package,post-release}.sh` carry the commands only that repo
has (free-agents' second-venv gates, its Homebrew tap trigger) and are **opt-in by presence** — a
repo with no `.rtc/` is fully supported.

`fa-ship.sh` stays in place for now: the concurrent session shipping free-agents still calls it.
Its removal is waypoint `remove-fa-ship-sh-once-the`.

### Fixed while building it, by running it

- the dirty-tree check was **inverted** (`[ -n "$(git status …)" ] || { dirty }`) and would have
  refused every valid ship;
- the CHANGELOG extractor assumed the bracketed `## [1.2.3]` heading; Keep-a-Changelog also permits
  `## 1.2.3`, which this repo uses;
- an orphaned duplicate block left a stray `fi` — caught by `bash -n` before anything ran;
- `changelog-prepend.py` had that same bracketed-only assumption and refused to add *this* entry
  until it accepted both forms: the tool built to remove one class of slip contained it.

### Verification

`tests/test_rtc_ship.sh` (12): `--help` prints help and writes nothing; a consistent tree passes;
a planted split fails and names the disagreeing surface; an unreadable changelog fails rather than
passing silently; both heading styles parse; a repo with its own consistency test still passes.
`--versions-only` also passes on free-agents and cost-tracker, each using its own test.
## 0.6.3

**The ship loop verifies tag visibility immediately after pushing the tag.** New step,
right between TAG and RELEASE: run `get-haiggoh plan` (or the repo's equivalent version
check) and confirm it reports the new version. get-haiggoh fetches the HEAD manifest, so a
manifest that disagrees with the tag — conflict markers, an unbumped version surface —
reads as NO update: a broken release hiding behind a successful-looking push. If the plan
does not see the update, stop and correct before continuing: align every version surface,
move the tag onto the corrected commit, and say plainly that it moved. A broken update is
worse than having shipped nothing at all. Measured 2026-10-14: free-agents 0.33.0 shipped
manifest was fixed and the tag re-pointed. Re-check ONCE after a short delay before
concluding a miss: a read seconds after the push sits inside the host's propagation window
(measured: raw + ls-remote served the pre-push state for about a minute), so a stale
negative is not a verdict.

- **No hard dependency on get-haiggoh**: the visibility check has a self-contained fallback,
  `hooks/check-tag-visibility.py <repo-url> <installed-version>` (extracted from get-haiggoh's
  diagnosis taxonomy, 0.9.0; keep in sync) — fetches the HEAD manifest, diagnoses conflict
  markers / invalid JSON / a missing version key, reads the highest v-tag, and prints a
  verbose VISIBLE / BROKEN-OR-HIDDEN verdict. Use it when get-haiggoh is not installed or
  transiently unresponsive; `--self-test` asserts the taxonomy network-free.

Versioning note: 0.6.2 belongs to the concurrent handoff-gating release from main; this
branch numbers itself past it.

## 0.6.2

**Gate handed-off steps on their async dependencies.** A step handed to the human because the
session can't run it (a permission-gated command, a manual `!` run) is sequenced against in-flight
work: wait for the dependency to land before showing the command, or label it "run after X
returns". Prefer in-session execution where permitted — only the session knows the async state.
(Observed 2026-10-13: a `gh release create` handed over while the tag-pushing subagent was still
in flight published a tag at the wrong commit.)

## 0.6.1

**A killed or timed-out test suite is UNKNOWN, never passing.** execute-unattended's verify
step had no rule for a suite that did not finish, so an unattended run could report "tests
pass" after a run that was killed partway, timed out, or was cut off by a tool limit. Step 1
now counts only a run that finished and exited 0; anything else is recorded as UNKNOWN and
gates the item instead of feeding a pass claim, a bump or a merge. (audit-loose-ends carries
the matching check since 0.9.0, `verify-state.py` T1; skill observation 21.)

## 0.6.0

**Pushed is not merged, and merging in order to test has the loop backwards.** The ship
loop went verify → bump → commit → push → tag, which silently assumed the push made the
change obtainable. It usually does not: an installer or update command resolves the
repository's **default branch**, so a pushed-but-unmerged change leaves every downstream
step — refresh, confirm-live, dogfood — verifying the *previous* version and reporting
success. A green "confirmed live" that proves nothing is worse than no check, because it
is indistinguishable from a real one.

- **New step 6: land it on the branch consumers actually resolve.** Establish which ref
  the consuming path fetches, and get the change onto it before checking anything
  downstream. If the version string did not change after a refresh, the likely reason is
  that nothing was published — not that the refresh was a no-op.
- **Merge is now its own ship-loop DEPTH**, alongside push, tag and release, in all three
  places the depth is asked (`autopilot` kickoff, the attended up-front pass, the
  always-on nudge) and the one place it is read. A merge to the default branch is a public
  action: it makes the change obtainable by every consumer. Clearing a run "through push"
  must not be readable as clearance to land it.
- **New step 2: dogfood PRE-merge.** Many delivery mechanisms can consume a local checkout
  — a local source, a path-based install, a link mode, an editable install. Where one
  exists, that is the cheaper and more honest place to find a broken feature: no bump or
  push is needed and nothing published changes. Merging to test makes the default branch
  where unverified work lands, and the pressure to merge fast is exactly when verification
  gets skipped.
- **But establish whether that route LINKS or COPIES the checkout first.** A copy is the
  case that costs an afternoon: the edit stays in the source, the installed copy stays
  stale, and the refresh is often version-gated so it reports "already up to date" and
  exits 0 having copied nothing — every command succeeds while you test the old behaviour.
  Verify with an observable change through the installed path, never with an exit code.
- **And do not edit the installed copy when it bites.** It is derived state the next update
  overwrites silently, so the change can neither ship nor be trusted while testing; a
  sandbox may also refuse writes there, which looks like a permissions fault and invites
  more workarounds. Editing a derived copy to make a test pass means the loop is wrong.
- **The two dogfoods answer different questions** and neither replaces the other: pre-merge
  asks *does the behaviour work*, post-distribution asks *does it work the way a consumer
  receives it* — through the real fetch, install path and packaging. Packaging-only failures
  appear nowhere else.
- **Routine ref-pinning is explicitly discouraged.** Where an installer can be pointed at a
  branch or commit, a pin written into a published catalog is mutable state where consumers
  read, it keeps succeeding silently after the branch stops mattering, and removing it
  depends on someone remembering. It earns its keep for holding consumers at a known-good
  version after a bad release — not for avoiding a merge.
- `close-out-the-run` now looks for the specific shape this misses: work that is committed
  and pushed and never landed, which reads as finished from the repository side while being
  unobtainable by anyone.
- Tests: 31 skill checks (was 23) and 21 nudge checks (was 17). Each of the 12 new
  assertions was mutation-tested — the wording was broken deliberately and the check
  confirmed to fail — since a doc assertion that cannot fail is decoration.

## 0.5.1

**A delegate is not one thing.** The skills spoke of "a local-execution capability" as
if local inference were the only delegate lane. It isn't: free or cheap remote APIs are
an equally valid lane, and a run can route to either — or split independent work across
both in parallel when both have spare capacity. `autopilot`, `execute-unattended`, and
the README now say so.

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
