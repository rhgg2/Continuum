---
description: Comment-hygiene pass on the working-tree diff, then git add -A and commit with a headline-only message.
---

One pass. No iterative refinement.

1. `git status` and `git diff` to see what's about to land.
2. Hand the comment-hygiene pass to a subagent — Agent tool, `subagent_type: general-purpose`, `model: sonnet`. It owns the pass end to end; do not pre-read or fix comments here. Prompt it with:

   > Run `tools/comment_hygiene.py` from the repo root. It flags `--invariant:`/`--contract:`/`--emits:`/`--reaper:` lines >100 chars, `--shape:` lines >400 chars, and contiguous WHY-comment runs >2 lines, only where an added line participates. Fix every violation it names, then re-run until clean. Resolve each violation by trimming the comment to its load-bearing content, or by moving a longer WHY to `docs/<file>.md` with a one-line pointer at the site. NEVER resolve a violation by reverting the comment to a prior state or deleting the WHY wholesale — the content must survive in compliant form. Touch only comments the script flags. Report the files you changed and a one-line note per fix.

   When it returns, eyeball its summary; don't re-audit.
3. `git add -A`.
4. `git commit -m "<scope>: <headline>"` — headline only, no body, ≤70 chars, imperative, scoped to the affected area (eg `tm: fix off-by-one in selection rect`). No `Co-Authored-By`, no Claude tagline.
5. Stop. Don't push, don't offer to push.

Clean tree → say so and stop.
