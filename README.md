# run-to-completion

Claude behavior for **running a queue of open work to completion without stopping** —
and for stopping *well* when the only work left needs a human.

It started as a single rule ("offer to run a big multi-step plan continuously
instead of checking in after every step") and now ships the whole loop as
composable skills: score the queue, execute the autonomous part unattended,
close out with an honest account of what was left and why.

## What you get

| Skill | Phase | Owns |
|---|---|---|
| `autopilot` | whole run | Entry point for "run everything you can while I'm away." Sequences the three phases below as an explicit checklist, plus the up-front kickoff. |
| `triage-for-autonomy` | before | Scores any queue — a to-do list, an issue tracker, plan steps, a persistent open-items store — into **do-now** / **autonomous-but-heavy** / **gated**, recording a gate reason per blocked item. |
| `execute-unattended` | during | Keeping moving: wrap-and-switch the instant something needs a human, reversibility before touching a file, and the ship loop that carries a change through to confirmed-live in the *installed* copy. |
| `close-out-the-run` | after | Reconcile the durable records the run touched, stop cleanly at the gated boundary instead of churning, and write a wrap whose gated list says why each remaining item was left and how to resume it. |
| `ungate-queue` | attended | The other half: walks the **blocked** pile *with* you, turning each gate reason into the one question that releases it. |
| `run-to-completion` | offer | The original rule, for a plan already in view in the conversation: offer continuous execution, ask blocking matter-of-taste questions up front, fold mid-run prompts in at task seams. |

Plus a one-line, stateless **SessionStart hook** that reminds Claude the skills
exist so they fire when the mode becomes relevant. No markers, no first-run pass,
no state written anywhere — purely reactive.

## The shape of a run

```
kickoff  → establish the resource picture, warm any delegate,
           ask every blocking question ONCE
triage   → tier 1 do-now │ tier 2 heavy │ gated (+ reason)
execute  → do tier 1, wrap-and-switch on any gate, re-triage between batches
close    → reconcile records, pause rather than churn,
           wrap with a GATED list + how to resume each item
```

The gated list is the highest-value output. It turns "I stopped" into a menu you
can act on in seconds — and it is nearly free, because triage already recorded
why each item was blocked.

## What this does **not** relax

Autonomy here covers **routine step-by-step continuation**. It is not a license to
skip the standing rule about confirming destructive or hard-to-reverse actions —
deleting data, force-pushing, publishing to a shared or public destination,
changing shared infrastructure. Those confirmations apply at full strength inside
an unattended run, unless you authorized that specific action's scope up front.
`autopilot` deliberately asks for that scope during kickoff so the loop doesn't
stall on it late.

## Independence

Every skill is written in capability terms and names no other plugin. If you have
a persistent open-items store, that's the queue; if you have a local-execution
capability, delegatable steps route to it; if you have a reconciliation
discipline, the closing phase uses it. None of them are required — the skills
work on whatever queue you already keep, including one they didn't create.

## Why

The mode earned its keep across several long multi-part sessions: once
requirements are clear, asking permission before every routine step costs time
without adding signal. Making it a plugin (rather than one project's local
`CLAUDE.md` rule) makes it portable and independently toggleable.

## Install — Claude Code (one-click)

```
/plugin marketplace add haiggoh/get-haiggoh
/plugin install run-to-completion@haiggoh
```

> The marketplace catalog lives in the
> [`get-haiggoh`](https://github.com/haiggoh/get-haiggoh) repo and lists several
> plugins. Add the marketplace once from there, then install `run-to-completion`
> by name. This repo ships the plugin itself, not a marketplace catalog.

## Install — Claude Desktop / claude.ai (copy-paste)

These apps have no plugin marketplace. Open
[`templates/custom-instructions.md`](templates/custom-instructions.md) and paste the
rule block into **Settings → Custom Instructions** (or a Project's instructions).

## Tests

```
bash tests/test_nudge.sh      # hook output contract (needs jq)
bash tests/test_skills.sh     # frontmatter + independence checks
```

## License

MIT © Heiko Brantsch
