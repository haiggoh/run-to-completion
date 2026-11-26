# Real-window tooling (run-in-terminal + launch-claude-session) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task (NATIVE: the executor implements every task in its own session, then one final whole-branch review). Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** in-progress

> **Lasting Plans:** when every task below is done, set the Status line to `completed` by running `lasting-plans complete "<this file>"` as the closing step.

**Naming (decision 2026-11-26):** no `rtc` prefix on the commands, module, env vars, state dir or skill, so they can move into their own plugin later without renames.

**Goal:** Ship the user's two private window scripts as run-to-completion plugin commands — `run-in-terminal` (run any command in a REAL Terminal window and verify the outcome) and `launch-claude-session` (open a verified Claude Code session that LEARNS how the calling session was launched) — plus a skill so every installer's Claude knows when to use them.

**Architecture:** `bin/run-in-terminal` is a bash-3.2 port of `~/.claude/scripts/sudo-in-terminal.sh` with a generic banner. `bin/launch-claude-session` is a Python port of `~/.claude/scripts/claude-window` whose joyia-specific backend is replaced by route DETECTION: walk the process ancestry to the calling `claude`, classify its parent (wrapper vs shell), and probe `claude auth status --json` in a clean env for a plain login. Detection lives in `bin/claude_launch_route.py` (pure functions + thin collectors) so tests feed fixtures. A new skill `skills/terminal-handoff/` and one sentence in `hooks/nudge.sh` carry the "when to use / never fake it" knowledge.

**Tech Stack:** bash 3.2-compatible shell, Python 3 stdlib, AppleScript via `osascript` (macOS Terminal.app only), framework-free shell test suites (repo convention).

**Spec:** this conversation's decisions, recorded on waypoint `generic-verified-window` (`waypoints.py show generic-verified-window`) and restated under Global Constraints. Source scripts: `~/.claude/scripts/sudo-in-terminal.sh` (188 lines), `~/.claude/scripts/claude-window` (271 lines) — not in any git repo (confirmed live 2026-11-26).

## Global Constraints

1. Repo is PUBLIC (confirmed live: `gh repo view` → PUBLIC). No string `joyia`, no internal hostnames, no `/Users/`, no `~/.claude/` paths may appear in `bin/`, `skills/`, `hooks/`, README or CHANGELOG. (decision)
2. Default route = INHERIT the calling session's credentials (user rule 2026-11-26). A different route only on explicit `--route`, with a printed NOTICE when it differs from the caller's.
3. A normal Anthropic login (no route env, clean-env `claude auth status --json` → `loggedIn: true`) is a first-class route: launch plain `claude` and copy NO credential variables. (decision)
4. Credentials and process argv never appear on a command line, in Terminal history, in output, or in a stored file. Launcher words are kept only if every kept token matches `^[A-Za-z0-9._/-]{1,40}$` and none is key-shaped (`^(sk-|ghp_|gho_|eyJ)` or ≥ 32 chars of `[A-Za-z0-9+/_=-]`); otherwise the launcher is `unavailable (unsafe token)` and nothing of it is printed.
5. Every script supports `--help` (runs nothing), exits 2 with a stderr usage line on an unknown flag, and an explicit-but-invalid override (env var or flag) aborts naming it.
6. Shell: `#!/usr/bin/env bash`, bash 3.2-compatible (no `declare -A`, no `${x,,}`). macOS only: on non-Darwin, exit 2 with `run-in-terminal: needs macOS Terminal.app`.
7. Verdict vocabulary is preserved exactly: `ALREADY_SATISFIED`, `WINDOW_ID=`, `VERIFIED after Ns`, `NOT_VERIFIED`, `EXITED_EARLY`, `OPENED`, `STARTED pid=… session=… route=… lane=…`, `REPLIED`, `NOT_STARTED`, `NO_REPLY`, `SESSION_EXITED`. Exit codes: 0 verified · 1 not verified · 2 usage.
8. Version: 1.6.4 → **1.7.0** (new feature), in `.claude-plugin/plugin.json` and a new top CHANGELOG entry. Ship only via `bin/rtc-ship.sh` from this worktree.
9. Skills test rules (`tests/test_skills.sh`): no other plugin's name, no machine paths, a "when NOT to use" section.

## Authority matrix

| Operation | Authority |
|---|---|
| Edit/commit on `feat/real-window` in `~/ClaudeWorkspace/.wt/rtc-real-window`; push that branch | allowed now |
| Run tests with stubbed `osascript`/`ps`/`claude` on PATH, temp HOME | allowed now |
| Merge to `main`, tag `v1.7.0`, GitHub release, plugin refresh — via `rtc-ship.sh` | allowed after gate G1 (full suite green + final review findings fixed) — user granted "through release" 2026-11-26 |
| Dogfood: open REAL Terminal windows, start real Claude sessions (spends gateway tokens, a few cents each) | allowed after release, ≤ 4 launches total |
| Replace `~/.claude/scripts/{sudo-in-terminal.sh,claude-window}` with shims; edit `~/.claude/CLAUDE.md` | needs separate user OK — show the diff first (user asked for that) |
| Force-push, move a published tag, edit the plugin cache, kill/restart any process, print argv or credential values | prohibited |

**Highest granted boundary: RELEASE + dogfood.** Nothing past that.

## Review Focus

1. **Transparent wrappers** — claude started via `env`, `nohup`, `caffeinate`, `arch`, `time` must not be mistaken for a gateway wrapper: skip them while walking up. (test: T2 `transparent-env`)
2. **Node-hosted claude** — npm installs show `comm=node` with `…/claude` or `cli.js` in args; still recognised as the claude ancestor. (test: T2 `node-claude`)
3. **Called from outside any Claude session** (a plain terminal, launchd) — no claude ancestor: use the LEARNED route file if present, else the login probe, else exit 2 naming both. (test: T3 `outside-session-learned`)
4. **Login shells** — `-zsh`, `login`, `tmux`, `screen` parents count as DIRECT, not wrappers. (test: T2 `login-shell-dash`)
5. **Planted secret** — a key-shaped token in the wrapper argv or an `ANTHROPIC_AUTH_TOKEN=sk-planted…` value must appear in no output, no dry-run line, no learned file. (test: T2 `unsafe-token`, T3 `no-secret-in-output`)

---

## Phase 0 — Preflight (no mutation)

- [ ] Write three sentences: how Task 1 leads to the release, what "dogfood verified" means here, and what stays out of scope (project-launcher consumer, shims and CLAUDE.md need user OK).
- [ ] Confirm checkout: `git -C ~/ClaudeWorkspace/.wt/rtc-real-window rev-parse --abbrev-ref HEAD` → `feat/real-window`; `git status --porcelain` → empty except this plan.
- [ ] Baseline: `parallel --will-cite -j 12 bash ::: tests/test_*.sh` → record EXIT and FAIL count (dated observation 2026-11-26: running in background at plan time). A pre-existing failure is reported, never shipped around.
- [ ] Inspect (unknown): does `scripts/build-portable.py` / `portable/PORTABLE-BUILD.json` need a component entry for `bin/` or the new skill, and does any test enforce it? Record the answer before Task 4.
- [ ] Tools: `command -v osascript parallel python3 jq claude` all present.

Receipt: branch name, porcelain output, baseline EXIT line, portable answer.

### Task 1: `bin/run-in-terminal` (generic real-window runner)

**Files:** Create `bin/run-in-terminal`; Test `tests/test_window.sh`; Test fixture `tests/lib/fake_osascript.sh`.

**Interfaces — Produces:** CLI `run-in-terminal --command CMD [--verify TEST] [--timeout S] [--watch S] [--label TEXT]`; stdout verdict lines per Global Constraint 7; `WINDOW_ID=<n>` on stdout. Env read: none (test seam is PATH).

- [ ] Write `tests/lib/fake_osascript.sh`: installed into a temp dir as `osascript`; appends each `-e` script to `$FAKE_OSA_LOG`; returns `42` for a `do script`; for `get busy` prints the next line of `$FAKE_OSA_BUSY` (default `true`); for `get history` cats `$FAKE_OSA_HISTORY`. Plus a fake `uname` printing `$FAKE_UNAME` (default `Darwin`).
- [ ] Write `tests/test_window.sh` cases (failing first): `help-runs-nothing` (`--help` exit 0, `$FAKE_OSA_LOG` absent); `unknown-arg` (exit 2, stderr names it); `missing-value` (`--label` alone → exit 2, no hang: wrap in a 5 s guard); `already-satisfied` (`--verify true` → `ALREADY_SATISFIED`, log absent); `verified` (verify `[ -f $T/flag ]`, fake busy creates the flag on 2nd read → `VERIFIED`); `exited-early-masked` (busy `false,false`, history contains `sk-abcdef1234567890XYZ` → stderr has `EXITED_EARLY` and `sk-<masked>`, not the key); `label-apostrophe` (label `this session's` → logged script contains the shlex-quoted banner); `non-darwin` (`FAKE_UNAME=Linux` → exit 2 `needs macOS Terminal.app`); `generic-banner` (logged script contains `=== Claude opened this window to <label> ===`, and NOT `password`).
- [ ] Run `bash tests/test_window.sh` → FAIL (no `bin/run-in-terminal`).
- [ ] Port `sudo-in-terminal.sh` into `bin/run-in-terminal`: shebang per GC6; Darwin check before anything but `--help`; banner `Claude opened this window` (+ ` to <label>`); help text says it covers sudo/password prompts and any TTY need; everything else (arg loop, ALREADY_SATISFIED, `busy` polling, masked tail) unchanged.
- [ ] Run → PASS. **Known-bad:** temporarily drop the `sk-` mask sed in a COPY under `$TMPDIR`, point the test at it via `RIT_BIN` (test-only variable in the test file, not the script) → `exited-early-masked` must go red. Receipt: both runs.
- [ ] Commit `bin/run-in-terminal tests/test_window.sh tests/lib/fake_osascript.sh` — `feat: run-in-terminal — run a command in a real Terminal window and verify it`.

### Task 2: `bin/claude_launch_route.py` (route detection)

**Files:** Create `bin/claude_launch_route.py`; Test `tests/test_launch_route.sh`.

**Interfaces — Produces:**
- `Proc = TypedDict(pid:int, comm:str, args:list[str])`
- `Route = dataclass(kind: Literal['wrapper','env','login','none'], launcher: list[str] | None, launcher_name: str | None, unsafe_launcher: bool, lane: str, inside_session: bool)`
- `classify(ancestry: list[Proc], env: dict[str,str], logged_in_clean: bool | None) -> Route` — pure. `ancestry[0]` is the script's parent, upward.
- `collect_ancestry() -> list[Proc]` — `ps -o ppid=,comm= -p` per pid; `args` read with `ps -o args=` ONLY for the candidate wrapper, never printed.
- `probe_login_clean() -> bool | None` — `env -i HOME=$HOME PATH=$PATH claude auth status --json`, `loggedIn`; None if claude missing/fails.
- `CREDENTIAL_VARS`, `HAS_CREDENTIAL` — moved verbatim from `claude-window:75-76`.
- CLI for tests: `claude_launch_route.py --classify FIXTURE.json` prints `kind=… launcher=… lane=… inside_session=…` (launcher words space-joined, or `unavailable (unsafe token)`, or `-`).

Rules (decision): claude ancestor = first proc with `basename(comm)=='claude'`, or `basename(comm)=='node'` with an arg ending `/claude` or containing `claude-code`. Above it, skip transparent `{env,nohup,caffeinate,arch,time,sudo}`. Next proc: basename with leading `-` stripped in `{sh,bash,zsh,fish,dash,ksh,tcsh,csh,login,tmux,screen}` or a `.app/Contents/MacOS/` path ⇒ direct; else wrapper. Launcher words = leading args until the first starting with `-` (drops one-shot flags like `--select-key`), checked per GC4. Direct + credential var ⇒ `env`; direct without ⇒ `login` if `logged_in_clean` else `none`. Wrapper ⇒ `wrapper` regardless. No claude ancestor ⇒ `inside_session=False`, kind from env/login as above. `lane` = `ANTHROPIC_BASE_URL` host, `cloud-provider`, or `anthropic-default`.

- [ ] Write `tests/test_launch_route.sh` with fixture cases (failing first): `wrapper-joyia-shape` (`zsh→claude→gw agent claude --select-key→-zsh`, wrapper comm `gw`) → `kind=wrapper launcher=gw agent claude`; `direct-env` → `kind=env`; `direct-login` (`logged_in_clean:true`, no vars) → `kind=login`; `direct-none` → `kind=none`; `transparent-env` (`claude→env→zsh`) → `kind=env`, not wrapper; `node-claude` (`node /x/bin/claude`) found; `login-shell-dash` (`-zsh`) direct; `unsafe-token` (wrapper arg `sk-ABCDEFGHIJKLMNOP1234`) → `launcher=unavailable (unsafe token)` and output does not contain `sk-ABC`; `outside-session` (no claude) → `inside_session=False`.
- [ ] Run → FAIL. Implement. Run → PASS.
- [ ] **Known-bad:** comment out the transparent-skip line in a temp copy → `transparent-env` red. Receipt.
- [ ] Commit — `feat: launch-route detection (wrapper / env / login / none)`.

### Task 3: `bin/launch-claude-session` (verified Claude session)

**Files:** Create `bin/launch-claude-session`; Test `tests/test_claude_window.sh`.

**Interfaces — Consumes:** Task 1 CLI (driver resolved as `os.path.join(os.path.dirname(os.path.realpath(__file__)), 'run-in-terminal')`, never via PATH); Task 2 `classify`, collectors, `CREDENTIAL_VARS`.
**Produces:** CLI = `claude-window`'s options with `--backend inherit|joyia` replaced by `--route auto|inherit|launcher|login`, plus `--route-info` (print detected + learned route, launch nothing). Learned file: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/launch-claude-session/launch-route.json`, mode 0600, keys `kind, launcher, launcher_name, lane, learned_at` — never credential values. Sessions/transcripts dirs also derive from `CLAUDE_CONFIG_DIR`.

Route semantics (decision):
- `auto` (default): inside a session → `wrapper`/`env` ⇒ inherit; `login` ⇒ login; `none` ⇒ exit 2. Outside a session → learned `wrapper` with launcher ⇒ launcher; else login probe; else exit 2 naming the learned file and `claude auth login`. Every inside-session detection rewrites the learned file.
- `inherit`: copy `CREDENTIAL_VARS` via the 0600 env file (as today); exit 2 if none present.
- `launcher`: argv = launcher words + `--` + lean/plugin/extra flags + prompt; exit 2 if no safe launcher. NOTICE when the caller's own kind is not `wrapper`.
- `login`: plain `claude`, NO env file; exit 2 if the clean probe is not `loggedIn`.
- `--lean` = `--strict-mcp-config` (+ `--settings $LAUNCH_CLAUDE_LEAN_SETTINGS` when set; set-but-missing ⇒ exit 2 naming the variable).
- Test seams (documented in `--help` as test-only): `LCS_TEST_ANCESTRY_JSON`, `LCS_TEST_LOGIN_CLEAN` (`true|false`), `LCS_TEST_DRIVER`.

- [ ] Write `tests/test_claude_window.sh` (temp `CLAUDE_CONFIG_DIR`, fake driver that records argv and creates a fake session JSON): `help-runs-nothing`; `unknown-arg`; `route-info-wrapper` → `route=wrapper launcher=gw agent claude`; `auto-wrapper-inherits` (dry-run shows env-file part + `claude`); `auto-login-no-env` (dry-run has no `. <0600 env file>` and no `inherits:`); `auto-none-exit2`; `launcher-dryrun` → `gw agent claude -- …`; `launcher-unavailable-exit2`; `no-secret-in-output` (`ANTHROPIC_AUTH_TOKEN=sk-planted-0123456789abcdef`: dry-run, route-info and learned file contain no `sk-planted`); `learned-file-0600` (`stat -f %Lp` → `600`); `outside-session-learned` (no claude in ancestry, learned wrapper → launcher argv); `lean-settings-invalid` (set to missing path → exit 2 names `LAUNCH_CLAUDE_LEAN_SETTINGS`); `started-verdict` (fake driver + fake session → `STARTED … route=inherit`).
- [ ] Run → FAIL. Port `claude-window`, swapping backend logic for the above. Run → PASS.
- [ ] **Known-bad:** in a temp copy, make `login` route also write the env file → `auto-login-no-env` red. Receipt.
- [ ] Commit — `feat: launch-claude-session — verified Claude session on the learned launch route`.

### Task 4: Skill, nudge, docs, version

**Files:** Create `skills/terminal-handoff/SKILL.md`; Modify `hooks/nudge.sh` (append one sentence), `tests/test_nudge.sh`, `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json` (version 1.7.0 + description clause); portable files only per the Phase 0 answer.

- [ ] Skill `terminal-handoff`: description fires on "needs a password/sudo/TTY", "interactive login or prompt", "the user should watch it run", "open a new Claude session/window", "MCP test needs a full interactive session". Body: the two commands and verdicts; the rule *never approximate a real window with a headless or backgrounded run*; always pass `--verify` when an outcome is checkable; route table (auto/inherit/launcher/login) and that auto inherits; "When NOT to use": anything the Bash tool can run directly, headless `-p` jobs, non-macOS.
- [ ] Nudge: append `For anything needing a real terminal (a password or sudo prompt, an interactive login, a session the user should watch), use run-in-terminal / launch-claude-session from this plugin instead of a headless look-alike.` — add a `test_nudge.sh` case pinning `run-in-terminal`.
- [ ] README section "Real windows", CHANGELOG `## [1.7.0] - 2026-11-26` entry, plugin.json bump.
- [ ] Run the full suite: `parallel --will-cite -j 12 bash ::: tests/test_*.sh` → EXIT:0; `grep -rniE 'joyia|/Users/|~/\.claude/' bin skills hooks README.md CHANGELOG.md` → no output (planted check first: the grep must hit a temp file containing `joyia`).
- [ ] Commit — `chore: terminal-handoff skill, nudge line, docs, bump to 1.7.0`; push branch.

### Task 5: Gate G1, ship, dogfood

- [ ] Final whole-branch review (`/code-review high` over `main...feat/real-window`) plus one free stateless cross-check dispatch of the diff (local:review). Fix Critical/Important red→green.
- [ ] Ship: `rtc-ship.sh ~/ClaudeWorkspace/.wt/rtc-real-window 1.7.0 "real-window tooling"` (script path from the installed run-to-completion cache). Verify `git ls-remote --tags origin v1.7.0` and `gh release view v1.7.0`. Use `git -C` after — a successful ship reaps the worktree.
- [ ] Dogfood through the INSTALLED copy (≤ 4 launches): (a) `run-in-terminal --command 'touch $TMPDIR/rw-ok' --verify '[ -f $TMPDIR/rw-ok ]' --label 'dogfood'` → VERIFIED; (b) `launch-claude-session --route-info` from this session → `route=wrapper` with launcher words; (c) `launch-claude-session --prompt 'Reply with exactly OK'` → STARTED + REPLIED; (d) `--route launcher --prompt 'Reply with exactly OK'` → STARTED + REPLIED (assumed: the wrapper forwards args after `--`; this step verifies it).
- [ ] Seam for user OK: show the shim diff for `~/.claude/scripts/{sudo-in-terminal.sh,claude-window}` (timestamped backups first; shims resolve the newest installed plugin version by numeric sort, never PATH, and map the old `--backend joyia` to `--route launcher`, `--backend inherit` to `--route inherit`) and the CLAUDE.md "Admin rights" trim diff. Apply only on a yes.
- [ ] Waypoints: close `generic-verified-window` with evidence (tag, test counts); add `project-launcher launch subcommand → launch-claude-session` follow-up.

Receipt: suite EXIT lines, ls-remote/release output, dogfood verdict lines, waypoint ids.

## Adversarial review

- Run tests against the private `~/.claude/scripts` originals → green while the plugin bins are broken → shipped dead commands → tests call `bin/` by repo path only → `help-runs-nothing` uses `$ROOT/bin/…`.
- Read argv to "debug" detection → key lands in the transcript → leak → print only masked structure → `unsafe-token`, `no-secret-in-output`.
- Detect wrapper by name `joyia` → passes here, fails every other gateway, leaks the name → structural rule only → GC1 grep + `wrapper-joyia-shape` uses comm `gw`.
- Login users refused (today's bug) → "no credentials to inherit" → normal users locked out → `login` route → `auto-login-no-env`.
- Pipeline hides a failing suite → `| tail` exit 0 → shipped red → redirect to file, read `EXIT:` line.
- Version bumped in plugin.json only → tag-visibility check reads stale → rtc-ship door + CHANGELOG pin catch it.
- Dogfood skipped because version string matched → live-and-inert → Task 5 dogfood (c)/(d) require REPLIED.

## Delivery questions (answer at the end)

What shipped vs only planned? Which receipts ran? Were the user's private scripts and CLAUDE.md left untouched unless approved? Did the run stop at release + dogfood?

Closing step: `lasting-plans complete "docs/superpowers/plans/2026-11-26-real-window-tooling.md"` (on a `docs/plan-real-window-complete` branch, per plan-airtight end-of-life).
