# Fill Queued from the design doc

## 1. Transfer design model to docs/

If a phase just concluded, then the model it just landed needs moving
from the design doc into `docs/`. Find the relevant design doc
sections, and determine where in `docs/` they will go. Then, in one
`apply_patches` call:

- Write the `docs/` changes, replacing a superseded model rather
  than augmenting;
- Repoint any citations into the design doc sections to their new
  home in `docs/`. 
- Replace the design doc sections with a one-line pointer.

## 2. Split the new phase

Determine the new active phase of the plan: the first phase with work
outstanding. 

This phase needs splitting into Queued lines, each a single commit
with its spec, carrying enough detail that one can compile a brief
from it without re-reading the whole doc.

Each commit should be landable in <150k context, but don't get too
granular: an item that's 2-5 lines of production code is likely too
small.
   
If the split exposes a decision the design doc leaves open, settle it
with me before writing the queue; `/commit` records it.

Read `docs/STYLE.md` for the register, then in one `apply_patches`
call, write:

- Phase book-keeping: mark the previous in-flight phase, if any, as
  landed (dated, with the commit count) and move the `← in flight`
  marker to the active phase.
- The Queued list for the new active phase.

Stop and point at `/commit`.
