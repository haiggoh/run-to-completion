---
name: ship-config
description: 'Use when the user wants to inspect or change a repo''s rtc-ship.json — "/ship-config", "ship config", "which version surfaces does this repo declare", "change the roadmap surface". Shows what bin/rtc-ship.sh --which-config resolves today, asks which key to change and to what (AskUserQuestion, current value in the label), validates the value, writes the JSON atomically, then re-runs --versions-only to prove the surfaces still agree. For actually shipping a branch, use ship.'
---

# ship-config — the per-repo ship configuration, visible and editable

`rtc-ship.json` is DATA; this skill makes it readable and changeable without hand-editing
JSON. It never guesses a key: it lists the known keys with their current resolved values,
lets the user pick one via AskUserQuestion, validates the new value, writes atomically,
and proves the result with the repo's own gate.

## The flow

1. **Which repo?** Same worktree picker as `ship`: `git worktree list`, non-canonical
   entries plus the current directory, free-text Other for anything else. AskUserQuestion,
   header "Repo".
2. **Show today's resolution.** Run `bash <repo>/bin/rtc-ship.sh --which-config` and
   `bash <repo>/bin/rtc-ship.sh --versions-only <repo>` from the repo root; paste both
   outputs. A red gate here means: fix the surfaces BEFORE changing the config. The
   `--which-config` output ends with the policy-key source table (repo / template /
   built-in default) and the FULL path of the user-level defaults template — read the
   source column before changing a policy key, so you know whether a repo value is
   overriding the template.
3. **Which key?** AskUserQuestion, header "Key", options from the known set with current
   values in the labels: `tag_prefix`, `manifest`, `changelog`, `version_file`,
   `roadmap`, `extra_version_surfaces`, `assets`, `refresh_plugin`, `test_workers`,
   `default_branch`, `require_default_branch_checkout`, `reap`. Keys starting with `_`
   are comments — never edit them. Free-text Other for a new key.
4. **New value + validation.** AskUserQuestion, header "Value". Validate before writing:
   booleans only `true`/`false`; `test_workers` a positive integer; paths repo-relative
   with no leading `/` and no `..`; `manifest` must name a `.json` file; an empty value
   means "unset" (the surface is then not declared — allowed for `version_file`,
   `roadmap`, `assets`, `refresh_plugin`). `extra_version_surfaces` is a JSON array
   of `{"path", "kind": "json"|"toml-package"|"cargo-lock", "key"?, "crate"?}` —
   validate by parsing, and reject an entry whose declared file is absent (the
   empty-extraction rule). An invalid value aborts with the reason —
   never fall through to the old value.
5. **Write atomically.** Edit the JSON with python (load, set, dump with the file's
   existing indent, tmp + os.replace) — never a regex rewrite of the raw text, and never
   a whole-file rewrite from memory. Print the before/after diff of the key.
6. **Prove it.** Re-run `--which-config` and `--versions-only <repo>`; the gate must be
   green (or red for a pre-existing reason you reported in step 2 — distinguish the two).

## Rules that still apply

- The config lives in the repo being shipped; an installed plugin cache is a derived
  copy — edit the source repo, never the cache.
- `default_branch` is resolved, never assumed: config first, then the remote's own HEAD,
  then `main`. Changing it changes where ships land — say that out loud.
- A declared surface whose file is absent fails the gate (the empty-extraction rule) —
  after adding `roadmap` or `version_file`, the file must exist.

## When NOT to use

- The user wants to ship a branch now — that is `ship`.
- The change belongs in `.rtc/*.sh` (commands), not `rtc-ship.json` (data) — point there
  instead of stuffing commands into the JSON.
- No repo context at all (nothing to attach the config to) — ask which repo first.

## Branding (🏃)

When you begin working under this skill, lead your first substantive reply with
"🏃 ship-config:" so the user can see which plugin just became active.
