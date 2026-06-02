---
description: Comment-hygiene pass on the working-tree diff, then git add -A and commit with a headline-only message.
---

One pass. No iterative refinement.

1. `git status` and `git diff` to see what's about to land.
2. Run the `comment-hygiene` skill with no arguments (diff mode); let it run to completion, then eyeball its summary — don't re-audit.
3. `git add -A`.
4. `git commit -m "<scope>: <headline>"` — headline only, no body, ≤70 chars, imperative, scoped to the affected area (eg `tm: fix off-by-one in selection rect`). No `Co-Authored-By`, no Claude tagline.
5. Stop. Don't push, don't offer to push.

Clean tree → say so and stop.
