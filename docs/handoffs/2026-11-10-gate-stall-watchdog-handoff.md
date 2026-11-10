# Handoff: rtc-ship gate stall watchdog (run-to-completion 1.2.0)

## Why this session exists

Written by the planning session (Claude Opus 5.5, cloud) on 2026-11-10. The user chose native execution of
the plan by a free GLM 5.3 Flash session at max effort, NOT by the planning session ("that would be too
expensive"). Nothing has been implemented yet; you start at Phase 0.

## The goal, verbatim (user, 2026-11-10)

> Is there a smarter way how we could fix both rtc-ship and the free-agents test fixures for good so we
> don't have to remember workarounds and don't keep running into these issues?

The user approved "all three layers". This handoff covers **layer 3 only: rtc-ship's gate stall watchdog**.
Layers 1–2 (free-agents per-test timeouts, hermetic test env) are planned separately later — do not start them.

## State

- Worktree `~/ClaudeWorkspace/.wt/rtc-stall-watchdog`, branch `feat/gate-stall-watchdog`, based on
  `origin/main` `c0763c8` (run-to-completion 1.1.0).
- `029f456` — the base plan. `973ae21` — the execution-safety layer + QC milestones. This handoff is the next commit.
- The plan: `docs/superpowers/plans/2026-11-10-gate-stall-watchdog.md`. It is the authoritative brief.
- Another GLM 5.3 Flash session (a different one) is working on the free-agents repo. It is not yours:
  never touch its worktree, its branch or its processes.

## Standing rules (adopt for the whole session)

1. Autonomous: decide and record instead of asking; stop only for forks that cannot be weighed.
2. Execute the plan with `superpowers:executing-plans` (native — you do every task; no subagents, no
   Agent/Task tool). The plan's own "Standing rules for the executor" (12 rules) apply in full — they win
   over anything here that seems to conflict.
3. Work only in this worktree. Never switch the branch of `~/ClaudeWorkspace/run-to-completion`.
4. Commit every task, staged **by path** (never `git add -A`), with your own co-author trailer below the
   Claude line: `Co-Authored-By: GLM 5.3 <noreply@z.ai>` (verbatim from the attribution table) — check the
   running model's identity first; if you are NOT GLM 5.3, use your own model's trailer instead.
5. **Never push, merge, tag, release or refresh the installed plugin.** Highest boundary: local commits.
6. TDD every change (red for the right reason, then green); mutation-check each new guard; never weaken a test.
7. QC milestones M1–M4 via `/offload` to an OUT-OF-FAMILY free reviewer, per the plan's QC section and
   `~/.claude/plans/_playbooks/Playbook-milestone-qc-offload-test-proof.md`. Reviewers hallucinate file names:
   check every finding against the real code.
8. Resolve model and roster facts from the catalog (`free-agent-tool.py --list`), never from memory.
9. Never run `remote-session.sh --stop`, never start another remote session, never kill anything listening
   on 4141–4151 or 8000–8010: one of them is the proxy you run on.
10. Record progress below at EVERY receipt (one line), in the same commit as that task.
11. If you are told to "hand off to a new session", that successor is YOU — continue directly; never launch
    another session.

## Next action

Read the plan file in full, then the playbook once, then do **Phase 0** of the plan: the three sentences,
the read-only checks, the baseline runs, and `free-agent-tool.py --list`. Then Task 1.

## Progress log (append one line per receipt: date time — task/milestone — commit — result line)

- 2026-11-10 — handoff written by the planning session — plan at `973ae21`.
- 2026-11-10 — Phase 0 preflight (rides with Task 1 commit) — clean tree at `9a515e6`; `ps -o time=` = `0:00.00` (mm:ss.cc); `pgrep -P` ok; 19/19 baseline files green, slowest `test_ship_cleanup_rescue` 205s seq, parallel gate 42s; QC reviewer lane: Gemini 3.8 Flash (google, out-of-family).
- 2026-11-10 — Task 1 `watch_gate` + helpers + config-path wiring (commit below) — detect 13/13, progress 4/4, scope 6/6; mutations (a) tree_cpu→0, (b) size-term dropped, (c) pkill-by-name each RED then restored cmp-identical; full gate 22 files exit=0 60s; stall propagates as 124 via --test-only (user: 124 dominates mixed runs).
- 2026-11-10 — M1 QC closed — reviewer Nemotron 3 Ultra 550B (nvidia, out-of-family validator): all 6 requirements PROVEN; 2 findings fixed + mutation-checked (rc==124 pin, exclusive source naming), 1 rebutted (RTC_STALL_POLL scope); free-agent-tool openrouter crash waypointed.
- 2026-11-10 — Task 2: all gates stdin-detached + supervised (commit below) — supervision 9/9, test_gates 28/28, full gate 23 files exit=0 64s; stdin case green from the start (Task 1's `&` already detaches async stdin per POSIX; explicit </dev/null kept as documentation); sharp mutation `<&0` RED then restored cmp-identical.
