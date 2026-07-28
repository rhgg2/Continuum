# fx freeze — plan

> source: `design/fx-freeze.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — freeze to raw** (§ Freeze to raw) — `tm:freezeRegion`
   as the producer-shaped primitive: clear `derived`, drop the covered
   fxParked entries, drop the region and its `prevWindows`, one flush;
   plus the tm-side eligibility gates.  ← in flight
2. **Phase 2 — the curve thinner** (§ Freeze to group) — pure
   tolerance-bounded Douglas-Peucker over the standing densified seats,
   emitting linear breakpoints; cents for pb, steps for cc.
3. **Phase 3 — freeze to group** (§ Freeze to group) — re-seat the
   curves sparse, mint a stock gm group via `markGroup` on um-live staged
   events inside the same flush, gm rect-conflict gate on the tv verb.

## Landed  (newest first; prune below ~4)

- 2026-07-28 tm: one producer, one census entry -- dedupe and one-for-one (§ Eligibility gates)
- 2026-07-28 tm: freezeRegion's note-host arm -- parked and on-take (§ Freeze to raw)
- 2026-07-28 tv: bind freeze -- Ctrl-E and the fx tab's action row (§ Freeze to raw)
- 2026-07-28 tm: freezeRegion -- the raw core, region host (§ Freeze to raw)

## Now

(empty — the census double-count and the resync's set-semantics subtraction are both fixed; run /plan-next to promote queued item 1, lifting the producer census out of assembleParkWindows.)

## Superseded

The compiled gates brief of 2026-07-28 was refuted by adversarial
review before implementation and is not in this file; its two fatal
findings are recorded in the design doc (`§ Eligibility gates`) and
its sound parts return in queued item 2.

`tm:freezeRegion` is ungated today: it will freeze a producer whose
output is entangled with a neighbour's, taking material the neighbour
still needs, or destroying a producer whose windows survive in the
recognition baseline. Add three refusals, all above the first
mutation, each returning plain `nil` and changing nothing.

**Where the gate's information comes from** (settled 2026-07-28). The
overlap gates read the persisted `prevWindows`, not a live
reconstruction. `assembleParkWindows` (`trackerManager.lua:4634-4664`)
builds that baseline from fxRegions + on-take note hosts + parked fx
hosts, so it already **is** the whole live producer census — and the
entries surviving the frozen producer's own are exactly every other
producer's windows. Reconstructing the census inside `freezeRegion`
would be a third copy of the note-is-a-region literal, checked against
a set the sweep hazard is not defined on.

**Gates 1-2 — same-target window overlap.** `freezeRegion` already
walks `prevWindows` at `trackerManager.lua:1676-1681` to build
`keptWindows` for the resync. Move that walk **up** to just after
`local windows = generators.parkWindows({ frozen })` (:1627) — above
the first mutation, the `assignEvent` at :1644 — give it one-for-one
accounting, and gate off it:

```lua
  -- prevWindows is the whole live producer census (assembleParkWindows: regions + on-take hosts +
  -- parked fx hosts), so what survives this producer's own entries is every other producer's window.
  -- One-for-one: parkWindows emits a window per stage, so one chain can emit two identical windows and
  -- so can a neighbour -- consuming every match would hide the identical-window neighbour from the gate
  -- below and sweep its seats.
  local prevWindows, keptWindows, claimed = ds:get('prevWindows') or {}, {}, {}
  for _, w in ipairs(prevWindows) do
    local mine
    for i, fw in ipairs(windows) do
      if not claimed[i] and util.deepEq(w, fw) then mine = i; break end
    end
    if mine then claimed[mine] = true else util.add(keptWindows, w) end
  end
  -- Two chains folding onto one target: the painter fold's seats belong to the fold, not to either
  -- chain; a chord member under two note windows has no extractable slice either.
  for _, kept in ipairs(keptWindows) do
    for _, w in ipairs(windows) do
      if kept.evType == w.evType and kept.chan == w.chan and kept.cc == w.cc
         and kept.startppq < w.endppq and kept.endppq > w.startppq then return end
    end
  end
```

One predicate serves both gates: note-vs-note and same-target
continuous differ only in `evType`, and `cc` is nil on note and pb
windows, so the target key compares uniformly. The move also drops the
`local frozen = false` at :1678, which shadows the frozen region.

**Gate 3 — a covered note carrying its own chain** (pulled forward
from phase 3, 2026-07-28; the design doc had it group-only). Goes
after `covered()` (:1630-1636), still above :1644:

```lua
  -- A covered note carrying its own chain is an independent producer, and dropping it with the chord
  -- strands its windows in the baseline: the next rebuild diffs them as removed and sweeps seats
  -- nothing produces any more. Freeze that host first, then this one.
  for _, spec in ipairs(stash) do
    if spec.evType == 'note' and spec.fx and spec.uuid ~= uuid and covered(spec) then return end
  end
```

Gates 1-2 cannot see this one: a note host's own note window is
suppressed by `noteHost` (`generators.lua:548-550`), and a
continuous-only chain shares no target key with a note-dest region.

**Contracts** at `trackerManager.lua:1711-1714` — replace `--contract:
ungated -- overlap with a neighbouring region is the caller's to
refuse` with the two refusals. Refusals **never surface**, at tm or at
the verb (settled 2026-07-28): silent decline is the house style and
there is no toast facility to build one on.

**Specs** — red first, four cases at the tail of
`tests/specs/tm_fx_region_spec.lua` (after :2125, before the closing
`}` at :2127), under a `----- Freeze to raw: the eligibility gates`
banner. Helpers to hand: `sine30` (:9), `arpUp` (:117), `addNote`
(:119-124), `injectArp` (:126-131), `stashOfType` (:51-57),
`authoredPitches` (:166-173). Note `derivedNotes` (:135-147) hardcodes
`'fxr-1'`, so two-region fixtures assert on `fxRegions` /
`authoredPitches` or filter locally.

1. *two note-replace regions overlap* — `h.ds:assign('fxRegions', {
   arp fxr-1 [0,240), arp fxr-2 [120,360) })` over a chord;
   `freezeRegion('fxr-1')` is nil, both regions stand, the stash is
   untouched, the chord is still parked.
2. *two chains fold onto one continuous target* — an on-take note
   ppq 0-240 carrying `sine30`, plus a pb region fxr-1 [120,360);
   `freezeRegion('fxr-1')` is nil. Earns its keep twice: it pins that
   the census reaches on-take hosts, which is why the gate reads
   `prevWindows`.
3. *the window covers a note carrying its own chain* — the fixture of
   `freeze (host parked by a region)` (:2089-2112) with the target
   swapped: sine30 on-take note + `injectArp`, then
   `freezeRegion('fxr-1')` is nil, the host is still parked **with**
   its `fx`, and the region still produces.
4. *a disjoint neighbour is no obstacle* — arp fxr-1 [0,240) and arp
   fxr-2 [240,480) with a note under each; `freezeRegion('fxr-1')`
   succeeds, fxr-2 survives with its parked member and still produces.
   Pins that the gate is not over-broad.

**Done**: suite green (2195 + 4). Cases 1-3 fail before the gates and
pass after; case 4 passes throughout. The twelve standing freeze cases
stay green — `freeze (host parked by a region)` (:2092) especially, as
the mirror of gate 3: freezing *the host* under a region must still
succeed.

## Queued (current phase; one-liners)

1. tm: lift the producer census — `assembleParkWindows`'s body becomes
   a named module-level function returning `{ uuid, chan, startppq,
   endppq, fx, noteHost }` producer records; rebuild pipes them
   through `generators.parkWindows` exactly as now. Collapses the
   three hand-kept copies of the note-is-a-region literal
   (`trackerManager.lua:1606-1607`, `:1614-1615`, `:4650-4651`) to
   one. Pure refactor, pinned by the standing suite.
2. tm: identity-stamp the baseline — `generators.parkWindows` stamps
   each emitted window `id = <producer uuid>` (census records carry
   it); `prevWindows` persists the field; freeze's resync drops by
   `id`, retiring the landed one-for-one walk and the field-for-field
   literal agreement it rests on (`trackerManager.lua:4662-4663`'s
   warning). The pb diff and cc recognition stay span-keyed — `id` is
   inert for seat recognition. Behaviour-equal after the landed
   dedupe; persisted-shape change free pre-beta. (§ Eligibility
   gates, "Identity reaches the baseline as a stamped `id`")
3. tm eligibility gates, against the census — same-target overlap by
   **owner identity** (not window value, so an identical-window
   neighbour is visible), the covered-fx-host gate, and the inverse
   note-host-span gate; pb-inclusive boundary. Specs pin each refusal
   and pin that a disjoint neighbour still freezes. Supersedes the
   refuted brief.
