---
description: Comment-hygiene pass on the working-tree diff, then git add -A and commit with a headline-only message.
---

One pass. No iterative refinement.

1. `git status` and `git diff` to see what's about to land.
2. Comment-hygiene pass on `.lua` files in the diff. Run `tools/comment_hygiene.py` — it flags `--invariant:`/`--contract:`/`--emits:`/`--reaper:` lines >100 chars (`--shape:` exempt) and contiguous WHY-comment runs >2 lines, only where an added line participates. Fix each violation it names. Longer WHYs move to `docs/<file>.md` with a one-line pointer at the site. Don't audit comments the script didn't flag.
3. `git add -A`.
4. `git commit -m "<scope>: <headline>"` — headline only, no body, ≤70 chars, imperative, scoped to the affected area (eg `tm: fix off-by-one in selection rect`). No `Co-Authored-By`, no Claude tagline.
5. Stop. Don't push, don't offer to push.

Clean tree → say so and stop.
