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

## Authority

Executor may edit, test and commit on a feature branch in a worktree of `~/ClaudeWorkspace/run-to-completion`.
Ship (merge → tag → release → refresh) only after the user approves the plan's result; ship via the repo's
own `bin/rtc-ship.sh`, depth asked once. No force-push, no tag moves.

---

### Phase 0 — preflight (no edits)

- [ ] `git -C ~/ClaudeWorkspace/run-to-completion status --porcelain` empty, on `main`; create worktree
      `~/ClaudeWorkspace/.wt/rtc-stall-watchdog` on new branch `feat/gate-stall-watchdog` from `origin/main`.
- [ ] Baseline: `bash tests/test_gates.sh; echo exit=$?` and the full `test_cmd` from rtc-ship.json, both
      green. Record the counts.

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

- [ ] **Step 1: tests** in `tests/test_stall_watchdog.sh`, each case a fresh `mkrepo` whose rtc-ship.json
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
- [ ] **Step 2:** run `bash tests/test_stall_watchdog.sh; echo exit=$?` → FAIL (watchdog absent: the stall case
      runs until the harness's own 30 s guard kills it — the harness MUST wrap each gate in a 30 s guard so
      the red run terminates).
- [ ] **Step 3:** implement the four functions in `bin/rtc-ship.sh`; document `RTC_STALL_SECONDS`,
      `RTC_STALL_POLL (tests only)` and the `stall_seconds` config key in the header env block.
- [ ] **Step 4:** tests green. **Known-bad discriminants** (one at a time, then restore, `cmp` against a copy):
      (a) make `tree_cpu` print `0` always → `busy_silent_is_not_a_stall` RED; (b) drop the `wc -c` term →
      `logging_sleep_is_not_a_stall` RED; (c) kill by `pkill sleep` instead of the tree → `kill_spares_foreign_processes` RED.
- [ ] **Step 5:** commit `feat(rtc-ship): watch_gate — a silent, CPU-idle gate ends as a named STALLED failure`.

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

- [ ] README: a "When a gate stalls" section — what `STALLED` means, where `.stall` lives, `RTC_STALL_SECONDS`,
      `stall_seconds`, `RTC_BASELINE=1`, and that `RTC_SKIP_TESTS=1` is no longer the stall workaround.
- [ ] CHANGELOG `## [1.2.0] — <date> — gate stall watchdog`; `bin/rtc-ship.sh --bump-versions . 1.2.0`;
      `--versions-only .` agrees.
- [ ] `rtc-ship.sh --help` shows the three new env/config entries (RUN it; grep is not proof).
- [ ] Full suite via the repo's `test_cmd`, `; echo exit=$?` → 0. Commit `chore(release): 1.2.0 — gate stall watchdog`.

## Final delivery

Per task: commit SHA, test command + result line, each known-bad run's result. The pre-fix reproduction from
Task 2 Step 2. What was NOT verified (the watchdog on a real free-agents wedge happens only on its next ship).
