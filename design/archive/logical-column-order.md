# logical column order — index the fx/park subsystem on the frame it tests

> Working design doc. Not part of the dirt-spine programme
> (`dirty-channels.md`) and not blocked on it: this is about the *index*
> over a channel's events, not about which channels get visited.

## Status

Closed 2026-07-15 (archived). Correctness landed and pinned; the targeted sort/park perf
captured. One item deliberately banked: dropping `computeFxWindows`' first sort (~3.7ms),
which needs the audited find/clip split + `rebuildFx` re-gate — poor risk/reward next to the
bigger rebuild costs (`fire`/`place`, `internals`, `serialise`) that live outside this design.

- **Steps 1 & 3 (correctness) — done.** Note columns sort on `ppqL` (`sortByPPQL`),
  `computeFxWindows`' chord-mate clip and `nextSameLaneNote`'s `strictNextMap` key on
  `ppqL`. `tm_column_order_spec` pins the host clip, the `slide(target='next')`
  successor, and (step 4's motivating rule) a note delayed out of a window in raw
  still parking.
- **Step 4 (regionPark perf) — done as a `covered()` pre-filter, not a binary
  search.** The note/cc park scans gate the `parkSpec` clone on `covered()`, so a
  no-fx take builds an empty scan and spends nothing. This is exact (same predicate
  `reconcilePark` applies) and self-contained — it needs neither the `fxHosts` set nor
  a sorted-column range query, and captures the full 15.6ms without them.
- **Step 2/3 (sort cost) — landed as a sort-dedup, not the `fxHosts` host set.** Live
  profiling on the Hammerklavier take settled the split: `fxWindows`/`fx` are dominated by
  the full note-column sort, not the `openHosts` walk a host set would remove. So the win is
  collapsing redundant sorts, not `seatNote`/`unseat`/`fxHosts`. Per rebuild the column is
  sorted four times (`computeFxWindows` ×2, `rebuildFx`, `projectLogical`); three follow a
  real column mutation, but `rebuildFx`'s re-sort is provably redundant — `computeFxWindows`
  runs immediately upstream and nothing between reorders. Removed it: `fx` 5.9 → 2.2ms live
  (the 3.7ms delta is one full column sort; the 2.2ms floor is the host walk + reconcile,
  which run with zero hosts). Then a second cut, same principle: `computeFxWindows`' *second*
  sort (post-park/PA) is needed only for columns `rebuildPA` appended into — the sole mutation
  between the two calls that unsorts a column (park removes in place; restore re-sorts its lane
  inline). `rebuildPA` now returns its touched-channel set and `computeFxWindows` gates sort #2
  on it, so a PA-free rebuild skips it: `fxWindows` 9.7 → 4.8ms live. That leaves two sorts:
  `computeFxWindows`' first (all dirty, fresh from internals) and `projectLogical`'s (for tv) —
  both load-bearing. Dropping the first needs the find/clip split + `rebuildFx` re-gate (the
  audited full plan); banked, not built.

## Problem

Two symptoms, one cause.

**Correctness.** Delay separates the two frames:
`ppq = fromLogical(ppqL) + delayToPPQ(delay)`. A delay larger than the gap
to a lane-mate reorders the lane in *raw* while the grid order stands. Three
consumers walk a note column in array order but test `ppqL`, so each reads the
wrong successor:

| site | reads | breaks as |
|---|---|---|
| `computeFxWindows:2224` | `evt.ppq > openHosts[1].ppq`, clips with `ppqL` | host window never clipped by a successor that sorts before it — the fx stream over-runs into ground it doesn't own |
| `eachWindowNote:392` | `onsets[i + 1].ppqL` as "next onset" | region member spans invert (`hi < lo`); a lane-mate can vanish from membership entirely |
| `nextSameLaneNote:2332` | `strictNextMap(byLane)`, default raw onset | `slide(target='next')` aims at the raw-next note, not the grid-next |

`:2332` even documents the dependency: *"groups are ppq-ordered: computeFxWindows
sorted col.events"*. The order is real; it's just the wrong order.

**Perf.** `rebuildRegionPark`'s note and cc scans (`:1922-1935`, `:2027-2038`)
enumerate every event in every dirty channel, allocate a `parkSpec` clone plus a
wrapper per event, and *then* filter with `covered()`. They brute-force because
there is no logical-ordered index to range-query — `covered()` tests `ppqL` and
the columns are sorted on raw. Placing one note on an 8438-note single-channel
take spends **15.6ms** building ~10,100 throwaway tables to test them against an
empty window list.

`computeFxWindows` has the same shape and is worse placed: it walks every event
in all 16 channels — *ungated by dirt*, unlike every other stage — to find hosts
by brute force, and the pipeline calls it **twice** (`:3083`, `:3115`, re-scanning
after park/unpark/PA). On a take with zero fx hosts it costs 7.3ms to return an
empty table. The `parkRegions` loop (`:3087-3096`) then walks every note column
again looking for the same hosts.

## The model

The fx/park subsystem is logical-frame throughout. Windows are grid spans
(`parkRegions` builds them from `ppqL`); `covered()` tests `spec.ppqL`;
`eachWindowNote` takes `startL`/`endL`; `membersOf`, `allocateRegionLanes` and
`channelStreams` are logical; `pbBaseFor`/`ccBasesFor` (`:2291`, `:2308`) already
sort *logical* values through `sortByPPQ` by writing `ppqL` into a field spelled
`ppq`. Park membership is **intent**: a note delayed out of a window in raw is
still inside it on the grid, and must still park.

Realisation-frame work is already elsewhere and already correct: `rebuildTails`
clips in raw, and builds its own array with its own `rawThenLogical` sort
(`:2563-2571`). `externalLanePacker` sweeps raw-ordered probes and pads by the
pass's max delay (`:1721-1726`).

So only the index is in the wrong frame. Fixing it is not a new mechanism — it
is deleting a frame confusion.

## Scheme

1. **Sort note columns by `ppqL`** at `:2215` and `:2248`. Costs nothing: the
   sort already runs, on the wrong key.
2. *[Superseded — see Status: the cost was the sort, not the walk, so this landed as a
   sort-dedup rather than a host set.]* **Drive `computeFxWindows` from a host set, not an event scan.** The fx hosts
   of a channel are known where every note is already visited: `rebuildInternals`
   (`:1545-1551`). Keep them as a per-channel list on the channel frame — built
   for dirty channels, carried for clean ones, exactly like the columns
   themselves (phase B, `:3165-3173`). `computeFxWindows` then walks *hosts* and
   binary-searches each host's lane column for the first event with a greater
   `ppqL`. O(hosts·log N), and free when there are no hosts.

   The `openHosts` machinery (`:2221-2227`) dissolves: chord-mates share a `ppqL`,
   so each independently binary-searches to the same successor. That is also the
   fix for the clip frame — the comparison is on `ppqL` because the index now is.
   `parkRegions` (`:3087-3096`) reads the same host set instead of re-scanning.
3. **`nextSameLaneNote`** passes a `ppqL` onset accessor to `strictNextMap`
   (`:2332`).
4. **Window-driven park scan.** `rebuildRegionPark` reads the same per-channel
   host set (its `covered()` has a host term as well as a window term, `:1887`)
   and drives its note/cc scans from `currentWindows` by binary search
   into the now-logical-ordered columns, the way the pb pass already drives
   itself from `pbCreated` (`:2098-2113`). Cost becomes
   O(windows·log N + covered + hosts). Zero windows with zero hosts yields an
   empty scan by construction, so the no-fx case needs no special-case guard.

## Blast radius (audited)

Everything upstream of `:2215` sees columns in mm order and is untouched:
`rebuildInternals`, `rebuildCCs`, `rebuildExtraColumns`, `rebuildExternals`.

Downstream, verified order-free or self-sorting: `rebuildTails` (`:2563-2571`),
`rebuildPbs` (own lane-1 list, `:2664`), `reconcilePCsForChan` (re-buckets by
`ppq`, `:528`), `findNoteColumnForPitch` (containment scan, `:2151`),
`projectToLogical` (re-sorts, and after `evt.ppq = evt.ppqL` that sort is already
logical, `:3019`/`:3032`). `trackerView` only ever sees post-projection columns.

## Validation

- `tm_column_order_spec` — host clip under a delayed successor. **Red.**
- Add: region membership under a raw-reordered lane (`eachWindowNote`).
- Add: `slide(target='next')` picks the grid successor (`nextSameLaneNote`).
- Add: a note delayed *out* of a window in raw still parks (membership is
  intent — the rule that motivates the whole change).
- `tm_regionpark_gating_spec`, `tm_fx_region_spec`, `tm_vibrato_spec`,
  `tm_gate_parity_spec` stay green.

## Expected effect

On the profile that prompted this (one note placed on the Hammerklavier first
movement: 8438 notes, all channel 1, no fx, no regions; flush 130ms of which
rebuild 86ms): `regionPark` 15.6 → ~0, and `fxWindows` 7.3 + `fx` 4.8 lose their
per-event scans. ~28ms of the 86.

The rest of the rebuild is untouched and stays O(take): `internals` 22.2,
`tails` 14.0, `projLogical` 8.5 all walk every note because the channel is dirty
and dirt is channel-granular. A better index cannot fix that — it needs a finer
dirty unit. Explicit non-goal here; see the interval-dirt successor project.
