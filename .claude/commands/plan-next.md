---
description: Promote the next queued plan item into a self-contained, commit-sized Now brief.
---

Synthesis step: compile the next stretch of work from the design doc
into the plan, so implementation sessions read the plan alone.

1. The live plan arrives injected by the `UserPromptExpansion` hook —
   work from that rather than re-reading it. (A plan over the 10k
   context cap arrives as a file path and a preview; read the path.)
   The plan file is a working buffer. Phases, where the plan has one,
   is the human's map; it changes only when the roadmap does. Queued
   holds the incomplete items of the in-flight phase, or in a phaseless
   one-off the remainder of the job. Now is the next item to implement.
   Landed prunes below ~4 entries — git and the design doc's dated
   notes are the permanent record.
2. Queued is filled by `/plan-phase` (programme) or by `/plan-new`
   (one-off); this command never refills it, because sizing a whole
   phase and compiling one brief are different kinds of reading. So an
   empty Queued means the level above needs to run: point at
   `/plan-phase` if the plan has Phases, or at `/plan-close` if it
   doesn't — a phaseless plan with an empty queue is finished work.
   Either way, say so and stop.
3. With Queued non-empty, the goal is to promote its top entry to the
   Now section. Size check — two duties, before promoting:
   - **Commit-sized**: one landable change, spec included. An item
     that is really two or more commits gets split into ordered Queued
     lines; promote only the first.
   - **≤150k context**: the brief must name tight file/line ranges so
     an implementation session works from the brief plus those ranges
     alone. If it can't, split further.
4. Write the self-contained Now brief. Study the relevant sections in
   the design-doc name in the `> source:` line, plus the relevant code
   (maps first), until you could implement it without the doc. That's
   the brief. Self-contained means:
   - what and why, two or three sentences;
   - target shapes (data structures, fields) copied in, not pointed at;
   - decisions already settled, restated with their dates;
   - file anchors — tight ranges, current line numbers (the plan will
     be implemented immediately, so no worries over drift);
   - red-spec-first when the item fixes observable behaviour, naming
     the target spec file and fixture;
   - what done looks like: suite green, plus the item's own evidence
     (which walks are gone, what a probe should show).
5. If the design doc leaves open a decision the brief needs, settle it
   with the user before promoting. The brief records the settlement;
   the design doc gets the dated note.
6. Stage the whole plan-file update as one `apply_patches` call — the
   user reviews the compiled brief hunk by hunk.
