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

7. Spawn one subagent — Agent tool, `subagent_type: general-purpose`, `model: sonnet` — and hand it the headline. It owns everything else and does **not** spawn further subagents. Prompt it as follows. If the scope from step 1 is narrower than "all dirty files", amend the `git add -A` line correspondingly.

> You are finishing a commit. Do these in order, then stop.
> 1. `git status` and `git diff` to see what's landing.
> 2. Comment-hygiene pass. If there are any `.lua` files dirty in the tree, run `tools/comment_hygiene.py` from the repo root. It flags `--invariant:`/`--contract:`/`--emits:`/`--reaper:` lines >100 chars, `--shape:` lines >400 chars, and contiguous WHY-comment runs >2 lines. Fix every violation it names; trim to load-bearing content, or move a longer WHY to `docs/<file>.md` with a one-line pointer at the site. Don't revert the comment or delete the WHY wholesale; the content must survive in compliant form. Touch only comments the script flags. Re-run until clean, then apply the fixes with `mcp__patches__apply_patches` (the only write tool available in this environment). Stage every fix from one hygiene run in a single call (`edits[]` spans files); call again only for what the next re-run turns up.
> 3. `git add -A`.
> 4. `git commit -m "<HEADLINE>"`, no commit body.
> 5. Report the hygiene fixes (one line each) and the commit hash. Don't push, don't offer to.
>
>    If the user sent you instructions directly while you were working (a message mid-run, or hunk `feedback:` returned by `apply_patches`), say so explicitly in the report (call them "the user", not "you"): quote or paraphrase what they asked and what you did about it. The parent agent cannot see your conversation and will otherwise read the change as yours.

8. When it returns, eyeball its summary; no need to re-audit.
