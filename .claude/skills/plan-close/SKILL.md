---
name: plan-close
description: Close the live plan and archive its documentation, pop the CURRENT stack.
disable-model-invocation: true
---

This skill closes out a plan by moving any remaining model from the
design doc into `docs/`, filing whatever is not model, and deleting
the doc. The hook injects the live plan, the CURRENT stack and the
plan and design listings; work from those.

Offer to commit after steps 2, 3 and 4. Do these yourself, `git add`
then `git commit -m "<headline>"`, no body, scopes as indicated below.

## 1. Check we are done

The live plan is done when:

- There is no live implementation brief;
- Every phase in the plan is marked as landed, or the last in-flight
  phase has no remaining Queued items.

**Check in** if it seems we are not done.

## 2. Sweep forward-looking design residue

We first rehome everything in the doc that is not model. There are
three categories:

- **Unimplemented, dropped**: if the rejection is still tempting,
  rehome to a `design/decisions.md` entry naming what would make it
  moot; otherwise it goes.
- **Unimplemented, still wanted**: this rehomes, either to a live
  design doc, or else to `design/pipe-dreams.md`
- **Quirks and oddities**: things which stop short of being actual
  bugs, but are wrinkles which may want fixing up in future. These
  move to `docs/oddities.md`.
  
**Check in** with your proposed classification of non-model items, and
their proposed destinations.

**Done when** everything non-model has left the design doc. Commit
scope `design:`.

## 3. Sweep design citations

Each remaining section of the design doc states a model that must now
live in `docs/`. First, for each section, write the `docs/` section.
Then repoint all the citations. `grep -rn 'design/<doc>' .` finds the
links in source and specs that must move.

Don't amend the design doc, as it will be deleted very shortly.

**Check in** with a summary of what you are going to do before
starting the repoint.

**Done when**: The grep is clean. Commit scope `docs:`.

## 4. Archive the plan, delete the design doc

Start with `git mv plan/<name>.md plan/archive/`. The plan and the
design doc may or may not share a name, so check the plan's
`> source:` line.

Tidy the plan: clear any leftover `← in flight` marker, leave Landed
as the record rather than pruning it, and repoint the `> source:` line
at the `docs/` files that now carry the model. Name files, not
sections.

Then `git rm design/<doc>.md`, safe since nothing cites it by now.

Now pop `plan/CURRENT` by removing the top line. The next item is now
live again, so set its design doc `status:` back to `in flight —
plan/<revived>` in the same batch. An empty CURRENT means no live
plan; leave the file in place and empty, since the hook reads it.

**Done when** the plan reads as historical record — dated, demoted,
cited by nothing live — the design doc is gone, and the planning
apparatus is consistent and ready for `/plan-next` on the new plan.
Commit scope `plan:`.
