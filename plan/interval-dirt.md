# interval-dirt v2 — plan

> source: `design/interval-dirt-v2.md` — synthesis (`/plan-next`) compiles
> from there; don't design here.

## Phases

1. **Raw record set** (§ 1) — rawIndex covers every event type; the five
   read-sites converted; `ccsRawBetween` retired — landed 2026-07-21
2. **Ungated passes** (§ 2) — `computeFxWindows` done; `realiseParked`
   bounds remains ← in flight
3. **rebuildPbs skeleton** (§ 3) — span-bounded gather/clone/project;
   kept-range carry extended to the whole out-of-scope remainder
4. **Scan-to-filter passes** (§ 4) — rebuildPA seed-gating, rebuildPCs
   seeks, stampSamples gated on add/import seeds
5. **rebuildFx soft spots** (§ 5) — keptById only when a producer runs;
   bases over running producers' windows only

## Landed (newest first; prune below ~4)

- 2026-07-21 tm: cache note-host fx windows per uuid, gate on span dirt (§ 2)
- 2026-07-21 tm: pb read-sites onto the raw index; wire raw rides the entry (§ 1)
- 2026-07-21 tm: pa/pc read-sites onto the raw index; retire ccsRawBetween (§ 1)
- 2026-07-21 tm: extend rawIndex to all event types; buildCcExisting seeks it (§ 1)

## Now

(empty — run `/plan-next` to promote the next queued item)

## Queued (current phase; one-liners)

- `realiseParked` bounds: dirt-gate the re-clip; each member's bounding
  successor by binary seek over the note index, not the full bounds list (§ 2)
