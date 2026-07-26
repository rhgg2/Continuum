---
description: Open a new plan — from a design doc, or from conversation for a one-off — and push it onto the CURRENT stack.
---

Compile a design doc, or the conversation we have just had, into a
fresh plan file and make it live. The argument is a design-doc path
(`design/<doc>.md`); no argument means a one-off — designed in
conversation, with the plan file standing as its own record.

1. The `UserPromptExpansion` hook injects the CURRENT stack and the
   `plan/`, `plan/archive/` and `design/` listings — work from those.
   `plan/CURRENT` is a stack, newest first: the top line is live, the
   lines under it are parked. Opening a plan **pushes** onto it and
   archives nothing, because what's underneath is parked rather than
   finished; `/plan-close` pops.
2. Pick the shape.
   - **Programme** — a design doc exists. The doc keeps the model; the
     plan carries a **Phases** section, which is my map: one line per
     phase, in order, `← in flight` on the first, each citing its
     `§ <section>`. Derive the phases from the doc's own structure.
     Don't design here.
   - **One-off** — no design doc. More than a couple of commits but not
     a programme, so there are no phases. The file opens with **The
     problem** and **Decisions**, compiled from the conversation. That
     preamble is the only record this work will ever have, so settle
     anything still open with me before writing it, and don't invent
     decisions we didn't take. `plan/fx-dest.md` is the model.
3. Write `plan/<slug>.md`. Same skeleton either way, minus Phases for a
   one-off. Programme:

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

   (empty — new plan; run /plan-phase to split phase 1 into Queued.)

   ## Queued (current phase; one-liners)

   (empty)
   ```

   One-off — the source line becomes the record's disclaimer, and the
   preamble sits above Landed:

   ```markdown
   # <slug> — plan

   > No design doc: this work was designed in conversation (<date>) and
   > this file is the record. Decisions below are settled; if one needs
   > reopening, do it here and say so.

   ## The problem

   <two or three paragraphs: what's wrong, and what makes it worth
   more than a couple of commits>

   ## Decisions

   **D1 — <decision>.** <why, and what it rules out>

   ## Landed  (newest first; prune below ~4)

   (nothing yet)

   ## Now

   (empty — new plan; run /plan-next to promote the first Queued item.)

   ## Queued (one-liners)
   ```
4. Seed Queued according to the shape. A programme leaves it empty —
   splitting phase 1 is `/plan-phase`'s job, and doing it here would
   collapse the same two jobs the commands exist to keep apart. A
   one-off seeds it now with the whole job as ordered commit-sized
   one-liners: there's no phase to refill from later, which is exactly
   why an empty Queued in a phaseless plan means the work is done.
5. Push the new filename onto the top of `plan/CURRENT`.
6. Stage the new plan and the CURRENT edit as one `apply_patches` call,
   then stop and point at `/plan-phase` (programme) or `/plan-next`
   (one-off). Opening a plan is not permission to start implementing
   it. Name the plan you pushed in front of, if there was one.
