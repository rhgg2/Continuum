---
description: Implement the plan's Now brief — red spec first, brief kept current, suite green.
---

1. Read `plan/CURRENT` → the live `plan/___.md`. Don't follow the
   `source:` link to the design doc. If it's empty, say so, point at
   `/plan-next`, stop.
2. Work from the brief: open the anchors it names (maps first), write
   the red spec first when it calls for one, implement, suite green
   via `lua_test_run`.
3. The design doc stays closed — the brief was compiled to be
   sufficient. When it isn't, escalate by the size of the gap:
   - **Mechanical** — anchors drifted, a local renamed, a range moved:
     reconcile against the code and carry on. No ceremony.
   - **Tactical** — the brief needs a decision it didn't settle, but
     the design intent is clear enough to settle locally: propose the
     settlement to the user and if approved, continue.
   - **Design** — the code contradicts the design doc's model, or the
     item dissolves or splits on contact: stop implementing. Surface
     it; the fix is a design-doc conversation and a `/plan-next`
     re-run, not an implementation detour. Demote the brief back to
     Queued with a one-line note of what broke.
4. Done is the brief's own definition plus a green suite: remind to
   commit, once (`/commit` carries the landing bookkeeping). If you
   stop short of done, leave the brief amended to reflect actual
   state, including any tactical escalations, before ending.
