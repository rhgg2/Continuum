---
description: Settle the next queued plan item in chat, then compile it into a self-contained, commit-sized Now brief.
---

Synthesis step: compile the next stretch of work from the design doc
into the plan, so implementation sessions read the plan alone. The
compiling is yours; the settling happens in chat with me first.

1. The live plan arrives injected by the `UserPromptExpansion` hook —
   work from that rather than re-reading it. (A plan over the 10k
   context cap arrives as a file path and a preview; read the path.)
   The plan file is a working buffer. Phases, where the plan has one,
   is the human's map; it changes only when the roadmap does. Queued
   holds the incomplete items of the in-flight phase, or in a phaseless
   plan the remainder of the job. Now is the next item to implement.
   Landed prunes below ~4 entries — git and the design doc's dated
   notes are the permanent record.
2. Queued is filled by `/plan-phase` (phased) or by `/plan-new`
   (phaseless); this command never refills it, because sizing a whole
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
4. Study before proposing anything: the relevant sections of the design
   doc named in the `> source:` line, plus the relevant code (maps
   first), until you could implement the item without the doc. The
   search is the expensive part — finding an 80-line seam in a
   5,000-line module costs an order of magnitude more than stating
   where it is — and the brief is its memo.
5. Bring the search to chat and settle the item there, before writing
   any of it down: what the item turns out to involve, the forks the
   search exposed, what you'd do, what you're unsure of. Anything the
   design doc left open is settled here too — the brief records the
   settlement, the design doc gets the dated note.

   This ordering is the point of the command. A brief is written to be
   sufficient for a reader with no conversation behind them, which is
   what makes it slow going for the one person who has one; arriving
   instead as the write-up of a discussion just held, it can be skimmed
   and accepted, which is the only way its review gate is dischargeable
   at all.
6. Write the settlement up as the Now brief. Self-contained means:
   - what and why, two or three sentences;
   - target shapes (data structures, fields) copied in, not pointed at;
   - decisions already settled, restated with their dates;
   - file anchors — tight ranges, current line numbers (the plan will
     be implemented immediately, so no worries over drift);
   - red-spec-first when the item fixes observable behaviour, naming
     the target spec file and fixture;
   - what done looks like: suite green, plus the item's own evidence
     (which walks are gone, what a probe should show).

   Copying shapes in rather than pointing at them is a forcing
   function, not documentation: vagueness survives a conversation and
   does not survive having to write the shape down.
7. Stage the whole plan-file update as one `apply_patches` call.
