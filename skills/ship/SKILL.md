---
name: ship
description: 'Use when the user wants to ship ONE branch of ONE repo right now — "/ship", "ship this worktree", "ship the branch I am on". Infers the worktree and branch from the current session (AskUserQuestion only when sitting on the default branch with unmerged branches, or outside any repo), derives the version and release title, then runs that repo''s bin/rtc-ship.sh end to end — gates, merge to the default branch, tag, release, refresh of the plugin, dogfood — and relays every phase verdict. For a whole queue unattended use autopilot; for editing a repo''s rtc-ship.json use ship-config.'
---

# ship — one branch, one repo, shipped all the way out

`rtc-ship.sh` owns the loop; this skill owns the conversation around it: infer what can
be inferred from the session, ask only what genuinely needs a human, run the loop, relay
the verdicts. It does not re-implement any loop step.

## The flow

1. **Which worktree/branch — inferred first, asked only when ambiguous.** Resolve the
   session's own location: `git rev-parse --show-toplevel` and `git branch --show-current`.
   - Inside a repo on a NON-default branch → that worktree and branch are the ship
     target. State them ("shipping `<branch>` in `<toplevel>`") and move on — no question.
   - Inside a repo ON the default branch → list the unmerged branches
     (`git branch --no-merged <default>` plus `git worktree list`) and AskUserQuestion
     which one to ship (header "Branch", option labels `<branch> — <worktree path>`).
   - Not inside any repo at all → AskUserQuestion for the repo path (header "Repo",
     free-text Other), then pick the worktree from `git -C <path> worktree list`.
   The default branch is resolved, never assumed (`bin/rtc-ship.sh --which-config`),
   and a worktree is the only safe ship target — never the canonical checkout.
2. **Version and title — derived, not asked.** Read the target repo's declared manifest
   (rtc-ship.json `manifest`, default `.claude-plugin/plugin.json`) and its top CHANGELOG
   entry: version = `X.Y.(Z+1)`; title = the CHANGELOG entry's text after the date, else
   the first line of `git log <default>..HEAD`. Print both. AskUserQuestion only when the
   derivation is genuinely ambiguous (header "Version/title", first option "use the
   derived `<version>` / `<title>`").
3. **How far may it go — always asked once.** AskUserQuestion, header "Depth", with the full loop as the
   first option: gates → merge to the default branch → tag → release → refresh → dogfood.
   Other options: "through the merge only" and "gates only (`--test-only`)". A ship that
   stops short of the default branch is not yet obtainable by installers — say so when
   the user picks a shorter depth.
4. **Run it.** From the target repo's root:
   `bash bin/rtc-ship.sh <worktree-dir> <version> "<title>"` (append `--no-reap` only if
   the user asks to keep the worktree). Stream the phase output to the user as it goes.
   On a non-zero exit, report the failing phase and the tail the script already printed,
   and STOP — do not retry blindly; say what has to be fixed first (a red gate, a dirty
   canonical checkout, a version-surface split).
5. **Inspection modes first, when asked:** `--which-config` (what the repo resolves
   today), `--versions-only` / `--check-versions` (the gate alone, writes nothing),
   `--bump-versions <dir> <version>` (rewrite only the declared surfaces). Offer these as
   a first AskUserQuestion choice when the user says "check" rather than "ship".

## Rules that still apply

- The canonical checkout must be clean on the default branch when the config sets
  `require_default_branch_checkout` — back up any foreign dirt byte-identically, never
  discard it.
- Never force-push; a published tag that is wrong moves only with the user's explicit
  approval (delete + recreate), otherwise fix forward in the next version.
- Ask the depth question every time — an earlier "you may push" does not cover merge,
  tag or release.

## When NOT to use

- A whole standing queue to clear unattended — that is `autopilot`.
- Editing or inspecting a repo's `rtc-ship.json` — that is `ship-config`.
- A repo with no `bin/rtc-ship.sh` — say so and stop; do not improvise a loop by hand.
- The user only wants to read state (no ship intended) — use the inspection modes in
  step 5 and stop there.

## Branding (🏃)

When you begin working under this skill, lead your first substantive reply with
"🏃 ship:" so the user can see which plugin just became active.
