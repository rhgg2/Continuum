# Fill Queued from the design doc

1. If appropriate, mark the previous in-flight phase as landed (dated,
   with the commit count) and move the `← in flight` marker to the
   next phase.
   
2. Split that scope into Queued one-liners, each a single commit with
   its spec, landable in <150k context and in enough detail that one
   can compile a brief from it without re-reading the whole section.
   
3. Prefer the split that makes each line separately reviewable over
   the one that makes them equal in size. Write in plain, uncompressed
   sentences.
   
4. If the split exposes a decision the design doc leaves open, settle
   it with me before writing the queue. Apply the principle of
   *preservation of scope*: any contraction of scope should be
   explicitly agreed, and either go in the design document, or be
   queued as a follow-up item.

5. Before any updates to the design doc, read `docs/STYLE.md` for the
   register.
   
6. Stage the plan update as one `apply_patches` call, then stop and
   point at `/commit` for the landed phase plan.
