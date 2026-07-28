---
description: Split the live plan's in-flight phase into an ordered queue of commit-sized items.
---

Decomposition step, at phase scope: turn the in-flight phase into
ordered commit-sized one-liners in Queued. This reads the design doc at
phase scope and produces a shape for the whole phase; `/plan-next`
reads code and produces one implementable brief. Keeping them apart is
the point of this command existing — run it and stop.

1. The live plan arrives injected by the `UserPromptExpansion` hook —
   work from that rather than re-reading it. (A plan over the 10k
   context cap arrives as a file path and a preview; read the path.)
2. No Phases section means a phaseless plan, whose Queued was seeded
   whole at creation. There is nothing to split: say so and point at
   `/plan-next`, or at `/plan-close` if Queued and Now are both empty
   and the work is finished. Stop.
3. A non-empty Queued means the in-flight phase still has work sized
   and waiting. Say so, point at `/plan-next`, stop — refilling
   mid-phase would re-decide items already sized, and the later ones
   are the ones the earlier ones' landings inform.
4. An empty Queued is a phase boundary. Do the Phases bookkeeping
   first, since it decides which section you're about to split:
   - the in-flight phase's last item has landed, so mark that phase
     landed in Phases (dated, with the commit count if it took
     several) and move the `← in flight` marker to the next phase;
   - if there is no next phase, the programme is done — say so, point
     at `/plan-close`, stop.
5. Split the newly in-flight phase's design-doc section into Queued:
   ordered one-liners, each a landable change with its spec, each
   carrying the *what* in enough detail that `/plan-next` can compile a
   brief from it without re-reading the whole section. Order by what
   the next item needs to exist already. Prefer the split that makes
   each line separately reviewable over the one that makes them equal
   in size.

   Write them in plain sentences, not the compressed register the
   briefs use. Queued is what a cold session and the human both read to
   see what is coming, and the compression buys about a third of the
   length at several times the cost in readability.
6. If the split exposes a decision the design doc leaves open, settle
   it with me before writing the queue. The Queued line records the
   settlement in passing; the design doc gets the dated note.
7. Stage the plan update as one `apply_patches` call, then stop and
   point at `/plan-next`. Don't promote the first item yourself.
