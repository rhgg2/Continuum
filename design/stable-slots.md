# stable slots — the write side stops paying O(take) per keystroke

> Working design doc, **phase 1 in flight** — 0, 1a and 1b landed
> 2026-07-25. Sibling to `interval-dirt`, which
> attacked the derivation half of a flush (`reload`) and closed 2026-07-21
> (`design/archive/interval-dirt-closing.md`); this one attacks the write
> half (`rebuild` + `serialise`). Phase 2 here depends on phase 1 here.
> Plan: `plan/stable-slots.md`.

## Status at a glance

| | |
|---|---|
| sibling | `interval-dirt` — derivation side, closed 2026-07-21, archived |
| enduring model it changes | `docs/midiManager.md` § reindex gate; `docs/midiBlob.md` |
| the hard part | equal-ppq order becomes an explicitly maintained thing instead of a sort by-product |

## The problem

Every one-note edit pays O(take) in flush. HAMMERKLAVIER (8438 notes, 1685
ccs, 10174 texts), one-note **property** edit, 2026-07-25:

| span | ms | O(take) because |
|---|---|---|
| serialise | 16.3 | rebuilds every key (2.2, of which 0.75 is the `seenOnset` backstop), sorts all 28.7k (6.0), re-validates every chunk (5.8), concat (0.8) |
| reload | 13.2 | derivation — `place` 8.1 dominates; interval-dirt's residue, not this programme's |
| setEvts | 9.1 | whole-blob API — REAPER's floor |
| sidecars | 2.1 | rebuilds the whole texts array every flush; cached rows keep the per-row cost down |
| meta | 0.9 | no longer O(take) — fixed 2026-07-16 (`BUCKET` 256 → 64) |
| rebuild | 0 | **did not run** — see below |
| **flush** | **53.7** | 11.0 of it sits outside `mm`, untraced |

`rebuild` is gesture-conditional: `indexStale()` gates it on `needsSort or
needsCompact`, so a property edit (velocity, detune) skips it entirely and
only an add, delete or ppq move pays. On this take that cost is ~8ms — a
1.8ms reindex loop plus a 6.1ms `stableByPpq` over both arrays (estimated
read-only, 2026-07-25).

That is the trap for anyone profiling this programme: **the two halves
surface on different gestures**, so a trace that does not say which gesture
it profiled cannot price either half. The model below was derived on the
glasswork macro fixture (1268 notes, 9689 ccs, 1906 texts, flush ~24ms,
2026-07-16) and is unchanged by the refresh; the numbers are simply denser
here.

Two of those spans are self-inflicted, and both trace to one fact.

## Root cause: loc = dense position

`loc` is the event's position in the dense `notes`/`ccs` arrays. Two
consequences:

- **rebuild.** Any add, ppq move, or delete disturbs order or density;
  compact + `stableByPpq` then move every loc, and the always-run tokenIdx
  loop (`midiManager.lua:397-419`) re-derives loc, tokenIdx, chanIdx and
  eventsByUuid for every event. The verbs already maintain every index on
  the no-move path (`indexStale`) — the loop exists only because locs
  renumber.
- **serialise.** The wire sort key packs the record's dense index
  (`seq2 = i*2`, `midiBlob.lua:239-266`). Renumbering invalidates every
  key, so the sorted key list cannot survive a flush. Each flush therefore
  rebuilds ~14k keys (1.1ms), sorts them all (2.7ms), and walks ~16k chunks
  re-validating the pack cache (3.3ms) — to move, typically, two keys.

Feasibility check (2026-07-16): `loc` never leaves mm. Every
`notesRaw`/`ccsRaw` consumer discards it, `mm:events()` strips it
deliberately, and `gm_metadata_propagate_spec` pins the non-leak. Changing
its meaning is an mm-internal affair.

## The idea

`loc` becomes a **stable slot id**; ppq order becomes a maintained
injection instead of a sort by-product.

```lua
notes[slot]   = evt      -- sparse; slot is stable for the event's lifetime
noteOrder[i]  = slot     -- dense injection [1..n] -> slot, ascending ppq
noteFree      = { ... }  -- freed slots, reused before minting new ones
evt.loc       = slot     -- loc keeps its name; its meaning changes
```

(Per type: `ccOrder`/`ccFree` likewise — serialise ranks the streams
separately anyway.)

Verb maintenance replaces the reindex:

- **add** — slot from the free list, else `maxSlot+1`. Binary-search the
  order array for the ppq position, `table.insert` — a C-level memmove of
  ~10k pointers, sub-0.1ms, not a Lua loop. `util.insertSorted` (added
  2026-07-25) is that primitive.
- **ppq move** — splice out of the order array, splice back in at the new
  position. Everything keyed by slot (chanIdx `byLoc`, the event itself,
  phase 2's wire keys) is untouched.
- **delete** — splice out of the order array immediately; the slot goes to
  the free list. Decided 2026-07-25: the mid-iteration contract was the only
  argument for tombstoning, and the audit found nothing exercising it —
  production holds four mm iterator sites, all in tm, and every mutator call
  sits inside a collect-then-mutate loop. A tombstone would also owe a
  per-flush sweep, which is the O(take) walk this programme exists to
  remove. Because a splice under a live iterator skips a neighbour silently
  rather than failing, `ordered` carries a splice-epoch backstop that
  asserts instead.

`needsSort`, `needsCompact`, `indexStale` and `mm:reindexIfStale` dissolve:
nothing is stale after a verb, so nothing needs a deferred reindex.
`rebuild(metadata)` survives as the wholesale path `load` needs — a blob
arrives in take order with dedup holes, so `util.compact`, `stableByPpq` /
`fullSortByPpq` and the loop that mints slots 1..n all survive *inside* it.
What goes is every other caller: after phase 1 only `load` reindexes.

### Equal-ppq order: the add is specified, the move is not

Today equal-ppq order is a by-product: `stableByPpq` preserves array order
among equals, and array order encodes insertion history. Under splice, the
order among equals is wherever the binary search lands. So the rule is pinned
as a spec (`mm_sort_order_spec`, 2026-07-25) before phase 1 starts, and it
reads:

> **A newly added event inserts after all existing events at that ppq.**

Measured against today's code, that already holds — notes, ccs, and through
serialise to the wire. It does not hold for a **ppq move**, and could not
without new machinery: array order *is* ppq order, so an event arriving from
an earlier ppq already sits before its new equals, and `stableByPpq`'s strict
`>` never relocates an event past an equal. A move down onto an occupied ppq
lands after the events there; a move up onto one lands before them.

The rule therefore covers the add only, and **a ppq move's placement among
its new equals is unspecified.** That is REAPER's own position: `MIDI_Sort` is
stable, so order among coincident events is whatever relative order they
already had rather than a property of the last gesture. Nothing downstream can
see the difference either — equal-ppq siblings always differ in pitch (same
pitch at one ppq is a collision), so tm's same-pitch tail walk is blind to it,
the view lays out by lane and pitch, and which of two pitches at one ppq goes
first on the wire is nothing to REAPER.

Phase 1 gets the uniform behaviour for free: one splice serves add and move
alike, so both land after the equals. It may pin the move then — as a
consequence of the mechanism it chose, not as a debt it inherited.

### chanIdx: the per-channel walk order needs its own answer

`rawInChan` yields ascending loc, which is ppq order today *only because
rebuild assigns locs in ppq order*. Under stable slots, slot order is not
ppq order. The bucket machinery already has the right reflex — `seat`
appends when in order, else nils `locs` and the next walk re-derives — but
the re-derive key must become order-position, not slot value. Options:

1. per-bucket order arrays maintained by the same splice discipline (the
   verbs already visit `indexPut`/`indexDrop` per event);
2. re-derive on demand by one filtered walk of the global order array.

Option 1 is the likely answer — the verbs are already at the site — but
phase 1 measures rather than guesses.

## Phase 2: incremental serialise

With slots stable, the wire key becomes `ppq*1e6 + rank*1e5 + slot*2`
(`+1` for a bezier rider), and the sorted key array plus packed chunk list
persist across flushes:

- mm owns a `wire` state object (keys, chunks) alongside `loadedBlob`;
  midiBlob stays pure — full-regen constructs it, splice helpers mutate it.
- The verbs record per-event key dirt: old key value out (binary search),
  new key value in. A note's off-key rides the same slot at rank 0 with
  `endppq`, so a length edit dirties only the off key.
- The reporting spine already exists at channel granularity.
  `dirtyChans`/`markChan` (`midiManager.lua:912-915`) is reset in
  `enterNest` beside `metaDirty`/`metaDeleted` and seeded from exactly three
  sites — `mm:add`, `mm:assign`, `mm:delete` — each already holding the
  record. Key dirt lands at those same three sites and inherits the same
  completeness argument: `dirtyChans` is load-bearing for tm's gating, so a
  lossy set would already be showing as visible bugs.
- Delta coupling is local: a spliced key re-packs only its own chunk and
  its successor's (their `dppq` changed). The chunkCache covers the rest —
  and the per-flush cache *validation* scan (most of pack's 3.3ms)
  disappears with the full walk.
- `concat` stays whole-blob: 0.3ms, and `MIDI_SetAllEvts` imposes that
  floor anyway.

Constraints and wrinkles:

- **slot < 5e4** — `seq2` must stay under the key's 1e5 rank field.
  Free-list reuse bounds slots by the live high-water mark (macro fixture
  peaks ~9.7k ccs; 5× headroom). A guard falls back to full regeneration
  beyond the cap.
- **texts.** `flushTake` rebuilds the texts array fresh each flush, so
  text indices are never stable. Sidecar rows are already cached per event
  (`sidecarCache`); key sidecar texts by their **owner's slot** — streams
  are rank-disjoint, so ids may repeat across ranks. `carriedTexts` and
  passthrough are static between loads.
- **The full-regen path stays.** Today's serialise remains the
  load/bulk/guard path; the incremental path must produce a byte-identical
  blob. The `seenOnset` collision backstop runs only on the full path.

## What this buys, what it doesn't

| span | now | after |
|---|---|---|
| rebuild (ppq-moving gestures only) | ~8 | ~0.1 (splices) |
| serialise | 16.3 | ~1 (splice + neighbourhood re-pack + concat) |
| sidecars | 2.1 | ~0 (touched rows only; the texts array stops being rebuilt) |
| **flush**, property edit | **53.7** | **~35** |

A ppq-moving gesture sheds the `rebuild` row on top of that.

### Measured after phase 1b: an add note (2026-07-25)

The gesture is named because it has to be — **add one note** on
HAMMERKLAVIER, which is where the reindex used to land. Persistent across
edits rather than a single trace.

| span | before | after | |
|---|---|---|---|
| rebuild | ~8 | — | no gate and no span: `rebuild` runs from `load` alone |
| serialise | 16.3 | 15.2 | untouched by 1b; phase 2's target |
| reload | 13.2 | 11.9 | tm's half — interval-dirt's residue |
| setEvts | 9.1 | 3.3 | the surprise; see below |
| sidecars | 2.1 | 2.3 | unchanged |
| meta | 0.9 | 0.7 | unchanged |
| **flush** | **~62** | **44.3** | before = the 53.7 property-edit trace + the ~8ms reindex |

No add-note trace was taken before the flip, so that `before` column is the
property-edit trace plus the estimated reindex: the per-span deltas outside
`rebuild` are indicative, not measured pairs.

`setEvts` is the surprise. It is one `MIDI_SetAllEvts` call, 1b changes
nothing about the bytes handed to it, and yet 5.8ms of it went away and
stayed away. The leading candidate is GC attribution: the old reindex
allocated two compacted arrays, two identity order arrays and a whole fresh
`chanIdx` per qualifying gesture — some 30k table slots of garbage per
keystroke — and Lua's incremental collector charges that at later allocation
sites, of which the blob string is the biggest going. Untested; a
`collectgarbage('count')` delta across a flush would settle it. If it holds,
phase 2's allocation cuts may hand back more than their own span.

Untouched by this programme: reload (11.9, `place` 7.3 the crux), meta (0.7
— done), and the ~9.7ms of flush sitting outside `mm`, which has never been
broken down. That remainder is the next thing worth a profile after this
programme, not before it.

## Implementation plan

### Phase 0 — pins

- Equal-ppq order spec (the insert-after-equals rule) on both rebuild
  fixtures.
- Blob-stability pin: flush twice, byte-identical blob (the zero-write
  fixtures already pin write counts; this pins content).

### Phase 1 — stable slots in mm

- Sparse arrays + order injections + free lists; verbs splice; the delete
  shape decided against the mid-iteration contract; `rebuild()` reduces to
  the load-wholesale path.
- chanIdx walk-order decision (option 1 vs 2, measured).
- Suite and pins green; profile target: rebuild span ~4ms → ~0.1ms.

Decided 2026-07-25: `midiBlob.serialise` keeps its dense-array signature
through phase 1 — mm gathers a dense ppq-ordered snapshot from the order
arrays and hands it over, so `seq2 = i*2` stays valid and the wire key is
phase 2's business alone. The gather is ~10k pointer copies per flush.

### Phase 2 — incremental serialise in midiBlob

- Persistent wire state; verb-reported key dirt; slot-cap guard with
  full-regen fallback.
- Blob-equality pin: incremental vs full regen after gesture storms on
  both rebuild fixtures.
- Profile target: serialise span ~7ms → ~1ms.

### The ceiling, stated

After both phases the flush floor is reload + setEvts ≈ 11ms on the macro
fixture. Going lower is interval-dirt's job (reload) and REAPER's
(setEvts).

## Open questions

- chanIdx option 1 vs 2 — measure bucket-walk cost per dirty channel before
  choosing. Phase 1b lands option 2 (filter the global order array) as the
  correct-by-construction baseline, so 1c measures option 1 against working
  code rather than against today's.

Settled 2026-07-25, both by the phase-1 audit: the delete shape (immediate
splice, § The idea), and mid-walk mutation — no caller adds, deletes or
moves a ppq during a raw walk. Production's four iterator sites are all in
tm and all collect-then-mutate; the ppq assigns that read as mid-walk inside
`fullRebuildChannelCCs` are deferred through `mmBatch` and only reach mm
after the channel loop closes. The whole repo's genuine mid-walk mutations
are two ppq assigns in `tm_rebuild_rule_spec` (setup noise, rewritten in 1b)
and one value-only assign in `mm_cc_dedup_spec`, which reorders nothing.
