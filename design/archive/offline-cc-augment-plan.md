# Offline continuous realisation — slice 1: cc-augment (impl plan)

> Scratch build-plan, not a design doc. Delete once landed and fold the
> outcome into `design/note-macros-v2.md` § *Offline continuous realisation*
> and § *Continuous cc*. Written 2026-07-04.

## Goal

Migrate **cc-augment** continuous realisation off the runtime carrier/node
onto offline **park-and-seat**, following the landed cc-replace pattern. This
is slice 1 of "offline continuous realisation" (route-by-window already landed;
pb-replace and cc-replace already offline). Slices 2 (pb-augment) and 3 (retire
the carrier/node/add-bank) follow separately.

The producer stops handing cc-augment deltas to the carrier and instead **sums
`parked-base + Σ macros` per cc target** and writes the result as markerless fx
cc events on the target lane — the same events cc-replace already writes.

## Load-bearing decisions (settled in discussion)

1. **No disjointness on augment regions.** The node sums arbitrary overlapping
   carriers on a cc today; the seat path **must** preserve that. Summation is
   scoped **per (chan, cc target)**, folding every augment stream that covers a
   point — not per region. This is the primary regression guard.
   *(Replace keeps its one-region-per-target lock; that's unchanged.)*

2. **A note is the degenerate region — park it through `parkWindows`.** Rather
   than a region-only guard with note-hosts stranded on the carrier, note-hosts
   are fed to `parkWindows` as regions so **all** cc-augment (region + note-host)
   parks and realises through one path. The only obstacle — a note-host's window
   (`fxWindow`) is computed inside `rebuildFx`, after the park pass — is soft:
   `fxWindow` is a pure, G4-stable scan of the note columns (settled after
   externals), so it's extracted to a helper callable at park time.

3. **Naming: fx cc events / fx pb events, parallel to fx notes.** Kill the
   fill/seat vocabulary. This slice:
   - `ccFill` (producer accumulator) → **`ccLive`** (like `noteLive`)
   - `fx.ccExisting[chan].fill` → **`.events`** (recognized fx cc events)
   - `fx.ccExisting[chan].base` (rest seat) + `derived='ccbase'` → **retire**
     (rest folds into the summed base)
   - `fx.ccExisting[chan].carrier` → **stays** — pb-augment still rides
     cc-coded carriers until slice 2. So `fx.ccExisting[chan]` = `{carrier, events}`
     after this slice; the full flatten to a plain list is slice 3.
   - `fx.replacePb` → `fx.pbLive` is **slice 2**, not now.

4. **cc events are plain 7-bit** — `sumStreams` clamps 0..127. The carrier's
   14-bit was a pb-transport artifact; cc-replace already writes 7-bit.

5. **cc-replace stays verbatim** (single curve, `out.delta` → `ccLive` per bp,
   shape preserved, no densify). Only cc-**augment** goes through `sumStreams`.
   Both land in `ccLive` → one "fx cc events" family downstream.

## The unified parking (note-is-a-region)

**`generators.lua`**

- `parkWindows(regions)` — guard the chord window: `if generators.parksNotes(region)
  and not region.noteHost then window('note', region) end`. A note self-parks via
  the note scan; its region form must not *also* trigger region-chord parking.
  Continuous (cc/pb) windows emit for all regions including note-hosts.
- Widen the continuous arm so cc-**augment** targets park too (today only
  `mode=='replace'` emits cc/pb windows):

  ```lua
  for _, params in ipairs(region.fx or {}) do
    local meta = generators.kinds[params.kind]
    if meta then
      if type(meta.dest) == 'number' then window('cc', region, meta.dest)   -- replace + augment
      elseif meta.dest == 'pb' and meta.mode == 'replace' then window('pb', region) end  -- pb-augment defers to slice 2
    end
  end
  ```
  (pb stays replace-only here — pb-augment parking is slice 2. No registered
  pb-replace kind today, so real pb behaviour is untouched.)

**`trackerManager.lua`**

- Extract `computeFxWindows()` from the `local fxWindow, nextInLane = {}, {} do … end`
  block (~1782–1808) into a module-level helper returning `fxWindow` (and
  `nextInLane`). Pure scan of `channels[chan].columns.notes`; no realised
  round-trip. `rebuildFx` calls it as today.
- In the park pass (or in `tm:rebuild` just before `rebuildRegionPark`, 2719),
  build note-host park-regions and pass a unified list to `parkWindows`:

  ```lua
  local fxWin = computeFxWindows()
  local noteHostRegions = {}
  for chan = 1, 16 do
    for _, col in ipairs(channels[chan].columns.notes) do
      for _, host in ipairs(col.events) do
        if host.fx and host.evType ~= 'pa' then
          util.add(noteHostRegions, { chan = chan, startppq = host.ppqL,
            endppq = fxWin[host], fx = host.fx, noteHost = true })
        end
      end
    end
  end
  local parkRegions = util.concat(ds:get('fxRegions') or {}, noteHostRegions)
  ```
  Pass `parkRegions` to `generators.parkWindows(...)` in **both**
  `rebuildRegionPark` (park) and `rebuildCCs` (recognition) — recognition needs
  the same windows to route seats out. Thread `parkRegions` in, or recompute the
  note-host list in each (cheap; prefer computing once in `tm:rebuild` and passing
  down, since both funcs already take args).

  *Gotcha:* `rebuildCCs` runs at 2714, before the park at 2719 — but it only
  needs the *windows* (for `steadyWins`/recognition), which `computeFxWindows`
  supplies independently of the park. Compute `parkRegions` once in `tm:rebuild`
  before 2714 and pass to both.

## The summation — `sumStreams`

New module-level helpers in `trackerManager.lua` (near `centsToRaw`, ~95):

```lua
local function isCurved(shape) return shape and shape ~= 'step' and shape ~= 'linear' end
local function ccGridStep() return math.max(1, util.round((mm:resolution() or 960) / mm:ccInterp())) end
```
(Hoist the existing `isCurved`/`gridStep` locals in `rebuildPbs` to use these —
small DRY cut, and slice 2 reuses them.)

```lua
-- Sum a base curve and N macro curves into a realised polyline on the absolute
-- gridStep lattice, within one covered span. Curves are sorted {ppqL,val,shape}.
-- opts = { round=bool, lo=num, hi=num }.  Returns { {ppqL,val,shape}, ... }.
local function sumStreams(base, macros, span, opts)
  local sL, eL = span[1], span[2]
  local grid = ccGridStep()

  -- held-both-ways eval: before first -> first value; after last -> last value;
  -- interior -> mm:interpolate honouring the governing bp's shape. Macros read 0
  -- outside their own window because generators anchor 0 at both window edges.
  local function eval(curve, ppq) ... end            -- firstAfter + mm:interpolate('val')
  local function governingShape(curve, ppq) ... end  -- shape of last bp with .ppq <= ppq ('step' at/beyond ends)

  -- feature points = {sL, eL} ∪ every bp ppqL of base and all macros within [sL,eL], sorted, deduped
  -- for each adjacent pair (p,q):
  --   curved = any constituent isCurved(governingShape(·,p))
  --   stepped = every constituent governingShape=='step'
  --   emit p: val = eval(base,p) + Σ eval(macro,p); shape = stepped and 'step' or 'linear'
  --   if curved: densify — for g=p+grid; g<q; g+=grid: emit {g, Σeval, 'linear'}
  -- emit final eL point.
  -- opts.round: util.round(val); opts.lo/hi: util.clamp(val, lo, hi)
end
```

Notes:
- **Densify only curved segments** (any 'slow'/curved constituent). Linear+linear
  and step+step sum exactly at the union — no growth. autopan emits `'slow'`
  extrema, so a lone autopan over a flat rest **will densify** (more CC than the
  carrier's 2-points-per-cycle). Correct, acceptable for first cut. *Future opt:*
  a single macro over a constant base can be emitted verbatim (shape preserved,
  no densify) — deferred.
- **Grid is segment-relative from stable points** (`p + grid`, p an authored or
  deterministic-macro bp) — idempotent, churn-free, matching the absorber's rule.
- Domain-agnostic on the value field (`'val'`) so slice 2's pb path reuses it
  (pb adds detune downstream in `deriveChan`; `sumStreams` stays cents/val-only).

## Producer + reconcile edits (`rebuildFx`)

Per-chan locals (~1931): `local predicted, pending, ccLive, ccAugment = {}, {}, {}, {}`
(rename `ccFill`→`ccLive`; add `ccAugment`).

**`runProducer` augment arm (~1960–1983).** Split cc-augment out of `pending`;
no host guard (all hosts are regions now):

```lua
local target = meta.dest ~= 'note' and meta.dest or nil
if target and #out.delta > 0 then
  if meta.mode == 'replace' and type(target) == 'number' then
    for _, bp in ipairs(out.delta) do              -- cc replace: verbatim seats
      util.add(ccLive, { evType='cc', chan=chan, cc=target,
        ppq=tm:fromLogical(chan, bp.ppqL, p.d), val=bp.val, shape=bp.shape })
    end
  elseif meta.mode == 'replace' and target == 'pb' then
    util.add(fx.replacePb[chan], { startL, endL, curve=out.delta, d=p.d })  -- unchanged
  elseif type(target) == 'number' then             -- cc AUGMENT: bucket for per-target sum
    util.bucket(ccAugment, target, { window={startL,endL}, bps=out.delta,
      rest = p.fx.rest, d = p.d })
  else                                             -- pb AUGMENT: carrier (slice 2 migrates)
    util.add(pending, { startL=startL, endL=endL, target=target, delta=out.delta, d=p.d })
  end
end
```
(The `rest` computation that was inline for cc moves into the augment sum below.)

**Per-target summation** — after the region/host producer loops, before/at Pass B:

```lua
for cc, macros in pairs(ccAugment) do
  local rest = firstRestOverride(macros) or generators.ccDefaultRest[cc] or 0  -- first/lowest wins
  local base = buildCcBase(chan, cc, macros, rest)   -- parkedCC[cc] ∪ out-of-window col.events[cc], deduped by ppqL; else flat {ppqL=<span start>, val=rest, shape='step'}
  for _, span in ipairs(mergeWindows(macros)) do     -- maximal covered spans (overlap merges; gaps split)
    local pts = sumStreams(base, overlapping(macros, span), span, { round=true, lo=0, hi=127 })
    for _, pt in ipairs(pts) do
      util.add(ccLive, { evType='cc', chan=chan, cc=cc,
        ppq=tm:fromLogical(chan, pt.ppqL, 0), val=pt.val, shape=pt.shape })
    end
  end
end
```

Helpers (module-level or local to `rebuildFx`):
- `mergeWindows(macros)` — sort macro windows by start, merge overlapping/adjacent
  into maximal `{sL,eL}` spans. Overlap → one span (N-stream sum); disjoint →
  separate spans, authored cc in the gap untouched on-take.
- `buildCcBase(chan, cc, macros, rest)` — authored cc curve for the target:
  `channels[chan].parkedCC` filtered to `cc` (in-window, authoritative) ∪
  `channels[chan].columns.ccs[cc].events` filtered to `ppqL` not already present
  (out-of-window, for hold-in). Sort by ppqL. If empty → single flat point at
  `rest`. This is the base `sumStreams` evals held.
- `overlapping(macros, span)` — macros whose window intersects the span.

**Reconcile (~2118–2124).** Rename:
```lua
reconcileDerived{
  existing = fx.ccExisting[chan].events, predicted = ccLive, sink = wires,
  key   = function(x) return util.key(x.cc, x.ppq) end,
  match = function(have, spec) return have.val == spec.val and have.shape == spec.shape end,
}
```

**Retire the cc rest seat (~2103–2117).** Delete the `predictedBase`/`ccbase`
block and its `reconcileDerived`. `fx.ccExisting[chan].base` bucket goes away.
Pass B (~2040–2101), `predictedDelta`, `reconcileCarrier`, `allocateCarrier`
**stay** — pb-augment (and note-host cc-augment? no: note-host cc-augment now
also seats) still need the carrier for pb only. `pending` now carries pb-augment
only.

**`rebuildCCs` (~1265–1294).** The recognition already routes in-window cc out as
`.fill`→`.events`; it now sees note-host cc windows too (unified `parkRegions`).
Rename `.fill`→`.events`. Delete the `ccbase` recognition arm (~1277–1281). The
`carrierRoute` arm stays (pb carriers).

**`fx` table init (~2702–2708).** `fx.ccExisting[i] = { carrier = {}, events = {} }`
(drop `base`, rename `fill`→`events`).

## Tests (`tm_fx_region_spec`, `tv_fx_region_spec`)

- **Value-correctness**: augment region on cc N over authored cc → seats equal
  `base + macro` at breakpoints; authored held-in value respected before the
  first in-window authored bp.
- **N-stream sum (the regression guard)**: two overlapping autopan regions on
  cc 10 → seats equal `rest + macroA + macroB` in the overlap; single-region
  values outside it.
- **Rest fallback**: augment region on a cc target with no authored automation →
  base = `ccDefaultRest[cc]` (or `fx.rest` override); seats centre on it.
- **Note-host augment**: autopan on a note host realises seats over `fxWindow`;
  its base cc (if any) parks via the unified `parkWindows`.
- **Markerless**: seats carry `uuid==nil`, no `eventMeta` (route-by-window).
- **Parked base visible + editable**: `channels[chan].parkedCC` shows the authored
  cc; the fill/seats are hidden. Creating the region never blanks the lane.
- **Removal**: region removed → seats swept, authored base restored (existing
  `ccSweepQueue` path; confirm it fires for augment windows too).
- **Disjoint spans**: two non-overlapping augment regions on one cc with an
  authored cc *between* them → the between-cc stays on-take (not seated).

## Explicitly NOT in this slice

- **pb-augment** (vibrato, slide) — slice 2. Still on the carrier. `fx.replacePb`
  keeps its name; `pbLive` rename is slice 2.
- **Retire carrier / node summation / add-bank / `Continuum CC.jsfx`** — slice 3,
  once pb-augment migrates. `fx.ccExisting[chan]` flattens to a plain list then.
- **Single-macro-over-constant-base verbatim optimization** — deferred; slice 1
  densifies all curved segments.
- **Mixed-delay overlap** — a delayed note-host cc-augment overlapping a region
  (d≠0 vs d=0) on one target: seats convert at `d` of the region (0). Regions are
  the common case; note-host-with-delay cc-augment overlap is a noted edge.

## Key references (may drift)

- `generators.lua`: `parkWindows` 316–333, `parksNotes` 305, `kinds` 237,
  `ccDefaultRest`, `CARRIER_PRIORITY`/`allocateCarrier` 123–137, `autopan` 206.
- `trackerManager.lua`: `centsToRaw` 95, `rebuildCCs` 1220 (recognition 1265–1294),
  cc park scan 1614–1655, `computeFxWindows` source 1782–1808, `rebuildFx` 1757,
  producer arm 1960–1983, Pass B 2040–2101, rest seat 2103–2117, cc reconcile
  2118–2124, `fx` init 2702–2708, pipeline order 2713–2727 (ccs 2714, park 2719,
  fx 2722), `deriveChan`/`isCurved`/`gridStep`/`streamValue` 2291/2222/2274/2350.
- Pipeline order: internals → **ccs** → externals → **regionPark** → pa → **fx**
  → tails → pbs → pcs.

## Sequencing within slice 1

1. `computeFxWindows` extract + note-host `parkRegions` + `parkWindows` guard/widen
   — parking unified, no summation yet. Pin: note-host autopan base parks; region
   augment cc parks. (Recognition still treats them as before → seats may be
   wrong until step 3, so land 1–3 together or gate tests.)
2. `sumStreams` + helpers (`mergeWindows`, `buildCcBase`, `overlapping`,
   `isCurved`/`ccGridStep` hoist) — pure, unit-testable in isolation.
3. Producer split (`ccAugment` bucket) + per-target summation → `ccLive`;
   reconcile/rebuildCCs/`fx`-init renames; delete rest seat.
4. Tests green; commit.
