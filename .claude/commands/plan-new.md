---
description: Open a new plan — from an existing design doc, or writing a short one from conversation — and push it onto the CURRENT stack.
---

Compile a design doc into a fresh plan file and make it live. The
argument is a design-doc path (`design/<doc>.md`); with no argument the
design doc is written first, from the conversation we have just had.
Every plan has one: the doc holds the model and the decisions, the plan
holds only the machinery.

1. The `UserPromptExpansion` hook injects the CURRENT stack and the
   `plan/`, `plan/archive/` and `design/` listings — work from those.
   `plan/CURRENT` is a stack, newest first: the top line is live, the
   lines under it are parked. Opening a plan **pushes** onto it and
   archives nothing, because what's underneath is parked rather than
   finished; `/plan-close` pops.
2. Establish the design doc.
   - **Argument given** — it exists and holds the model already. Read
     it; don't design here.
   - **No argument** — write it now, from the conversation. It will be
     short, and it is the only record this work will ever have, so
     settle anything still open with me before writing it, and don't
     invent decisions we didn't take. Write it in the register
     (`docs/STYLE.md`), and narrate a plausible path to the design
     rather than presenting the finished thing: the path need not be
     the one we actually took, but the wrong turns we walked past are
     half of what makes the doc worth having.

     ```markdown
     # <slug> — <one-line subject>

     > opened: <date> · status: in flight — `plan/<slug>.md`
     >
     > Designed in conversation rather than in a design round; this doc
     > is the record. The decisions below are settled — if one needs
     > reopening, it reopens here.

     ## The problem

     <two or three paragraphs: what's wrong, and what makes it worth
     more than a couple of commits>

     ## Decisions

     **D1 — <decision>.** <why, and what it rules out>
     ```

     `opened:` is a creation date and never moves; revision history is
     git's. It is what lets `design/` be read in order, so every doc
     carries one — see CLAUDE.md § Programme plans.
3. Decide whether the work has phases. That's a question about
   decomposition, not about how the doc came to be written: a doc with
   an ordered structure of its own gets a **Phases** section derived
   from it — my map, one line per phase, in order, `← in flight` on the
   first, each citing its `§ <section>` — and work that is one
   continuous stretch omits the section entirely.
4. Write `plan/<slug>.md`. One skeleton, phased or not:

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

   Phaseless: drop the Phases section, and Now reads `(empty — new
   plan; run /plan-next to promote the first Queued item.)`.
5. Seed Queued according to step 3. A phased plan leaves it empty —
   splitting phase 1 is `/plan-phase`'s job, and doing it here would
   collapse the same two jobs the commands exist to keep apart. A
   phaseless plan seeds it now with the whole job as ordered
   commit-sized one-liners: there's no phase to refill from later,
   which is exactly why an empty Queued in a phaseless plan means the
   work is done.
6. Push the new filename onto the top of `plan/CURRENT`.
7. Stage the new plan, the design doc if you wrote one, and the CURRENT
   edit as one `apply_patches` call, then stop and point at
   `/plan-phase` (phased) or `/plan-next` (phaseless). Opening a plan is
   not permission to start implementing it. Name the plan you pushed in
   front of, if there was one.
