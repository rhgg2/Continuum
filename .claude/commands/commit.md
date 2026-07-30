---
description: Complete the commit bookkeeping, write a headline here, then spawn a subagent for the purely mechanical steps.
---

## Preliminaries

1. Size up the commit from `git status --porcelain` and `git diff --stat HEAD`, injected for you by a hook. Empty status means clean tree, so stop. Otherwise, check for the changes you expect; for an `/implement-next` pass, these include changes to the design document and plan from the previous session's `/plan-next`. Scope your commit to the expected files, and nothing more: there may be parallel work happening in the tree.
2. Decide the headline; you have the intent from the session, and the injected stat for scope. The format is `<scope>: <headline>`, imperative, ≤70 chars, scoped to the affected area (eg `tm: fix off-by-one in selection rect`).

## Commit bookkeeping

The next steps assemble a commit bookkeeping JSON manifest (steps 3-5) and apply it via `tools/bookkeep.py` (step 6).

3. Decision log (`decision` key). Any design decision needs recording. If the live task has a design doc, write a dated note **there**, by hand. If there is no design doc, write the decision as plain prose and place in the manifest's `decision` key; the script dates it, wraps it, and prepends it to `design/decisions.md`. If a commit makes no design decision, omit the key.
4. Plan (`land` key). If `plan/CURRENT` exists and this commit completes the live plan's Now entry, include `land: {headline, ref, now}`: the script prepends `- <date> <headline> (<ref>)` to Landed, prunes it below ~4, and replaces the Now body with your `now` note. Commits unrelated to the live plan omit the key.
5. Jot triage (`wonder` key). If `tools/wonder.py` spooled anything, the hook injects it; give each jot a verdict in the order shown, `keep` / `drop` / `replace: <the fuller text>`. The default is **keep**, unless the session went on to answer, refute or refine the thought. The array needs exactly one entry per jot, and a mismatch throws an error. For entries you didn't jot yourself (the spool is shared across sessions), **keep**. Jots that records an incident against a `us` claim signal its continuing relevance, so don't drop these. Nothing spooled: omit the key.
6. If any of 3-5 fired, apply the bookkeeping. The manifest comprises whichever keys 3-5 produced: pipe it in on stdin as below and it writes the files directly. The **quoted** `<<'JSON'` delimiter is what stops the shell touching apostrophes, `"` and `$` in your prose, and the closing `JSON` must sit at column 0 or the heredoc never terminates.

```sh
python3 tools/bookkeep.py <<'JSON'
{"date":"2026-07-22",
 "decision":"one or two lines of prose; the script formats it",
 "land":{"headline":"tm: …","ref":"§ 3","now":"(empty — … ; run /plan-next to promote the next commit)"},
 "wonder":["keep","drop","replace: the fuller form, now that the session knows it"]}
JSON
```

## The commit

7. Spawn one subagent — Agent tool, `subagent_type: commit-finisher` — and hand it the headline. The procedure lives in its definition (`.claude/agents/commit-finisher.md`), so the prompt needs only the headline, plus which paths to stage if the scope from step 1 is narrower than "all dirty files".

8. When it returns, eyeball its summary; no need to re-audit.
