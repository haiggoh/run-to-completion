# Ship-time Branch/Worktree Cleanup in `rtc-ship.sh` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `rtc-ship.sh` reap the shipped worktree, its branch, and every other merged branch — the step its own CHANGELOG has advertised since 0.7.0 but never implemented.

**Architecture:** Port `cleanup()` from `~/.claude/scripts/fa-ship.sh` (lines 194–245) into `bin/rtc-ship.sh`, replacing its free-agents-specific assumptions with this script's existing resolvers (`DEFAULT_BRANCH`, `$MAIN`, `$WT`, `$BR`, `phase`). It runs after the post-release hook, on the full ship path only, gated by `RTC_SKIP_CLEANUP=1`. Tests extend the existing rehearsal harness, which already builds a scratch repo with a local bare origin, a worktree branch, and stubbed `gh`/`get-haiggoh`/`curl`.

**Tech Stack:** POSIX-ish bash (`set -euo pipefail`), git plumbing, the repo's own shell test suites (`tests/test_*.sh`), no new dependencies.

**Spec:** the user's decision in this session (2026-10-27): the branch-cleaning routine belongs in `rtc-ship`, and must match `fa-ship.sh` exactly — **including deletion of merged remote refs** via `git push origin --delete`.

## Global Constraints

- `fa-ship.sh` behavior is the reference implementation: `~/.claude/scripts/fa-ship.sh:189-248`. Deviations must be justified in a comment as a generalization, never silently.
- The tool is repo-agnostic: no free-agents path, no machine path, no plugin-cache version may appear in new code — a workspace path quoted inside a comment is a machine path, so use `$MAIN`/`$WT`.
- "main" means `$DEFAULT_BRANCH`, already resolved at `bin/rtc-ship.sh:266-271`. Never a literal `main`.
- A cleanup failure must NOT fail a confirmed release (`cleanup || echo "⚠ cleanup failed; the release itself is done"`), matching `fa-ship.sh:247`.
- Default branch, HEAD, and any branch a worktree has checked out are never deleted.
- Every new env var must be documented in the header (which `usage()` prints dynamically) AND added to the env-var assertion list in `tests/test_rtc_ship.sh:30-31`, or that test fails.
- Version surfaces for this repo are exactly two: `.claude-plugin/plugin.json` and the `CHANGELOG.md` top heading. Both must move together (the version gate enforces it).

## Review Focus

For each line: the test that pins it, in the owning task's step style.

1. **A branch checked out by ANOTHER worktree is never deleted** — the shipped branch's sweep must skip every branch in `git worktree list`. Fa-ship's `in_wt` guard.
2. **The default branch and `HEAD` are never deleted**, neither locally nor on the remote.
3. **A dirty or unmerged worktree is kept, with a reason** — never removed silently. (The ship itself refuses a dirty `$WT`, so this path is reached via an *unmerged* second worktree.)
4. **Nothing precious is lost**: untracked/ignored files that are not mere caches are backed up to `~/.claude/backups/worktrees/<name>-<timestamp>/` before `worktree remove --force`.
5. **`$WT == $MAIN` must be a no-op**, not the deletion of the canonical checkout.

---

### Task 1: The failing rehearsal tests

**Files:**
- Modify: `tests/test_ship_rehearsal.sh` (append a cleanup section after the refresh section, ~line 200+)
- Test: same file (this repo's tests are the test)

**Interfaces:**
- Consumes: `rehearse <dir>`, `ship <dir> [args...]`, `fake_cache <dir> <version>`, `is`, `has`, `$TMP`, `$ROOT`.
- Produces: nothing yet — these tests must FAIL against current `bin/rtc-ship.sh` (it has no cleanup at all).

- [ ] **Step 1: Assert the shipped worktree and branch are reaped after a clean ship**

```bash
D="$TMP/c1"; rehearse "$D"
is "a clean ship reaps the shipped worktree" "1" "$(ship "$D" 0.2.0 'second')"
is "the shipped worktree directory is gone" "" "$([ -d "$D/wt" ] && echo present || echo '')"
is "the shipped branch is gone locally" "" "$(git -C "$D/main" branch --list feat/ship)"
is "the merged remote branch was deleted" "" "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x 'feat/ship' || echo '')"
has "and each removal is reported" "$(cat "$D/out")" "cleanup:"
```

- [ ] **Step 2: Assert `RTC_SKIP_CLEANUP=1` keeps everything**

Extend `ship()` to forward extra env, or add a variant:

```bash
ship_no_cleanup() { ( cd "$D/wt" && CALLS="$D/calls" PATH="$D/bin:$PATH" RTC_SKIP_TESTS=1 \
    RTC_PLUGIN_CACHE="$D/cache" RTC_SKIP_CLEANUP=1 RTC_TAG_VISIBILITY_DELAY=0 \
    PUBLISHED_VERSION=0.2.0 "$ROOT/bin/rtc-ship.sh" "$d/wt" 0.2.0 'second' ) >"$d/out" 2>&1; echo $?; }
is "RTC_SKIP_CLEANUP=1 keeps the worktree" "0" "$(ship_no_cleanup "$D")"
is "and the branch" "feat/ship" "$(git -C "$D/main" branch --list feat/ship)"
is "and the remote ref" "feat/ship" "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x feat/ship || echo '')"
```

- [ ] **Step 3: Assert a merged branch checked out by ANOTHER worktree survives**

Build a second worktree on a branch that IS merged into the default branch, then ship:

```bash
D="$TMP/c2"; rehearse "$D"
( cd "$D/main" && git branch other/merged && git worktree add -q "$D/wt2" other/merged )
is "a merged branch held by another worktree survives the sweep" "other/merged" \
   "$(git -C "$D/main" branch --list other/merged)"
is "and its remote ref survives too" "other/merged" \
   "$(git -C "$D/origin.git" for-each-ref --format='%(refname:short)' refs/heads | grep -x other/merged || echo '')"
```

- [ ] **Step 4: Assert a precious untracked file is backed up before removal**

```bash
D="$TMP/c3"; rehearse "$D"
( cd "$D/wt" && mkdir -p build && echo precious > build/notes.txt && printf 'build/\n' >> .gitignore \
    && git add .gitignore && git commit -qm 'ignore build' )
ship "$D" 0.2.0 'second' >/dev/null
is "a precious untracked file is backed up, not silently destroyed" "1" \
   "$(find "$HOME/.claude/backups/worktrees" -name notes.txt -newermt '-2 minutes' 2>/dev/null | wc -l | tr -d ' ')"
has "and the backup is reported" "$(cat "$D/out")" "backed up"
```

`RTC_BACKUP_DIR` must be overridable (the test cannot write to a real `$HOME`): add env `RTC_BACKUP_DIR` (default `$HOME/.claude/backups/worktrees`) and have the test point it at `$TMP/bk`. Assert the file exists under `$TMP/bk`. **The test must never touch the real backups directory.**

- [ ] **Step 5: Assert a mere-cache untracked file is NOT backed up (it is reaped silently)**

```bash
D="$TMP/c4"; rehearse "$D"
( cd "$D/wt" && mkdir -p bin/__pycache__ && echo x > bin/__pycache__/a.pyc )
is "a cache-only worktree is reaped with no backup" "0" "$(grep -c 'backed up' "$D/out")"
```

- [ ] **Step 6: Assert `$WT == $MAIN` is a no-op**

```bash
D="$TMP/c5"; rehearse "$D"
( cd "$D/wt" && RTC_BACKUP_DIR="$TMP/bk" ... "$ROOT/bin/rtc-ship.sh" "$D/main" ... )  # ships the canonical checkout
is "shipping the canonical checkout does not remove it" "0" "$([ -d "$D/main" ] && echo 0 || echo 1)"
```

(If the ship refuses `$WT == $MAIN` for another reason first, assert the refusal message names it rather than the checkout being deleted.)

- [ ] **Step 7: Run the new tests and confirm they FAIL**

Run: `bash tests/test_ship_rehearsal.sh`
Expected: FAIL — every assertion above fails, because `rtc-ship.sh` performs no cleanup. A GREEN result here means the test is not exercising the new code (the plan's own negative-control requirement).

---

### Task 2: Implement `cleanup()`

**Files:**
- Modify: `bin/rtc-ship.sh` — header env block (add `RTC_SKIP_CLEANUP`, `RTC_BACKUP_DIR`), a new section before the final `phase "done — ..."`, and the call site.
- Test: `tests/test_rtc_ship.sh:30-31` (env-var assertion list).

**Interfaces:**
- Consumes: `$WT`, `$BR`, `$MAIN`, `$DEFAULT_BRANCH`, `phase`, `cfg_get`.
- Produces: `cleanup()`, `cleanup_extra()`; env `RTC_SKIP_CLEANUP`, `RTC_BACKUP_DIR`.

- [ ] **Step 1: Document the two new env vars in the header**

Add to the `# Env:` block, so dynamic `usage()` prints them:

```
#   RTC_SKIP_CLEANUP=1  keep the shipped worktree and branches after a confirmed release
#   RTC_BACKUP_DIR      where uncommitted files are backed up before a worktree is reaped
#                       (default $HOME/.claude/backups/worktrees)
```

Then add `RTC_SKIP_CLEANUP` and `RTC_BACKUP_DIR` to the `for v in ...` list in `tests/test_rtc_ship.sh`.

- [ ] **Step 2: THE USER'S CONTRIBUTION — `cleanup_extra()`**

See the request in the conversation. Contract, fixed by the callers:

```bash
cleanup_extra() {  # print one relative path per line for everything in $WT that would be LOST
                   # and is NOT a mere cache; empty output = safe to reap without a backup
```

The body is ~8 lines and is the one genuine design decision in this port (see the trade-offs in the conversation). It must:
- read `git -C "$WT" status --porcelain --ignored --untracked-files=all`, strip the `!! ` marker;
- drop cache paths (`__pycache__`, `*.pyc`, `.pytest_cache`);
- treat an ignored file that is byte-identical to the same path under `$MAIN` as NOT precious;
- print whatever remains (one path per line).

- [ ] **Step 3: Implement `cleanup()`**

Signature: `cleanup()` — no arguments, no return value contract beyond "prints a phase line per action". Body follows `fa-ship.sh:194-245` with these substitutions:

- `origin/main` → `origin/$DEFAULT_BRANCH` (assigned once to a local `upstream`).
- `$BR`/`$WT`/`$MAIN` already exist; `cd "$MAIN"` is already in effect.
- The backup root is `${RTC_BACKUP_DIR:-$HOME/.claude/backups/worktrees}`.
- Guard at the top: `[ "$WT" = "$MAIN" ] && { echo "⚠ cleanup: $WT is the canonical checkout — not touched" >&2; return 0; }`.
- The fa-ship `config/config.local.sh` special case is REPLACED by the generalized byte-identical rule inside `cleanup_extra()` — do not carry the free-agents path over.

- [ ] **Step 4: Call it after the post-release hook, before the final phase**

```bash
if [ "${RTC_SKIP_CLEANUP:-0}" != 1 ]; then
  cleanup || echo "⚠ cleanup failed; the release itself is done" >&2
fi
phase "done — ${PREFIX}${V} is live"
```

- [ ] **Step 5: Run the rehearsal tests and confirm they PASS**

Run: `bash tests/test_ship_rehearsal.sh`
Expected: PASS, with the new `cleanup:` phase lines visible in `$D/out` on the happy path.

- [ ] **Step 6: Run the whole suite**

Run: `for t in tests/test_*.sh; do bash "$t" || exit 1; done`
Expected: all 8 suites green (baseline was 184 checks).

- [ ] **Step 7: Commit**

```bash
git add bin/rtc-ship.sh tests/test_ship_rehearsal.sh tests/test_rtc_ship.sh
git commit -m "feat(ship): reap the shipped worktree and stale merged branches after a confirmed release"
```

---

### Task 3: Prove each guard can FAIL (negative controls)

**Files:**
- Test: `tests/test_ship_rehearsal.sh` (mutations are manual, reverted after)

**Interfaces:**
- Consumes: everything from Task 2.

- [ ] **Step 1: Mutation — drop the `in_wt` guard from the local sweep**

Expected: the "merged branch held by another worktree survives" assertion goes RED.
- [ ] **Step 2: Mutation — drop the `$DEFAULT_BRANCH` skip**

Expected: a test asserting the default branch survives goes RED (add that assertion first if absent).
- [ ] **Step 3: Mutation — make `cleanup_extra()` print nothing always**

Expected: the "precious file is backed up" assertion goes RED (data-loss guard fails open).
- [ ] **Step 4: Mutation — remove the `$WT = $MAIN` guard**

Expected: the canonical-checkout no-op assertion goes RED.
- [ ] **Step 5: Revert every mutation, re-run the suite, confirm GREEN**

Run: `for t in tests/test_*.sh; do bash "$t" || exit 1; done`

---

### Task 4: Version bump, CHANGELOG, README

**Files:**
- Modify: `.claude-plugin/plugin.json`, `CHANGELOG.md`, `README.md`

**Interfaces:**
- Consumes: none.

- [ ] **Step 1: Bump both version surfaces to `0.9.0`**

`.claude-plugin/plugin.json` `"version"` and the `CHANGELOG.md` top heading `## 0.9.0`. New capability ⇒ minor bump.

- [ ] **Step 2: Write the CHANGELOG entry**

Say what changed AND correct the historical claim: the 0.7.0 entry listed "worktree cleanup" as part of the loop; it was dropped in the generalization from `fa-ship.sh` and never ran. Do not edit the 0.7.0 entry — fix forward here.

- [ ] **Step 3: Update `README.md`'s ship section** (around lines 195–215) to list cleanup as a step, name `RTC_SKIP_CLEANUP`, and note that merged remote refs are deleted.

- [ ] **Step 4: Verify the surfaces agree**

Run: `bash bin/rtc-ship.sh --versions-only "$PWD"`
Expected: `version surfaces agree`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json CHANGELOG.md README.md
git commit -m "docs: 0.9.0 — ship-time cleanup lands, and the 0.7.0 claim finally becomes true"
```

---

### Task 5: Ship it

**Files:** none (workflow only).

**Interfaces:** the run-to-completion ship loop, executed from this worktree.

- [ ] **Step 1: Dogfood pre-merge from the branch** — run the new routine against a scratch repo *before* merging, per the ship loop's own rule.
- [ ] **Step 2: Push the branch and open nothing yet; run the full ship** `bin/rtc-ship.sh <this worktree> 0.9.0 "<title>"`.
- [ ] **Step 3: Confirm the tag is VISIBLE** — `get-haiggoh plan` (or `hooks/check-tag-visibility.py <repo-url> 0.8.3`); re-check once after ~60 s before treating a negative as real.
- [ ] **Step 4: Confirm the installed copy is 0.9.0 and exercise it** — the shipped `rtc-ship.sh` on PATH still has no cleanup until this lands; verify the installed copy reports the new version and `--help` prints `RTC_SKIP_CLEANUP`.
- [ ] **Step 5: Reap this worktree with the routine just shipped** — the first real consumer of the feature.
