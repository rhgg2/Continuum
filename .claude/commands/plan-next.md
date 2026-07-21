---
description: Promote the next queued plan item into a self-contained, commit-sized Now brief.
---

Synthesis step: compile the next stretch of work from the design doc
into the plan, so implementation sessions read the plan alone.

1. Read `plan/CURRENT` → the live plan file `plan/<name>`. Read it and
   the design doc named in its `> source:` line.
2. Take the top Queued item. Study its design-doc section plus the
   relevant source (maps first) until you could implement it without
   the doc.
3. Size check — two duties, before promoting:
   - **Commit-sized**: one landable change, spec included. An item
     that is really two or more commits gets split into ordered Queued
     lines; promote only the first.
   - **≤150k context**: the brief must name tight file/line ranges so
     an implementation session works from the brief plus those ranges
     alone. If it can't, split further.
4. Write the Now brief. Self-contained means:
   - what and why, two or three sentences;
   - target shapes (data structures, fields) copied in, not pointed at;
   - decisions already settled, restated with their dates;
   - file anchors — tight ranges, current line numbers (drift is fine;
     briefs live days, not weeks);
   - red-spec-first when the item fixes observable behaviour, naming
     the target spec file and fixture;
   - what done looks like: suite green, plus the item's own evidence
     (which walks are gone, what a probe should show).
5. If the design doc leaves open a decision the brief needs, surface
   it and settle it with the user before promoting. The brief records
   the settlement; the design doc gets the dated note.
6. Housekeeping in the same pass. Queued is a partial buffer of the
   in-flight phase, so an empty queue means one of two things:
   - the phase still has unqueued work → refill Queued with
     commit-sized one-liners from that phase's design-doc section;
   - the phase is complete (nothing left in its section, last item
     landed) → mark the phase landed in Phases, move the ← in-flight
     marker to the next phase, and seed Queued from its section.
7. Stage the whole plan-file update as one `apply_patches` call — the
   user reviews the compiled brief hunk by hunk.

The plan file is a working buffer. Landed prunes below ~4 entries —
git and the design doc's dated notes are the permanent record. Queued
holds the current phase only. Phases is the human's map; it changes
only when the roadmap does.
