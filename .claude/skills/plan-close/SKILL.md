---
name: plan-close
description: Close the live plan and archive its documentation, pop the CURRENT stack.
disable-model-invocation: true
---

This skill closes out a plan, and splits its design doc into current
WHY, historical decision record, and items left open. The hook injects
the live plan, the CURRENT stack and the plan and design listings —
work from those.

Offer to commit after steps 2, 3 and 4. Do these yourself, `git add`
then `git commit -m "<headline>"`, no body, scopes as indicated below.

## 1. Check we are done

The live plan is done when:

- There is no live implementation brief;
- Every phase in the plan is marked as landed, or the last in-flight
  phase has no remaining Queued items.

**Check in** if it seems we are not done.

## 2. Sweep design citations

A design doc archives as the record of what was decided, not a model
reference for live code. So grep the tree for the doc's path — `grep
-rn 'design/<doc>' --include='*.lua' .`, source and specs alike.
Every hit is a piece of the operating model with no home in `docs/`
yet. The job of this step is to write the doc sections these should
now point at, and repoint the references. This step is purely
additive, and doesn't touch the design doc.

**Check in** with a summary of what you are going to do before
starting the repoint.

**Done when**: The grep is clean; this means the extraction is done
and archiving is safe. Commit scope `docs:`.

## 3. Sweep forward-looking design residue

We now extract the design doc's open items. There are three
categories:

- **Unimplemented, dropped**: this stays where it is, carrying its
  date and its reason: it's history, which is what archives
  hold. 
- **Unimplemented, still wanted**: this moves to a live doc that owns
  it, because nobody rereads an archive. This could be another live
  design doc, or else `design/pipe-dreams.md`
- **Quirks and oddities**: things which stop short of being actual
  bugs, but are wrinkles which may want fixing up in future. These
  move to `docs/oddities.md`.
  
This step is *not* additive; open items genuinely leave the design
doc, or are closed in-place.

If the doc has live intent with **nowhere** to go, a new design doc is
probably the answer; you are welcome to propose this.

**Check in** with your proposed classification of open items, and
their proposed destinations.

**Done when** the design doc is entirely historical record. Commit
scope `design:`.
  
## 4. Archive the plan and design doc

Start with `git mv plan/<name>.md plan/archive/` 
and `git mv design/<doc>.md design/archive/`. The two rarely share a
name — read the doc's off the plan's `> source:` line.

Tidy the two files:

- for the plan, clear any leftover `← in flight` marker, leave Landed
  as the record rather than pruning it, and point the plan's 
  `> source:` line at the archived design doc.
  
- for the design doc, `status:` says complete and dated, and one line
  demotes the doc — which `docs/` files carry the model as built, and
  the rule that where the two accounts differ, `docs/` is right. Name
  the files and not their sections, as a hedge against staleness:
  section names change, while module names rarely do. Don't thin the
  prose further: this is a historical decision record.

Now pop `plan/CURRENT` by removing the top line. Whatever sat under it
is live again, so set that plan's design doc `status:` back to `in
flight — plan/<revived>` in the same batch. An empty CURRENT means no
live plan; leave the file in place and empty, since the hook reads it.

**Done when** both files read as historical record: dated, demoted,
and cited by nothing live, and the planning apparatus is consistent
and ready for `/plan-next` on the new plan. Commit
scope `plan:`.
