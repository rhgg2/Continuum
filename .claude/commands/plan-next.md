---
description: Promote the next queued plan item into a self-contained, commit-sized Now brief.
---

Synthesis step: compile the next stretch of work from the design doc
into the plan, so implementation sessions read the plan alone.

1. Read `plan/CURRENT` → the live plan file `plan/<name>`. The plan
   file is a working buffer. Phases is the human's map; it changes
   only when the roadmap does. Queued holds the incomplete items of
   the current phase only. Now is the next item to implement. Landed
   prunes below ~4 entries — git and the design doc's dated notes are
   the permanent record.
2. First, some housekeeping on the Queued section. This is a partial
   buffer of the in-flight phase, so an empty queue means one of two
   things:
   - the phase still has unqueued work: so refill Queued with
     commit-sized one-liners from that phase's design-doc section;
   - the phase is complete with its last item landed: so mark the
     phase landed in Phases, move the ← in-flight marker to the next
     phase, and seed Queued from its section.
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
