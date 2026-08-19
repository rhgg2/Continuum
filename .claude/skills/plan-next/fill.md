# Fill Queued from the design doc

## 1. Figure out the split

Determine the new active phase of the plan: the first phase with work
outstanding. 

Split that scope into Queued lines, each a single commit with its
spec, landable in <150k context and in enough detail that one can
compile a brief from it without re-reading the whole section. Write in
plain, uncompressed sentences.
   
If the split exposes a decision the design doc leaves open, settle
it with me before writing the queue. 

## 2. Write the changes

Read `docs/STYLE.md` for the register, then in one `apply_patches`
call, write:

- Any agreed updates to the design doc;
- Phase book-keeping: mark the previous in-flight phase as landed
  (dated, with the commit count) and move the `← in flight` marker to
  the next phase.
- The Queued list for the new active phase.

Stop and point at `/commit`.
