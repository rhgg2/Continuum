---
name: commit
description: Complete commit bookkeeping and spawn a subagent for the mechanical steps.
disable-model-invocation: true
---

## 1. Size the commit and decide the headline

Size up the commit from `git status --porcelain` and `git diff --stat
HEAD`, injected for you by a hook. Empty status means clean tree,
so stop. 

Otherwise, check for the changes you expect; for an `/implement-next`
pass, these include changes to the design document and plan from the
previous session's `/plan-next`.
   
Scope your commit to the expected files, and nothing more: there may
be parallel work happening in the tree.

Decide the headline; you have the intent from the session, and the
injected stat for scope. The format is `<scope>: <headline>`,
imperative, ≤70 chars, scoped to the affected area (eg `tm: fix
off-by-one in selection rect`). `config:` is the scope for Claude
Code's own machinery — skills, hooks, settings, agents, and tools.

## 2. Docs pass

The hook names the docs related to code you touched, as well as all
cross-cutting docs.

Where the model moved, the doc and code annotations move in the same
commit. Check if a change is needed, and if so, apply it in one
`apply_patches` call and add the changes to the scope from step 1.

## 3. Commit bookkeeping

Assemble a commit bookkeeping JSON manifest for the bookkeeping
script.

- **Decision log** (`decision` key). Any design decision needs
  recording. Write it in the manifest's `decision` key; the script
  dates it, wraps it, and prepends it to `design/decisions.md`. Read
  `docs/STYLE.md` first for the register. If a commit makes no design
  decision, omit the key.
  
- **Plan** (`land` key). If `plan/CURRENT` exists and this commit
  completes the live plan's Now entry, include `land: {headline,
  ref}`.
  
  The script prepends `- <date> <headline> (<ref>)` to Landed, prunes
  it below ~4, empties Now, and deletes the implementation brief
  `plan/IMPL.md`, echoing its title as it goes.
  
  An optional `now` overrides the empty placeholder, for a landing
  that leaves something behind. Commits unrelated to the live plan
  omit the key.

If the manifest is non-empty, apply it thus:

```sh
python3 tools/bookkeep.py <<'JSON'
{"date":"2026-07-22",
 "decision":"one or two lines of prose; the script formats it",
 "land":{"headline":"tm: …","ref":"§ 3"}}
JSON
```

## 4. The commit

If you changed no `.lua` files, you may as well commit yourself: `git
add <scope> && git commit -m "<headline>"`, no commit body.

Otherwise, spawn a `commit-finisher` subagent and hand it the headline
(and to be clear, there is still no commit body) plus which paths to
stage, if the scope from steps 1 and 2 is narrower than "all dirty
files".

The agent runs a comment hygiene pass then commits. When it returns,
eyeball its summary; no need to re-audit.
