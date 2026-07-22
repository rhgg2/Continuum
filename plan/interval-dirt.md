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

- 2026-07-22 tm: hoist rebuildPbs seat-span computation ahead of the gather (§ 3)
- 2026-07-22 tm: cache parked render clips per uuid, dirt-gate the reseek (§ 2)
- 2026-07-21 tm: cache note-host fx windows per uuid, gate on span dirt (§ 2)
- 2026-07-21 tm: pb read-sites onto the raw index; wire raw rides the entry (§ 1)

## Now

(empty — Commit 1 of 4 landed 2026-07-22: `seatScope` now computes spans
from the raw index ahead of the gather. Run `/plan-next` to promote commit
2 — bound the gather/clone to the seat spans, the 5.4ms win — from Queued.)

## Queued (current phase; one-liners)

- tm: bound rebuildPbs gather/clone to the seat spans; carry the prior pb
  column at projection for out-of-span pbs (§ 3, commit 2 — the 5.4ms win)
- tm: bound rebuildPbs lane-1 view to the seat spans by binary seek,
  dropping the whole-channel `mergeIndexed` on `rawNotes` (§ 3, commit 3)
- tm: bound rebuildPbs detune-onset diff to the seat spans by binary seek
  (§ 3, commit 4)
