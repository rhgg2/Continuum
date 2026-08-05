---
name: commit
description: Complete the commit bookkeeping, write a headline here, then spawn a subagent for the purely mechanical steps.
disable-model-invocation: true
---

## Preliminaries

1. Size up the commit from `git status --porcelain` and `git diff
   --stat HEAD`, injected for you by a hook. Empty status means clean
   tree, so stop. Otherwise, check for the changes you expect; for an
   `/implement-next` pass, these include changes to the design
   document and plan from the previous session's `/plan-next`. Scope
   your commit to the expected files, and nothing more: there may be
   parallel work happening in the tree.
2. Decide the headline; you have the intent from the session, and the
   injected stat for scope. The format is `<scope>: <headline>`,
   imperative, ≤70 chars, scoped to the affected area (eg `tm: fix
   off-by-one in selection rect`).

## Commit bookkeeping

The next steps assemble a commit bookkeeping JSON manifest (steps 3-4)
and apply it via `tools/bookkeep.py` (step 5).

3. Decision log (`decision` key). Any design decision needs recording.
   If the live task has a design doc, write a dated note **there**, by
   hand. If there is no design doc, write the decision as plain prose
   and place in the manifest's `decision` key; the script dates it,
   wraps it, and prepends it to `design/decisions.md`. Either way it
   is prose to be read cold later, so `docs/STYLE.md` applies. If a
   commit makes no design decision, omit the key.
4. Plan (`land` key). If `plan/CURRENT` exists and this commit
   completes the live plan's Now entry, include `land: {headline,
   ref}`: the script prepends `- <date> <headline> (<ref>)` to Landed,
   prunes it below ~4, empties Now, and deletes the implementation
   brief `plan/IMPL.md`, echoing its title as it goes. An optional
   `now` overrides the empty placeholder, for a landing that leaves
   something behind. Commits unrelated to the live plan omit the key.
5. If 3 or 4 fired, apply the bookkeeping. The manifest comprises
   whichever keys 3-4 produced: pipe it in on stdin as below and it
   writes the files directly.

```sh
python3 tools/bookkeep.py <<'JSON'
{"date":"2026-07-22",
 "decision":"one or two lines of prose; the script formats it",
 "land":{"headline":"tm: …","ref":"§ 3"}}
JSON
```

## The commit

6. If you changed no `.lua` files, you may as well commit yourself:
   `git add <scope> && git commit -m "<headline>"`, no commit body.

7. Otherwise, spawn a subagent — Agent tool, `subagent_type:
   commit-finisher` — and hand it the headline. The agent runs a
   comment hygiene pass then commits; its procedure lives in its
   definition (`.claude/agents/commit-finisher.md`), so the prompt
   needs only the headline, plus which paths to stage if the scope
   from step 1 is narrower than "all dirty files". When it returns,
   eyeball its summary; no need to re-audit.
