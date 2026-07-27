# um: index vs stager — plan

> source: `design/um-index-stager.md` — synthesis compiled from there;
> don't design here.

## Landed  (newest first; prune below ~4)

- 2026-07-27 tm: hoist the flush collision scan out of the stager (D5)
- 2026-07-27 tm: delete the flush-time PC reconcile (D5)
- 2026-07-26 tm: split the update manager into raw index and stager (D1)
- 2026-07-26 tm: pin the walk's index re-true with two specs (D4)

## Now

(empty — D5's second of three landed; next is `flush` getting one exit and the rebuild drive moving up to `tm:flush`. Run /plan-next to promote it.)

## Queued (one-liners)

1. `flush` gets one exit and stops driving `tm:rebuild` on the
   parked-only path; the drive moves up to `tm:flush`. Ordering risk:
   `postflush` currently fires *after* that rebuild, and
   `groupManager.lua:586` subscribes (D5, third of three).
2. Collapse `rawNotes`/`rawPbs`/`rawIndexFor` into one accessor (D6).
3. Docs: `docs/trackerManager.md § Update manager` describes the index
   as the primary structure and states the mutation contract.
