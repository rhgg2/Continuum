# um: index vs stager — plan

> source: `design/um-index-stager.md` — synthesis compiled from there;
> don't design here.

## Landed  (newest first; prune below ~4)

- 2026-07-27 tm: collapse the raw read accessors onto rawIndexFor (D6)
- 2026-07-27 tm: give flush one exit and drive its rebuild from tm:flush (D5)
- 2026-07-27 tm: hoist the flush collision scan out of the stager (D5)
- 2026-07-27 tm: delete the flush-time PC reconcile (D5)

## Now

(empty — the code side of the index/stager split is complete; the docs pass is the last queued item. Run /plan-next to promote it.)

## Queued (one-liners)

1. Docs: `docs/trackerManager.md § Update manager` describes the index
   as the primary structure and states the mutation contract.
