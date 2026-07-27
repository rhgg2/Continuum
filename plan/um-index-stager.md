# um: index vs stager — plan

> source: `design/um-index-stager.md` — synthesis compiled from there;
> don't design here.

## Landed  (newest first; prune below ~4)

- 2026-07-27 tm: give flush one exit and drive its rebuild from tm:flush (D5)
- 2026-07-27 tm: hoist the flush collision scan out of the stager (D5)
- 2026-07-27 tm: delete the flush-time PC reconcile (D5)
- 2026-07-26 tm: split the update manager into raw index and stager (D1)

## Now

(empty — D5 is complete: the stager no longer calls tm:rebuild. Next up is D6, collapsing the raw accessors; run /plan-next to promote it.)

## Queued (one-liners)

1. Collapse `rawNotes`/`rawPbs`/`rawIndexFor` into one accessor (D6).
2. Docs: `docs/trackerManager.md § Update manager` describes the index
   as the primary structure and states the mutation contract.
