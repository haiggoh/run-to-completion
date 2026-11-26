---
name: terminal-handoff
description: 'Use whenever a step needs a human at a REAL terminal, which the agent''s shell tool does not have: a sudo or other password prompt ("a terminal is required"), an interactive login or key picker (gh auth login, a cloud SSO login, --select-key), a TTY-only installer or TUI, or anything the user should watch and answer live. Also use to open a NEW interactive Claude Code session for the user (a successor or handoff session, an MCP test that needs a full interactive session, dogfooding in a clean window). Runs `run-in-terminal` / `launch-claude-session`, which open a Terminal.app window and return a VERIFIED outcome instead of the agent guessing. macOS only. Never approximate either with a headless or backgrounded run.'
---

# terminal-handoff — hand a step to a real window, get a verified verdict back

The agent's shell has no TTY and no screen. Two commands on PATH close that gap: each opens
a REAL Terminal.app window and reports a checked verdict, so the agent neither fails on a
prompt nor asks the user to retype a line and report back.

## `run-in-terminal` — any command that needs a human at a terminal

```
run-in-terminal --command "<cmd>" --verify '<shell test that passes only once it worked>' \
                --label "<what this does>" [--timeout S]
```

- **Always pass `--verify` when the outcome is checkable.** With it, an already-true state
  prints `ALREADY_SATISFIED` and opens no window, so the user is never interrupted needlessly.
- Verdicts: `VERIFIED after Ns` (exit 0) · `NOT_VERIFIED` (timed out, exit 1 — the user may
  have walked away; say so) · `EXITED_EARLY` + the window's last lines with tokens masked
  (exit 1) · `OPENED` (no `--verify`: it only proves the window is running).
- Tell the user, in your reply, what the window is waiting for (their password, a login).

## `launch-claude-session` — a new interactive Claude session, proven started

```
launch-claude-session [--prompt "<first message>"] [--cwd DIR] [--lean] [-- <claude flags>]
launch-claude-session --route-info      # what route would be used, launches nothing
```

The route is LEARNED from how the calling session was launched, never configured by name:

| `--route` | What the window runs | When |
|---|---|---|
| `auto` (default) | inside a session: inherit its credentials; on a normal Anthropic login, plain `claude` with nothing copied; outside any session: the shell's own route variables if set, else the learned launcher, else the login | almost always |
| `inherit` | plain `claude` with the caller's route variables (0600 env file, deleted on read) | force the same key |
| `launcher` | the program that started this session (e.g. a gateway CLI), which picks its own key | the user asks for the launcher's own key choice |
| `login` | plain `claude` on the normal login | the user asks for their own login |

Verdicts: `STARTED pid=… session=… route=… lane=<host>` (the session on the opened window's
tty, never a parallel one), then `REPLIED` when a prompt was given and a real reply arrived —
an API error does not count (exit 0). `NOT_STARTED`, `NO_REPLY`, `SESSION_EXITED` (exit 1). A window that opened proves
nothing — report the verdict line, not "launched".

Default is the FULL session (MCP servers, plugins, settings). Use `--lean` only when the user
wants a session without MCP servers.

## Rules

- **Never fake a real window.** A headless `claude -p`, a backgrounded command, or "please run
  this yourself" is a look-alike. If a step needs a TTY or the user's eyes, use these commands.
- Credentials never go on a command line or into output: do not echo, print or paste values
  to "help" the window; the commands carry them safely.
- Report the verdict line verbatim, and say when nothing could be verified.
- `--help` on either command shows every option and environment variable.

## When NOT to use

- The command runs fine in the agent's own shell (no prompt, no TTY need) — just run it.
- A headless batch job is genuinely what the user asked for (`claude -p` in a script).
- Not on macOS (both commands exit 2 there), or the commands are not on PATH (a surface
  without this plugin's command-line tools) — ask the user to run the step instead.

## Branding (🏃)

When you begin working under this skill, lead your first substantive reply with
"🏃 terminal-handoff:" so the user can see which plugin just became active.
