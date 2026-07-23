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
   seeks, stampSamples gated on add/import seeds — landed 2026-07-23
5. **rebuildFx soft spots** (§ 5) — keptById built lazily; bases over
   running producers' windows only ← in-flight

## Landed (newest first; prune below ~4)

- 2026-07-23 tm: build rebuildFx's keptById lazily on first keep (§ 5)
- 2026-07-23 tm: seed-gate rebuildPA's PA re-projection (§ 4)
- 2026-07-23 tm: gate stampSamples' sample scan on seed-dirty channels (§ 4)
- 2026-07-23 tm: seek-bound rebuildPCs's three residual raw walks (§ 4)

## Now

(empty — phase 5's keptById defer landed; run /plan-next to promote the queued 'bases cover running producers' windows only' item into a Now brief)

## Queued (current phase; one-liners)

- rebuildFx: bases cover running producers' windows only — hoist the
  `seeded`/gate classification (:3169-3222) above `pbBaseFor`/`ccBasesFor`
  (:3162-3165) so `spans` merges the seeded producers, not all of them.
  Downstream reads confirm the narrowing is safe: `channelStreams` runs
  only for running producers, and `rebuildPbs`' fold (:3820) reads
  `pbBase[chan]` over live spans (`emitScope`) only. (§ 5, second bullet)

(§ 6 lists the by-design non-targets: `rebuildCCs`' seed/wholesale
split, the tail walk's 16-seed linear fallback, the
`coverOnsets`/`coverInto` binary seeks.)
