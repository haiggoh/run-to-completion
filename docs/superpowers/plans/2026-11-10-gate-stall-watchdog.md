# rtc-ship gate stall watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan
> task-by-task (native: one executor does every task, one final review). Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** a stuck test gate in `rtc-ship.sh` ends in a named `STALLED` failure with a diagnosis file within a
bounded time, instead of waiting forever at 0% CPU — and no gate command can block on an inherited stdin.

**Architecture:** every gate command (repo `test_cmd`, default pytest, `.rtc/pre-flight.sh`) runs in the
background with `</dev/null`, supervised by ONE function, `watch_gate`, that samples the log size and the
cumulative CPU time of the command's own process tree. Neither advancing for `stall_seconds` ⇒ write a
diagnosis, kill only that tree, return 124. Optional `RTC_BASELINE=1` re-runs a failed gate on the default
branch and labels each failure branch-only or pre-existing (diagnosis only — the gate still fails).

**Tech stack:** bash 3.2-compatible (macOS `/bin/bash`), `ps -o`, `pgrep -P`, shell test suites in `tests/`.

**Spec:** user decision 2026-11-10 (session 9b087437): "fix both rtc-ship and the free-agents test fixtures for
good so we don't have to remember workarounds" — layer 3 of 3. Evidence: memory
`ship-gate-wedge-and-env-leaking-tests` (wedge measured 2026-11-06/07: bash at 0% CPU, log frozen, a
direct `pytest -n auto` wedged the same way for 75 min). Layers 1–2 (free-agents per-test timeouts with
stack dumps, hermetic test env) are a separate plan.

## Global Constraints

- Bash 3.2 compatible: no `declare -A`, no `${var,,}`, no `wait -n`, no `mapfile`.
- Never print process argv (`ps -o args`/`command`, `pgrep -a`/`-fl`): argv can carry API keys. Use `comm`.
- Kill ONLY descendants of the gate's own pid; never `pkill`/`killall`/by name.
- An explicit override that is SET but invalid aborts with a message naming it (`RTC_STALL_SECONDS`,
  `stall_seconds`), never falls back to the default.
- Defaults: `stall_seconds` = 600 (generous: a healthy free-agents gate prints within seconds and finishes in
  ~5 min), poll = 15 s. Precedence: `RTC_STALL_SECONDS` env > rtc-ship.json `stall_seconds` > 600.
  `RTC_STALL_POLL` exists for tests only (documented as such).
- Exit code 124 for a stall (the `timeout(1)` convention), distinct from a test failure.
- The no-known-errors policy is unchanged: a pre-existing failure still fails the gate.

## Review Focus

1. A long, silent but CPU-busy test (a 10-minute computation printing nothing) must NOT be killed — CPU
   time advancing counts as progress (Task 1 test `busy_silent_is_not_a_stall`).
2. A gate that sleeps while printing a heartbeat line must NOT be killed (Task 1 `logging_sleep_is_not_a_stall`).
3. Processes the gate did not start (a concurrent session's `sleep`, another ship) survive a stall kill
   (Task 1 `kill_spares_foreign_processes`).
4. A test reading stdin gets EOF instead of hanging, whatever stdin `rtc-ship.sh` itself was given
   (Task 2 `config_gate_stdin_is_dev_null`).
5. The baseline run never changes the verdict and never touches the canonical checkout or the shipped
   worktree (Task 3 `baseline_reports_but_still_fails`, `baseline_leaves_no_worktree`).

## 🚨 Standing rules for the executor — read before anything else

You are a free-lane session with no chat history. This file is your whole brief. Rules:

1. Work ONLY in `~/ClaudeWorkspace/.wt/rtc-stall-watchdog` (branch `feat/gate-stall-watchdog`). Never `cd`
   into, edit, or switch the branch of `~/ClaudeWorkspace/run-to-completion` (the canonical checkout: the
   installed `rtc-ship.sh` shim and every ship resolve through it).
2. **Highest boundary granted: local commits on `feat/gate-stall-watchdog`.** No push, no merge, no tag, no
   release, no version bump beyond Task 4's local commit, no `claude plugin update`, and never run
   `bin/rtc-ship.sh` against a REAL repo — only `--test-only` / `--versions-only` on scratch repos the tests
   create, and `--bump-versions .` / `--versions-only .` / `--help` in this worktree.
3. Never edit the installed plugin cache (`~/.claude/plugins/cache/...`) or `~/.local/bin/rtc-ship.sh`.
4. Stage BY PATH (`git add <file>…`), never `git add -A` / `.`; check `git diff --cached --stat` before each commit.
5. Never print process argv: no `ps aux`, `ps -o args`/`command`, `pgrep -a`/`-fl`. Use `ps -o pid,ppid,stat,etime,time,comm`.
6. Kill only processes YOUR tests started, by pid. Never `pkill`/`killall`, never touch ports 4141-4151 or
   8000-8010 (inference endpoints serving live sessions, possibly yours).
7. Tool names are case-sensitive: the shell tool is `Bash`. Never pass a JSON payload as a `Write` content
   string — write JSON through `Bash` with a quoted heredoc (`cat > f <<'EOF' … EOF`).
8. Test runs: targeted suites in the foreground (each finishes in seconds). Any run that may exceed ~5
   minutes goes to the background with a log (`… > /tmp/x.log 2>&1; echo exit=$? >> /tmp/x.log`): a
   silent foreground call over ~10 min kills your session.
9. Read results from the result line or the `exit=` line, never from a pipeline (`| tail` hides the exit
   code). "Not run" is reported as not run, never as passed.
10. Known-bad mutations: copy the file first (`cp f /tmp/f.good`), mutate, confirm it landed
    (`cmp -s` must DIFFER), run, restore, confirm `cmp` identical. A mutation that did not land "reports caught".
11. Never weaken or delete an assertion to make a run green. If an assertion contradicts a fact, inspect the
    instrument (the test harness) first.
12. On any unexpected failure: STOP that task, diagnose, fix, rerun, and show BOTH runs in the receipt.

## 📌 Facts (labelled)

- *confirmed live 2026-11-10:* worktree `~/ClaudeWorkspace/.wt/rtc-stall-watchdog` exists on branch
  `feat/gate-stall-watchdog` from `origin/main` = `c0763c8` (run-to-completion 1.1.0); this plan is its
  first commit (`029f456`). Canonical checkout clean on `main`.
- *confirmed live:* `gates()` is `bin/rtc-ship.sh:359-427`; the config `test_cmd` path runs in the FOREGROUND
  with no stdin redirect (`:389`), while the default pytest path (`:398-399`) and pre-flight (`:381`) use
  `</dev/null`. `run_logged` is `:72-84`; `phase` is `:66`; the header env doc block is `:38-56` and `--help`
  prints the header via `usage()` (`:64`).
- *confirmed live:* this repo's own gate: rtc-ship.json `test_cmd` = `parallel --will-cite -j 12 bash ::: tests/test_*.sh`;
  GNU parallel is at `/opt/homebrew/bin/parallel`. Shell test harness pattern: `tests/test_gates.sh`
  (`mkrepo`, `gate`, `ok/bad/is/has`, stubbed `$HOME/.local/bin/pytest` under a scratch HOME).
- *confirmed live:* no `py-spy` on this machine; do not depend on it.
- *decision:* `/bin/bash` is 3.2.57 here. `timeout`/`gtimeout` exist on THIS machine only via Homebrew coreutils;
  rtc-ship is published, so neither the script nor its tests may depend on them. The tests' 30 s guard is
  plain bash: run the gate in the background, a background `sleep 30` + `kill` of that pid, `wait`.
- *decision (user + planner, 2026-11-10):* NO soft dependency on `timeout(1)`, not even "use it when present".
  (1) It is a fixed wall-clock deadline, the wrong signal: it kills a slow healthy suite and still makes a
  stuck one wait the full time — the watchdog decides on PROGRESS (log + CPU). (2) Two behaviours = the
  fallback goes untested on this machine. (3) GNU `timeout` signals its direct child; xdist grandchildren
  can survive — `watch_gate` kills the whole tree explicitly.
- *decision (playbook `~/.claude/plans/_playbooks/Playbook-split-monolithic-test-suites.md`):* the new tests
  are SPLIT from the start. Each stall case waits ≥ stall window + poll + kill grace, so one file would take
  ~90 s while the repo's whole parallel gate runs in ~18–32 s — it would become the floor of every gate.
  Rig in `tests/lib/stall_rig.sh` (NOT matched by `tests/test_*.sh`; sourced; each file its own `mktemp -d`;
  one shared summary function computing the exit status). Files by theme, each ≤ the repo's next-slowest
  file (measure in Phase 0): `tests/test_stall_detect.sh` (stall named, `.stall` content, no argv leak,
  `tree_cpu` parsing), `tests/test_stall_progress.sh` (busy-silent, logging-sleep — the "not a stall" cases),
  `tests/test_stall_scope.sh` (foreign processes survive, bad overrides abort), `tests/test_gate_supervision.sh`
  (Task 2: stdin, pre-flight + default-pytest stalls), `tests/test_gate_baseline.sh` (Task 3). Wherever the
  plan below says `tests/test_stall_watchdog.sh`, put the case in the matching themed file instead.
- *decision:* tests-only knob `RTC_STALL_KILL_GRACE` (seconds between TERM and KILL, default 5; documented
  "tests only" like `RTC_STALL_POLL`); tests set it to 1.
- *dated observation (2026-11-06/07, memory):* real free-agents gates wedged at 0% CPU with a frozen log; root
  cause never identified. Do not claim this plan fixes that cause — it makes the stall visible and bounded.
- *unknown to inspect in Phase 0:* exact `ps -o time=` format on this macOS (expected `m:ss.cc`), and
  whether `pgrep -P` is present (it is on macOS; confirm).

## 🔒 Authority matrix

| Operation | Status |
|---|---|
| Read anything in the worktree; run tests; scratch repos under `mktemp -d` | allowed now |
| Edit files in the worktree; local commits on `feat/gate-stall-watchdog` | allowed now (rule 4) |
| `/offload` dispatches (free-agents `free-agent-tool.py`) for QC milestones | allowed now (free lanes only) |
| Start/kill processes | only ones your own tests start, by pid (rules 5-6) |
| Push the branch, merge, tag, release, refresh the installed plugin | **prohibited** — the reviewing session ships after the user approves |
| Any paid model call, downloads, credential changes, edits outside the worktree | **prohibited** |

**Side effects:** the tests start background `sleep`/`python3` processes, FIFOs and scratch git repos (with
a local bare `origin` in Task 3). All live under `mktemp -d` and die with the test (`trap … EXIT` kills the
test's own pids and removes its dirs). Nothing touches the network, real repos, or real config.

---

### Phase 0 — preflight (no edits)

- [x] Write exactly three sentences: what Task 1 adds, how Tasks 2–3 depend on it, and what a user sees on
      the next stalled ship once Task 4 is done.
- [x] `pwd` = the worktree; `git status --porcelain` empty; `git log --oneline -2` shows `029f456` on `c0763c8`.
- [x] Probe the unknowns: `sleep 5 & ps -o time= -p $!; pgrep -P $$ >/dev/null; echo pgrep=$?` — record the format.
- [x] Baseline, both green, results recorded (also time EACH tests/test_*.sh alone — the split playbook needs the per-file table): `bash tests/test_gates.sh; echo exit=$?` and the repo gate
      `parallel --will-cite -j 12 bash ::: tests/test_*.sh > /tmp/rtc-base.log 2>&1; echo exit=$?`.
- [x] `python3 ~/.claude/plugins/cache/haiggoh/free-agents/*/bin/free-agent-tool.py --list` (pick the highest
      version dir): record which free reviewer lanes are available for the QC milestones. None ⇒ say so
      and continue; the reviewing session then runs the QC dispatch itself.
- **🧪 Receipt 0:** the three sentences, the outputs above, baseline result lines.

### Task 1: `watch_gate` — the supervisor

**Files:** modify `bin/rtc-ship.sh` (new functions after `run_logged`, header env docs lines 38–56);
create `tests/test_stall_watchdog.sh` (harness copied from `tests/test_gates.sh`: `mkrepo`, `gate`, `ok/bad/is/has`).

**Interfaces — produces:**
- `stall_seconds() → prints the resolved seconds or exits 1 naming the bad source` (env > config > 600).
- `tree_pids <pid> → prints pid and every descendant pid, one per line` (recursive `pgrep -P`).
- `tree_cpu <pid> → prints the summed cumulative CPU time of tree_pids in CENTISECONDS` (`ps -o time= -p`,
  parse `[[dd-]hh:]mm:ss[.cc]` — macOS prints e.g. `0:00.01`; a vanished pid contributes 0). Centiseconds,
  not seconds: a slow but working gate at ~0.05% CPU gains under 1 s per 600 s window, and whole
  seconds would read that as a stall. Test `tree_cpu_parses_ps_time` pins `0:00.01`→1, `1:02.50`→6250,
  `1-02:03:04`→9338400 via a stubbed `ps`.
- `watch_gate <label> <log> <pid> → rc`: waits for `<pid>`; returns its exit status when it exits; returns
  124 after a stall, having written `<log>.stall` and killed the tree (TERM, then KILL after 5 s).
  Stall = both `wc -c <log>` and `tree_cpu <pid>` unchanged across consecutive samples spanning
  ≥ `stall_seconds`; samples every `${RTC_STALL_POLL:-15}` s.
- `<log>.stall` content: one header line `STALLED <label>: no output and no CPU for <N>s`, the tree as
  `ps -o pid=,ppid=,stat=,etime=,time=,comm=` (NEVER args), then `tail -n 30 <log>`.

- [x] **Step 1: tests** in `tests/test_stall_watchdog.sh`, each case a fresh `mkrepo` whose rtc-ship.json
      `test_cmd` is set as named, run as `RTC_STALL_SECONDS=3 RTC_STALL_POLL=1 rtc-ship.sh --test-only <dir>`:
  - `stall_is_named`: `test_cmd = "sleep 300"` → rc ≠ 0 in under 30 s wall time; output has
    `STALLED tests (config)`; the kept log dir holds `main.stall` whose first line starts `STALLED` and
    whose body lists `sleep`; afterwards `pgrep -P` of nothing — assert no `sleep 300` child of the gate
    survives (record the gate's sleep pid via a pidfile the test_cmd writes: `echo $$ > pid; exec sleep 300`).
  - `busy_silent_is_not_a_stall`: `test_cmd = "python3 -c 'import time;t=time.time()\nwhile time.time()-t<8: pass'"`
    → rc 0, no `STALLED`.
  - `logging_sleep_is_not_a_stall`: `test_cmd = "for i in 1 2 3 4 5 6 7 8; do echo tick; sleep 1; done"` → rc 0.
  - `kill_spares_foreign_processes`: start `sleep 300 &` in the TEST (outside the gate), then the stall case;
    the foreign pid is still alive afterwards (`kill -0`), then the test kills it.
  - `bad_override_aborts`: `RTC_STALL_SECONDS=abc` → rc ≠ 0, stderr names `RTC_STALL_SECONDS`;
    rtc-ship.json `"stall_seconds": 0` → names `stall_seconds`.
  - `no_args_leak`: the `.stall` file does not contain the test_cmd's secret-looking argv
    (`test_cmd = "exec sleep 300 SECRET_TOKEN_x"` → `.stall` lacks `SECRET_TOKEN_x`).
- [x] **Step 2:** run `bash tests/test_stall_watchdog.sh; echo exit=$?` → FAIL (watchdog absent: the stall case
      runs until the harness's own 30 s guard kills it — the harness MUST wrap each gate in a 30 s guard so
      the red run terminates).
- [x] **Step 3:** implement the four functions in `bin/rtc-ship.sh`; document `RTC_STALL_SECONDS`,
      `RTC_STALL_POLL (tests only)` and the `stall_seconds` config key in the header env block.
- [x] **Step 4:** tests green. **Known-bad discriminants** (one at a time, then restore, `cmp` against a copy):
      (a) make `tree_cpu` print `0` always → `busy_silent_is_not_a_stall` RED; (b) drop the `wc -c` term →
      `logging_sleep_is_not_a_stall` RED; (c) kill by `pkill sleep` instead of the tree → `kill_spares_foreign_processes` RED.
- [x] **Step 5:** commit `feat(rtc-ship): watch_gate — a silent, CPU-idle gate ends as a named STALLED failure`.

### Task 2: every gate runs supervised, stdin detached

**Files:** modify `bin/rtc-ship.sh` `gates()` (lines 359–427); extend `tests/test_stall_watchdog.sh`.

**Interfaces — consumes:** `watch_gate` (Task 1). **Changes:** the config path stops running in the
foreground: `bash -c "$test_cmd" </dev/null >"$d/main" 2>&1 &` then `watch_gate "tests (config)" "$d/main" $!`;
the default pytest path and `.rtc/pre-flight.sh` are supervised the same way (labels `pytest main`,
`pre-flight gates`), pre-flight still concurrent with the main suite. A 124 from any gate prints
`✖ <label> STALLED — diagnosis in <log>.stall` and fails the gate; logs are kept as today.

- [ ] **Step 1: tests:**
  - `config_gate_stdin_is_dev_null`: run `--test-only` with its OWN stdin held open by a FIFO that nobody writes
    (`mkfifo f; exec 3<>f; rtc-ship.sh --test-only d <f`), `test_cmd = "read -r x; echo got=[$x]"` →
    rc 0 within 10 s, log has `got=[]`.
  - `preflight_stall_is_named`: `.rtc/pre-flight.sh` = `exec sleep 300` → output has `STALLED pre-flight gates`.
  - `default_pytest_stall_is_named`: no test_cmd, stub `$HOME/.local/bin/pytest` = `exec sleep 300` →
    `STALLED pytest main`.
  - existing `tests/test_gates.sh` stays green (pre-flight still concurrent).
- [ ] **Step 2:** run → `config_gate_stdin_is_dev_null` FAILS (blocks until the harness guard) — this is the
      pre-fix reproduction; record it.
- [ ] **Step 3:** implement; **Step 4:** green + known-bad: remove `</dev/null` from the config path →
      `config_gate_stdin_is_dev_null` RED. **Step 5:** commit `fix(rtc-ship): gate commands get /dev/null stdin and run under watch_gate`.

### Task 3: `RTC_BASELINE=1` — label failures branch-only vs pre-existing

**Files:** modify `bin/rtc-ship.sh` (new `baseline_classify <log>` called from `gates()` only when a gate
failed AND `RTC_BASELINE=1`); extend tests; README + header docs.

**Interfaces — produces:** `baseline_classify <failed-log>`: `git worktree add --detach "$tmp" origin/<default>`
(default via `resolve_default_branch`), runs the SAME gate command there under `watch_gate` with label
`baseline`, then prints `branch-only:` and `pre-existing:` lists — lines matching
`^(FAILED|ERROR) ` (pytest) or `^  FAIL ` (this repo's shell suites), compared with `comm` on the
`::`/name part — and removes the worktree in a `trap`. It never changes `rc`.

- [ ] **Step 1: tests** (scratch repo with a bare `origin`, default branch whose `test_cmd` prints
      `FAILED t::a` and exits 1; branch prints `FAILED t::a` and `FAILED t::b`):
  - `baseline_reports_but_still_fails`: rc ≠ 0; output has `branch-only:` then `t::b`, and `pre-existing:` then `t::a`.
  - `baseline_off_by_default`: without `RTC_BASELINE`, no `branch-only:` line and no extra worktree.
  - `baseline_leaves_no_worktree`: `git worktree list` count unchanged after the run, also when the baseline
    itself stalls (`RTC_STALL_SECONDS=3`, baseline `test_cmd` sleeps).
- [ ] **Step 2–5:** red, implement, green + known-bad (swap the `comm` columns → labels reversed → RED), commit
      `feat(rtc-ship): RTC_BASELINE=1 labels failed-gate lines branch-only vs pre-existing`.

### Task 4: docs, version, full suite

- [ ] Per-file timing (playbook step 1/6): time each `tests/test_*.sh` alone; record the five slowest. No new
      stall file may be the slowest file in the suite; if one is, split it again by theme. Receipt: the table
      before (Phase 0 baseline) and after, plus the repo gate's wall time before and after.

- [ ] README: a "When a gate stalls" section — what `STALLED` means, where `.stall` lives, `RTC_STALL_SECONDS`,
      `stall_seconds`, `RTC_BASELINE=1`, and that `RTC_SKIP_TESTS=1` is no longer the stall workaround.
- [ ] CHANGELOG `## [1.2.0] — <date> — gate stall watchdog`; `bin/rtc-ship.sh --bump-versions . 1.2.0`;
      `--versions-only .` agrees.
- [ ] `rtc-ship.sh --help` shows the three new env/config entries (RUN it; grep is not proof).
- [ ] Full suite via the repo's `test_cmd`, `; echo exit=$?` → 0. Commit `chore(release): 1.2.0 — gate stall watchdog`.

## 🧪 Receipt format (end of EVERY task)

`pwd`; the exact test command; its result line and `exit=`; each known-bad mutation with the `cmp`-differs
line, its RED result line, and the restore `cmp`-identical line; `git log --oneline -1` after the commit.

## 🔎 Quality-control milestones

Playbook: `~/.claude/plans/_playbooks/Playbook-milestone-qc-offload-test-proof.md` — read it once before
Task 1. Its point: the executor wrote both code and tests, so it is the worst-placed reviewer of whether a
test proves the REQUIREMENT or only its appearance ("declared ≠ delivered").

**Standing rule, verbatim:** *At each milestone, run /offload (free-agents:offload) — a stateless dispatch to
an out-of-family reviewer — with the brief below. Treat its findings as hypotheses: run every proposed
mutation; fix or rebut each finding with evidence. Do not start the next task with an open finding.*

- **Reviewer:** OUT-OF-FAMILY from you (you are Z.ai GLM): pick the strongest non-GLM free lane from Phase 0's
  `--list`. No free lane available ⇒ write that in the receipt and continue; never use a paid model.
- **How:** `python3 <free-agents>/bin/free-agent-tool.py <<'JSON' … JSON` with `{"prompt": <brief>, "files": [<paths>]}`.
  A dispatch cannot read the disk — attach every file it must see (absolute paths).
- **Brief:** copy the "dispatch brief" block from the playbook verbatim, then append the requirements under
  review for that milestone (below), quoted from this plan.

| Milestone | After | Requirements under review | Attach |
|---|---|---|---|
| M1 | Task 1 | stall ⇒ named `STALLED` + `.stall` with tree and log tail, rc 124; busy-silent and logging-sleep are NOT stalls; foreign processes survive; bad overrides abort naming the source; no argv in `.stall`; centisecond CPU parsing | `bin/rtc-ship.sh`, `tests/test_stall_watchdog.sh`, this plan |
| M2 | Task 2 | every gate (config `test_cmd`, default pytest, pre-flight) gets `/dev/null` stdin and runs under `watch_gate`; pre-flight still concurrent | same + `tests/test_gates.sh` |
| M3 | Task 3 | `RTC_BASELINE=1` labels branch-only vs pre-existing, never changes rc, leaves no worktree (also when the baseline stalls); off by default | same |
| M4 | Task 4, before delivery | README/`--help`/CHANGELOG claims match behaviour; every claim in the CHANGELOG entry has a delivery-level test | same + `README.md`, `CHANGELOG.md` |

**Playbook hard rules applied to this plan:**
1. *Declaration ≠ proof.* "`watch_gate` exists" or "the header documents `RTC_STALL_SECONDS`" proves nothing:
   the proof is a real stalled command ending with `STALLED` and the `--help` OUTPUT showing the entry (RUN it).
2. *Reachability from the shipped entry point.* Every Task 1–3 behaviour has ≥1 test that goes through
   `bin/rtc-ship.sh --test-only <scratch-repo>` with default wiring — never only a direct call of `watch_gate`.
3. *Your explanation is a claim too.* If you state a cause for any failure, quote the probe whose result FLIPS
   with that cause.
4. *Independent effect check.* You are a free-lane executor, so the reviewing session will itself run one
   real stall through the delivered script before shipping; your receipts must give it the exact command.

**Per-milestone receipt:** reviewer model + route, the verdict table (requirement → PROVEN / WEAK / UNPROVEN /
DECLARED-ONLY → mutation → fixture fix), each proposed mutation with its RED run line, rebuttals citing the
line that proves the reviewer wrong, and the final green run line.

## 🧨 Adversarial review

- Watchdog tested only by calling `watch_gate` directly → green → the real `gates()` path never uses it → a
  stalled ship still hangs → rule 2 above → Task 2's `*_stall_is_named` tests via `--test-only`.
- Stall check on log size only → green on the sleep test → a busy silent suite gets killed mid-run →
  both signals required → `busy_silent_is_not_a_stall` + known-bad (a).
- Kill by name (`pkill sleep`) → green → a concurrent session's processes die → tree kill only →
  `kill_spares_foreign_processes` + known-bad (c).
- `.stall` dumps `ps -o args` for "more context" → green → an API key in a log file → `comm` only →
  `no_args_leak`.
- The red run of Task 1 Step 2 hangs forever (no watchdog yet) → session stalls → each harness gate is
  wrapped in a 30 s guard the TEST owns → Step 2 terminates red.
- A same-width mutation reuses a stale artefact → "caught"/"survived" lies → rule 10 (`cmp` before and after)
  — shell scripts have no bytecode, but a mutated file that was never written still reports caught.
- `RTC_BASELINE` worktree left behind or created in the canonical checkout → disk clutter or a dirty
  canonical → `trap` cleanup + `baseline_leaves_no_worktree`, created under `mktemp -d` only.
- Task 4 version bump read as permission to ship → a release nobody approved → rule 2 (local commit only).

## 🏁 Final delivery (write at the end, then STOP)

1. Per task: commit SHA and its receipt; the Task 2 Step 2 pre-fix reproduction (the stdin hang, red).
2. Per milestone: the QC receipt (or "no free reviewer lane — not run").
3. Implemented vs planned: anything not done, and why.
4. Not verified: the watchdog against a REAL free-agents wedge (only its next ship can show that).
5. Confirm: nothing pushed, merged, tagged, released or refreshed; canonical checkout untouched
   (`git -C ~/ClaudeWorkspace/run-to-completion status --porcelain` empty, still on `main`).
6. **Highest boundary reached: local commits on `feat/gate-stall-watchdog`.** Hand back to the user.
