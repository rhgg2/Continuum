# interval-dirt v2 — plan

> source: `design/interval-dirt-v2.md` — synthesis (`/plan-next`) compiles
> from there; don't design here.

## Phases

1. **Raw record set** (§ 1) — rawIndex covers every event type; the five
   read-sites converted; `ccsRawBetween` retired — landed 2026-07-21
2. **Ungated passes** (§ 2) — `computeFxWindows` and `realiseParked` bounds
   both cached + dirt-gated — landed 2026-07-22
3. **rebuildPbs skeleton** (§ 3) — span-bounded gather/clone/project;
   kept-range carry extended to the whole out-of-scope remainder — landed 2026-07-23
4. **Scan-to-filter passes** (§ 4) — rebuildPA seed-gating, rebuildPCs
   seeks, stampSamples gated on add/import seeds ← in-flight
5. **rebuildFx soft spots** (§ 5) — keptById only when a producer runs;
   bases over running producers' windows only

## Landed (newest first; prune below ~4)

- 2026-07-23 tm: seek-bound rebuildPCs's three residual raw walks (§ 4)
- 2026-07-23 tm: de-materialise rebuildPbs lane-1 view — seeks + bounded walk (§ 3)
- 2026-07-22 tm: bound rebuildPbs clone to seat scope, realPbs whole from index (§ 3)
- 2026-07-22 tm: hoist rebuildPbs seat-span computation ahead of the gather (§ 3)

## Now

(empty — rebuildPCs's three walks now seek/coverOnsets; run /plan-next to promote the next § 4 item — stampSamples gate or rebuildPA seed-gate)

## Queued (current phase; one-liners)

- stampSamples: gate the `sample == nil` scan on add/import seeds — a
  steady-state no-op walk of every note on every dirty channel today (§ 4)
- rebuildPA: seed-gate the PA re-projection — coupled to `exciseNotes`
  (:1862), which drops *all* PA cells because rebuildPA refills all;
  settle the out-of-scope PA carry at promotion (§ 4)

(The § 3 tails — `seatScope`'s per-seed `nextLane1After`/`bpSpan`,
`inSeatWindow`/`inKeptRange` linear-in-window-count — are by-design
backstops/routing, not targets, and stay unqueued.)
