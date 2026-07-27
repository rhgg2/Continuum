---
description: Write the commit headline here, then a subagent runs hygiene + add + commit mechanically.
---

One pass. No iterative refinement.

1. The `UserPromptExpansion` hook injects `git status --porcelain` and `git diff --stat HEAD`; read them there rather than re-running them. Empty status → clean tree; say so and stop. Don't spawn. If this was an `/implement-next` session, there will probably be changes you didn't make to the current design document and plan: that's from the previous session's `/plan-next` so nothing to worry about.
2. Decide the headline yourself: you have the change's intent from this conversation, and the injected stat for scope. The format is `<scope>: <headline>`, imperative, ≤70 chars, scoped to the affected area (eg `tm: fix off-by-one in selection rect`). Don't read the full diff.

Steps 3–4 decide *what* bookkeeping this commit carries — the judgment is yours, and a cold subagent can't make it. Step 5 applies it: you assemble one manifest and `tools/bookkeep.py` does the mechanical part. Author here; apply there.

3. Decision log — the `decision` key. Design rationale is durable in `design/`, and there is one test for where a decision goes: if the live plan has a design doc, the decision is written **there**, by hand, in this same pass — a new `**Dn —**` entry, or a dated note under the section it revises — and it gets no ledger entry, because writing it in both places is what made this ambiguous. The `decision` key is only for a decision with no design doc to belong to (a convention adopted in passing, a trade-off taken outside any planned work): write it as plain prose and the script dates it, wraps it, and prepends it to `design/decisions.md`. Most commits do neither — omit the key.
4. Landing bookkeeping — the `land` key. If `plan/CURRENT` exists and this commit completes the live plan's Now entry (wholly, or its final piece), include `land: {headline, ref, now}`: the script prepends `- <date> <headline> (<ref>)` to Landed, prunes it below ~4, and replaces the Now body with your `now` note. The design-doc revision is **not** the script's job — if the landing settled something design-relevant, revise the design doc by hand in this same pass (dated note, WHY only; don't write "Landed 2026/07/10"). Commits unrelated to the plan: omit the key.
5. Apply the bookkeeping. Assemble the manifest from whichever of 3-4 produced a key (all keys optional; `date` defaults to today) and pipe it in on stdin. It writes the files directly — no review gate, so eyeball them in the subagent's `git diff`. Skip this step when none of 3-4 fired.

   Run it exactly as below: the **quoted** `<<'JSON'` delimiter is what stops the shell touching apostrophes, `"` and `$` in your prose, and the closing `JSON` must sit at column 0 or the heredoc never terminates.

```sh
python3 tools/bookkeep.py <<'JSON'
{"date":"2026-07-22",
 "decision":"one or two lines of prose; the script formats it",
 "land":{"headline":"tm: …","ref":"§ 3","now":"(empty — … ; run /plan-next to promote the next commit)"}}
JSON
```
6. Spawn one subagent — Agent tool, `subagent_type: general-purpose`, `model: sonnet` — and hand it the headline. It owns everything else and does **not** spawn further subagents. Prompt it with:

> You are finishing a commit. Do these in order, then stop — do not spawn any subagent:
> 1. `git status` and `git diff` to see what's landing.
> 2. Comment-hygiene pass (diff mode): run `tools/comment_hygiene.py` from the repo root. It flags `--invariant:`/`--contract:`/`--emits:`/`--reaper:` lines >100 chars, `--shape:` lines >400 chars, and contiguous WHY-comment runs >2 lines. Fix every violation it names — trim to load-bearing content, or move a longer WHY to `docs/<file>.md` with a one-line pointer at the site. NEVER revert the comment to a prior state or delete the WHY wholesale; the content must survive in compliant form. Touch only comments the script flags. Re-run until clean.
>
>    Apply the fixes with `mcp__patches__apply_patches` — the user is at the keyboard and reviews each hunk. Run `ToolSearch select:mcp__patches__apply_patches` first to load the schema; never call it from memory. Stage every fix from one hygiene run in a single call (`edits[]` spans files); call again only for what the next re-run turns up. A lone one-hunk fix may use the built-in `Edit`.
> 3. `git add -A`.
> 4. `git commit -m "<HEADLINE>"` — exactly the headline given, no body, no `Co-Authored-By`, no Claude tagline.
> 5. Report the hygiene fixes (one line each) and the commit hash. Don't push, don't offer to.
>
>    If the user sent you instructions directly while you were working (a message mid-run, or hunk `feedback:` returned by `apply_patches`), say so explicitly in the report (call them "the user", not "you"): quote or paraphrase what they asked and what you did about it. The parent agent cannot see your conversation and will otherwise read the change as yours.

7. When it returns, eyeball its summary — don't re-audit.
