# interval dirt v2 — the raw record set, and what is still O(channel)

> Successor to `design/archive/interval-dirt.md` (closed 2026-07-21).
> v1 ended with every *derivation* gated on seeds; this list is what an
> audit the same day found still walking whole channels. Item 1 is the
> shared fix — a constantly-maintained raw record set — and the anchor
> for most of the rest. Audited against `trackerManager.lua` @ 9412af2;
> line refs will drift.

## 1. The raw record set (the shared fix)

Five passes still walk `mm:ccsRaw(chan)` to pick out one event type:
`rebuildPbs`' gather (:3646), `rebuildPA` (:2716), `rebuildPCs`' column
splice (:4173), `stampSamples`' PC gather (:4087), and the region
park's pb window diff (:2609, :2638). Meanwhile um already maintains
exactly the structure they want — `rawIndex[chan] = { notes, pbs }`,
raw-then-logical sorted, reconciled incrementally by the verbs and by
`mmBatch`'s `batchIdx` phase, rebuilt wholesale by `loadIndex` on
reload.

**The move**: extend the index to every event type, making it the
pipeline's one raw working set. `mm:ccsRaw` / `mm:notesRaw` then
survive only on the wholesale paths (`fullRebuildChannelCCs`,
`rebuildInternals`), and `mm:ccsRawBetween` retires (two callers, both
replaced by binary seek over sorted lists).

Shape, mirroring the column structure:

    rawIndex[chan] = { notes, pbs, pcs, pas, ats, ccs = {[ccNum] = list} }

ccs bucket per ccNum because every narrow cc consumer queries by
(chan, cc) window; pc/pa/at are flat per-channel lists (at has no
narrow consumer today — indexed for routing uniformity, cost ~zero).
`byUuid` grows to cover all events.

Why the machinery already suffices:

- Every mid-session writer passes through a maintenance door: the um
  verbs, or `mmBatch.commit` → `idxReconcile` per touched uuid. The
  rebuild passes' own derived writes (absorber pbs, cc seats, pc
  synthesis) all ride `mmBatch`.
- Markerless in-window pb seats are indexable: `addCC` always mints a
  uuid; "plain" only means no persisted sidecar
  (`map/midiManager.map` — plain-cc uuids are in-memory, re-minted
  each load). The re-mint coincides exactly with `loadIndex`'s
  wholesale rebuild, so identity churn lands on the full-rebuild
  boundary and nowhere else.
- `loadIndex` already walks all of `mm:events()` and discards the
  cc-family; filing them is free at load.

Decisions to settle at implementation:

- **pb frame**: `makeEntry` converts pb val raw→cents and drops the
  wire value, but `rebuildPbs`' consolidated assign delta-gates on
  wire raw (`pb.val ~= newRaw`). Entries carry the raw value alongside
  (`raw`), or the assign reframes to cents — one coherent choice.
- **Clone discipline** (restated, not new): entries are live um
  records read in place; a pass that mutates its working set clones
  what it touches, as `rebuildPbs` does today.

Read-site conversions: the five walks above plus
`buildCcExistingInWindows` (:2000). That last one is a live defect,
not just cost — it positional-queries mm mid-pipeline, so a cc
authored into a prev window in the same flush is missed
(`docs/decisions.md` § 2026-07-20). The um index is current
mid-pipeline because the staging verbs maintain it. **Red spec for
that edge lands first.**

What this does *not* buy: the index kills the type-filter scans and
enables span-bounded seeks everywhere, but the whole-channel skeletons
below are their own items.

## 2. Ungated — runs regardless of dirt

- ~~**`computeFxWindows`** (:2751) walks every note-column event of
  every fx-active channel, and runs **twice** per rebuild (:4222,
  :4263). No dirt check anywhere in it.~~ **Done (2026-07-21).**
  Note-hosts now cache `windowEnd` per uuid (`fxHostWin`); a host
  recomputes only when its own uuid seeds the dirt or a neighbour
  onset seeds a ppq inside its cached span, reseeking walk-free via
  the `byUuid.colEvt` seat stamp. Wholesale/restored channels fall to
  the old column walk. Length changes need no guard: they ride the
  `mm:setLength` wholesale reload, which reclips every window. The two
  calls share the one cache. See `docs/trackerManager.md` § Fx window
  cache. Region-fx window caching deferred.
- **`realiseParked` bounds** (:2471-2486): any channel with parked
  cells collects *every* note event in every lane as clip bounds,
  every rebuild, no dirt gate. Fix direction: dirt-gate the re-clip;
  find each member's bounding successor by binary seek over the note
  index instead of materialising the full bounds list.

## 3. `rebuildPbs` — gated seats, whole-channel skeleton

The closing list's item 1 gated the *seat* side (`seatScope`). The
skeleton around it still touches every pb and every lane-1 note on any
dirty channel, however sparse the dirt:

- gather clones every pb (:3643-3654) — was 5.4ms of the 15.1ms
  glasswork-dense baseline;
- the lane-1 view merges the whole raw note index (:3627-3638), and
  the detune-onset diff scans all lane-1 events before scope filtering
  prunes (:3775-3780);
- per-pb full sweeps: fence (:3789), cents back-derivation (:3796),
  `realPbs` (:3804), absorber pool partition (:3929), `mergeDetunes`
  (:3993), and the consolidated assign (:3997) — delta-gated writes,
  whole-channel scan (deliberate backstop; the scan is the cost);
- projection re-projects and re-sorts every pb into a fresh column
  (:4037-4064);
- small linear tails: `seatScope`'s `nextLane1After`/`bpSpan` per seed
  (:3665-3679); `inSeatWindow`/`inKeptRange`/`inSeatScope` linear in
  window count per query.

Fix direction: with the item-1 index, gather/clone/project only pbs
inside the seat spans and carry the prior pb column outside them — the
kept-range carry (`priorPb`, fencedWire) already does exactly this for
replace windows; extend the same mechanism to the whole out-of-scope
remainder. The lane-1 view and onset diff bound to the spans by binary
seek.

## 4. Scan-to-filter — index converts the walk, seeds can then gate

- **`rebuildPA`** (:2712) consumes no seeds at all: full cc-stream
  walk per dirty channel, re-projecting every PA. Index gives the pas
  list; the follow-up is seed-gating the projection like every other
  pass.
- **`rebuildPCs`** (:4133): `pcSeedSpans` finds each seed's next onset
  by scanning `rawNotes` from index 1 (:4123); the records build walks
  all notes filtering by span (:4144); the splice walks the cc stream
  filtering to PCs (:4173). Spans bound the *reconcile*, not the
  *scan*. Index + binary seek throughout.
- **`stampSamples`** (:4077) scans all notes per dirty channel for
  `sample == nil` — steady-state a no-op walk. Only fresh adds and
  imports can be unstamped, and both carry seeds; gate the scan on
  them.

## 5. `rebuildFx` soft spots

The producer gate works; two builds precede it that don't:

- `keptById` rebuilds from the full `noteExisting[chan]` even when
  every producer keeps (:3005);
- pb/cc bases cover the merged windows of *all* producers, including
  ones about to be kept verbatim (:3070) — near-whole-channel base
  construction on a dense-fx channel that then runs nothing. Build
  bases over the windows of producers that will actually run.

## 6. By design — not on the list

- `rebuildCCs` is properly split: seed dirt → `spliceChannelCCs`
  (O(seeds)); wholesale/stale-swing → full re-derive.
- The tail walk's linear fallback above 16 seeds is routing, not
  oversight.
- `coverOnsets` / `coverInto` / `eachWindowNote` binary-seek; the
  span-cover claims hold.

## Out of scope — carried from the closing list

- **Output side**: a delta-shaped `'rebuild'` signal.
- **Write side**: `serialise` + `setEvts` + sidecars (~14+10+2ms on
  the dense edit).
