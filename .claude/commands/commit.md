---
description: Write the commit headline here, then a subagent runs hygiene + add + commit mechanically.
---

One pass. No iterative refinement.

1. `git status --porcelain`. Empty → clean tree; say so and stop. Don't spawn.
2. Decide the headline yourself — you have the change's intent from this conversation, a cold subagent wouldn't. `<scope>: <headline>`, imperative, ≤70 chars, scoped to the affected area (eg `tm: fix off-by-one in selection rect`). Glance at `git diff --stat` if you need to confirm scope; don't read the full diff.
3. Spawn one subagent — Agent tool, `subagent_type: general-purpose`, `model: sonnet` — and hand it the headline. It owns everything else and does **not** spawn further subagents. Prompt it with:

> You are finishing a commit. Do these in order, then stop — do not spawn any subagent:
> 1. `git status` and `git diff` to see what's landing.
> 2. Comment-hygiene pass (diff mode): run `tools/comment_hygiene.py` from the repo root. It flags `--invariant:`/`--contract:`/`--emits:`/`--reaper:` lines >100 chars, `--shape:` lines >400 chars, and contiguous WHY-comment runs >2 lines. Fix every violation it names — trim to load-bearing content, or move a longer WHY to `docs/<file>.md` with a one-line pointer at the site. NEVER revert the comment to a prior state or delete the WHY wholesale; the content must survive in compliant form. Touch only comments the script flags. Re-run until clean.
> 3. `git add -A`.
> 4. `git commit -m "<HEADLINE>"` — exactly the headline given, no body, no `Co-Authored-By`, no Claude tagline.
> 5. Report the hygiene fixes (one line each) and the commit hash. Don't push, don't offer to.

4. When it returns, eyeball its summary — don't re-audit.
</content>
</invoke>
