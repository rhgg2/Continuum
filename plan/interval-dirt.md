# interval-dirt v2 — plan

> source: `design/interval-dirt-v2.md` — synthesis (`/plan-next`) compiles
> from there; don't design here.

## Phases

1. **Raw record set** (§ 1) — rawIndex covers every event type; the five
   read-sites converted; `ccsRawBetween` retired — landed 2026-07-21
2. **Ungated passes** (§ 2) — `computeFxWindows` and `realiseParked` bounds
   both cached + dirt-gated — landed 2026-07-22
3. **rebuildPbs skeleton** (§ 3) — span-bounded gather/clone/project;
   kept-range carry extended to the whole out-of-scope remainder ← in-flight
4. **Scan-to-filter passes** (§ 4) — rebuildPA seed-gating, rebuildPCs
   seeks, stampSamples gated on add/import seeds
5. **rebuildFx soft spots** (§ 5) — keptById only when a producer runs;
   bases over running producers' windows only

## Landed (newest first; prune below ~4)

- 2026-07-23 tm: de-materialise rebuildPbs lane-1 view — seeks + bounded walk (§ 3)
- 2026-07-22 tm: bound rebuildPbs clone to seat scope, realPbs whole from index (§ 3)
- 2026-07-22 tm: hoist rebuildPbs seat-span computation ahead of the gather (§ 3)
- 2026-07-22 tm: cache parked render clips per uuid, dirt-gate the reseek (§ 2)

## Now

(empty — phase 3's last substantive item landed; run /plan-next to mark phase 3 landed, advance the marker to phase 4, and seed Queued from § 4)

## Queued (current phase; one-liners)

(empty — this is phase 3's last substantive item. The remaining § 3
tails — `seatScope`'s per-seed `nextLane1After`/`bpSpan`,
`inSeatWindow`/`inKeptRange` linear-in-window-count — are by-design
backstops/routing, not targets. When Now lands, `/plan-next` marks
phase 3 landed, advances the ← marker to phase 4, and seeds Queued
from § 4.)
