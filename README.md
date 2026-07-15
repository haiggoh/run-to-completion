# run-to-completion

A Claude behavior rule: **offer to run elaborate multi-step work to completion,
without stopping between steps.** When a task is a big multi-step plan or spans
several open projects, and most of the needed information is already gathered,
this steers Claude to:

1. **Offer** continuous, autonomous execution — not silently start doing it.
2. If accepted: **ask blocking, matter-of-taste questions up front**, then run
   without pausing between steps.
3. **Fold in** any mid-run prompts at the next natural task seam, instead of
   letting them derail the plan.
4. **Reserve stops** for decisions that genuinely can't be weighed with pros and
   cons — otherwise decide and note the reasoning.

It does **not** relax the separate, standing rule about confirming destructive or
hard-to-reverse actions (deletes, force-pushes, publishing, shared infrastructure).
Autonomy here means "don't stop me to ask about routine next steps," not "skip
safety confirmations."

## Why

This mode worked well in practice across several long, multi-part sessions — the
back-and-forth of asking permission before every routine step slowed things down
without adding real signal, once requirements were already clear. Turning it into
a portable plugin (rather than leaving it as one project's local `CLAUDE.md` rule)
makes it available anywhere, and toggleable independently of everything else.

## Install — Claude Code (one-click)

```
/plugin marketplace add haiggoh/claude-code-desktop-sync
/plugin install run-to-completion@haiggoh
```

> The `haiggoh` marketplace catalog is hosted in the
> [`claude-code-desktop-sync`](https://github.com/haiggoh/claude-code-desktop-sync) repo
> (it lists several `haiggoh` plugins). Add the marketplace once from there, then install
> `run-to-completion` by name. This repo ships the plugin itself, not a marketplace catalog.

You get:
- a `run-to-completion` **skill** (visible in `/skills`, zero token cost until
  invoked) carrying the full offer/execute/fold-in/reserve procedure, and
- a one-line, stateless **SessionStart hook** that reminds Claude the skill exists
  so it fires at the moment the mode becomes relevant. No markers, no first-run
  pass — it's purely reactive.

## Install — Claude Desktop / claude.ai (copy-paste)

These apps have no plugin marketplace. Open
[`templates/custom-instructions.md`](templates/custom-instructions.md) and paste the
rule block into **Settings → Custom Instructions** (or a Project's instructions).

## License

MIT © Heiko Brantsch
