---
description: Close or park the live plan — archive it, archive a finished design doc, pop the CURRENT stack.
---

Pop the top of the CURRENT stack and put the files where a finished
programme's files live. This is the only command that archives.

1. The hook injects the live plan, the CURRENT stack and the plan and
   design listings — work from those.
2. Establish which of two things this is, and say so before doing
   anything:
   - **Close** — the work is finished: every phase marked landed
     (phased), or Queued and Now both empty (phaseless). Files move
     to the archives.
   - **Park** — the work is unfinished and attention is moving
     elsewhere. The plan stays in `plan/`, nothing is archived, and
     only the CURRENT line goes. Note in Now what's left, since a
     parked plan comes back cold.
   If the plan looks finished but you're inferring it from a Now note
   rather than the phase markers, ask me. Archiving mid-programme is
   how a phase gets lost.
3. Close only: `git mv plan/<name> plan/archive/<name>`, and tidy the
   file as it goes — clear any leftover `← in flight` marker, leave
   Landed as the record rather than pruning it.
4. Close only, the design doc — every plan has one. If the work is
   complete and the doc describes nothing beyond it,
   `git mv design/<doc>.md design/archive/`, update its `status:` line
   to say so, and point the plan's `> source:` line at the new path. A
   doc that still carries live intent stays where it is — say which you
   did and why. Either way the decisions in it stay readable and stay
   cited: `design/archive/` is the shelf below `design/`, not a bin.
5. Pop `plan/CURRENT`: remove the top line. Whatever sat under it is
   live again, so read it and report what I'm back to — its name, its
   in-flight phase, and whether Now holds a brief or is empty. An empty
   CURRENT means no live plan; leave the file in place and empty, since
   the hook reads it.
6. Do the `git mv`s first (patches works on paths, not renames), then
   stage the content edits and the CURRENT pop as one `apply_patches`
   call. Don't commit — that's `/commit`, and this one carries no
   landing bookkeeping.
