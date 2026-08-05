---
name: plan-close
description: Close the live plan and archive its documentation, pop the CURRENT stack.
disable-model-invocation: true
---

Pop the top of the CURRENT stack and put the files where a finished
programme's files live.

1. The hook injects the live plan, the CURRENT stack and the plan and
   design listings — work from those.
2. Establish which of two things this is, and say so before doing
   anything:
   - **Close** — the work is finished: every phase marked landed
     (phased), or Queued and Now both empty (phaseless). Files move
     to the archives.
   - **Park** — the work is unfinished and attention is moving
     elsewhere. The plan stays in `plan/`, nothing is archived, and
     only the CURRENT line goes. Its design doc's `status:` moves to
     `parked — plan/<name>`, since the hook checks that "in flight"
     appears in exactly the live plan's doc. Note in Now what's left,
     since a parked plan comes back cold. If the hook reports a brief in
     flight, that note absorbs whatever of it still matters and
     `plan/IMPL.md` goes in the same batch: it holds one item for
     whichever plan is live, so leaving it would let the next plan's
     `/plan-next` overwrite it unseen — and it would be stale by the
     time you came back regardless.
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
   in-flight phase, and whether Now holds a brief or is empty. Set that
   plan's design doc `status:` back to `in flight — plan/<name>` in the
   same batch: the revive is where the claim leaked before there was a
   check, because parking writes it and nothing wrote it back. An empty
   CURRENT means no live plan; leave the file in place and empty, since
   the hook reads it.
6. Do the `git mv`s first (patches works on paths, not renames), then
   stage the content edits (the `status:` lines included), the CURRENT
   pop and the brief's deletion if you're parking as one `apply_patches`
   call. Don't commit — that's `/commit`, and this one carries no
   landing bookkeeping.
