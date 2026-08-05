---
name: plan-new
description: Open a new plan and push it onto the CURRENT stack.
disable-model-invocation: true
---

Compile the design doc passed as an argument into a fresh plan file.
The design doc holds the model and the decisions; the plan holds only
the implementation machinery.

1. A hook injects the CURRENT stack and the `plan/`, `plan/archive/`
   and `design/` listings — work from those. `plan/CURRENT` is a
   stack, newest first: the top line is live, the lines under it are
   parked. Opening a plan **pushes** onto it.
2. If no argument was given, confirm with the user the design doc for
   which a plan should be built.
3. Split the work into phases. Each phase should be approximately 2-4
   commits of <150k context size. One phase is totally acceptable.
4. Write `plan/<slug>.md` to the following skeleton:

   ```markdown
   # <programme> — plan

   > source: `design/<doc>.md` — synthesis compiled from there;
   > don't design here.

   ## Phases

   1. **Phase 1 — <name>** (§ <section>) — <one line>  ← in flight
   2. **Phase 2 — <name>** (§ <section>) — <one line>

   ## Landed  (newest first; prune below ~4)

   (nothing yet)

   ## Now

   (empty — new plan; run /plan-next to split phase 1 into Queued.)

   ## Queued (current phase; one-liners)

   (empty)
   ```
6. Push the new filename onto the top of `plan/CURRENT`.
7. Stage the new plan, the design doc if you wrote one, and the
   CURRENT edit as one `apply_patches` call, then stop and point at
   `/plan-next`. Name the plan you pushed in front of, if there was
   one.
