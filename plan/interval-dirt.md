# interval-dirt v2 — plan

> source: `design/interval-dirt-v2.md` — synthesis (`/plan-next`) compiles
> from there; don't design here.

## Phases

1. **Raw record set** (§ 1) — rawIndex covers every event type; the five
   read-sites converted; `ccsRawBetween` retired — landed 2026-07-21
2. **Ungated passes** (§ 2) — `computeFxWindows` and `realiseParked` bounds
   both cached + dirt-gated — landed 2026-07-22
3. **rebuildPbs skeleton** (§ 3) — span-bounded gather/clone/project;
   kept-range carry extended to the whole out-of-scope remainder
4. **Scan-to-filter passes** (§ 4) — rebuildPA seed-gating, rebuildPCs
   seeks, stampSamples gated on add/import seeds
5. **rebuildFx soft spots** (§ 5) — keptById only when a producer runs;
   bases over running producers' windows only

## Landed (newest first; prune below ~4)

- 2026-07-22 tm: cache parked render clips per uuid, dirt-gate the reseek (§ 2)
- 2026-07-21 tm: cache note-host fx windows per uuid, gate on span dirt (§ 2)
- 2026-07-21 tm: pb read-sites onto the raw index; wire raw rides the entry (§ 1)
- 2026-07-21 tm: pa/pc read-sites onto the raw index; retire ccsRawBetween (§ 1)

## Now

(empty — Phase 2's last item landed 2026-07-22. Run `/plan-next` to
promote the next brief from Phase 3.)

## Queued (current phase; one-liners)

(empty — Phase 3 not yet seeded. Run `/plan-next` to seed Queued from
Phase 3 (`rebuildPbs` skeleton, § 3): span-bounded gather/clone/project
with the kept-range carry extended to the whole out-of-scope remainder.)
