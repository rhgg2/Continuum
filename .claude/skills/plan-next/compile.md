# Compile the top queued item

1. The goal is to write an implementation brief for the top queued
   item. This should be one landable change, spec included, fitting
   ≤150k context. If it isn't, split the item further.
2. Study the relevant parts of the design doc named in the `> source:`
   line, and the relevant code (maps first), until you could implement
   the item without the doc. Use the scratchpad and spike worktree to
   settle design questions — a fork you can name before writing the
   code, whose answer changes what the brief says.
3. Bring the search to chat: a summary of what the item actually is,
   the forks, what you'd do, and what you're unsure of. Anything the
   design doc left open is settled here too, and the design doc gets
   updated. Apply the principle of *preservation of scope*: the scope
   should not contract without being explicitly agreed upon, and
   either noted in the design document as a contraction of scope, or
   immediately queued as a follow-up item.
4. Once you have received an explicit go, write the brief as
   `plan/IMPL.md`. The implementer gets this and nothing else, so it
   should be self-contained. It opens with a header:

   ```markdown
   # <item title>

   > plan: `plan/<slug>.md` · source: `design/<doc>.md` § <section>
   >
   > Untracked working file — `/plan-next` writes it, `/implement-next`
   > works from it, the landing bookkeeping deletes it.
   ```
   
   and thereafter contains:
   - what and why, briefly;
   - the decisions already settled;
   - target shapes (data structures, fields) copied in;
   - file anchors with tight line ranges;
   - specs: red-first when the item fixes observable behaviour, naming
     the target spec file and fixture; green-first to pin a refactor;
   - what done looks like: suite green, plus the item's own evidence
     as observables and directions.
5. If compiling the brief built a working kernel in the spike tree,
   you may choose to salvage it rather than discard: `git -C <spike>
   diff HEAD > plan/IMPL.diff`. This is not an expected deliverable,
   and the reason it's handed over is not labour-saving, but
   correctness. The implementer writes the production code regardless,
   then compares against your spike. Briefs are, by construction,
   lossy, so code written against the brief may fail on a nuance not
   conveyed; where you think such nuances are most eloquently carried
   by the spike code itself, extract.
6. When you do hand over a diff, leave a pointer in your brief and
   classify the diff hunks as either **source code** or **target
   code**. Source code is partial implementation of production code,
   or of test code which is the subject of the brief itself. Target
   code is test-shaped code which forms part of the completion
   parameters of the brief from step 4.
7. Stage the brief and the plan-file update as one `apply_patches`
   call: the brief as a create with `overwrite: true`, the item cut
   from Queued, and Now replaced by a single line naming the item and
   its design reference. The item moves rather than copies — in flight
   the brief is its text, and the plan names it in one place, so the
   landing has nothing left to clear.

   ```markdown
   **Teach `usedby` the intra-file `@call` index** — brief in
   `plan/IMPL.md`. (design § Intra-file call edges)
   ```

   A salvaged `plan/IMPL.diff` is created as above and is exempt from
   review.
