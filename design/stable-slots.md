# stable slots — the write side stops paying O(take) per keystroke

> Working design doc, **not started**. Sibling to `interval-dirt`, which
> attacked the derivation half of a flush (`reload`) and closed 2026-07-21
> (`design/archive/interval-dirt-closing.md`); this one attacks the write
> half (`rebuild` + `serialise`). Phase 2 here depends on phase 1 here.
> Plan: `plan/stable-slots.md`.

## Status at a glance

| | |
|---|---|
| state | designed, unstarted; measurements refreshed 2026-07-25 |
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
- **delete** — two candidate shapes, phase 1 decides:
  1. splice out of the order array immediately;
  2. tombstone — nil `notes[slot]`, leave the order entry, sweep once at
     flush.
  The deciding constraint is today's mid-iteration contract: the raw walks
  are hole-tolerant of a delete landing mid-walk, and an immediate splice
  shifts positions under a live iterator where a tombstone does not.

`needsSort`, `needsCompact`, `stableByPpq`, `fullSortByPpq`,
`util.compact` and the tokenIdx loop all dissolve. `rebuild(metadata)`
survives only as the wholesale path `load` needs — building the order
arrays from scratch, which is exactly today's code.

### Equal-ppq order must be pinned first

Today equal-ppq order is a by-product: `stableByPpq` preserves array order
among equals, and array order encodes insertion history. Under splice, the
order among equals is wherever the binary search lands. Pin the rule —
**a new or ppq-moved event inserts after all existing events at that ppq**
— as a spec before phase 1 starts, so the migration converges on a stated
behaviour rather than mimicking an accident.

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

A ppq-moving gesture sheds the `rebuild` row on top of that. Its current
total has not been traced, so the after-figure is deliberately absent
rather than guessed.

Untouched: reload (13.2, `place` 8.1 the crux), setEvts (9.1 — REAPER's
floor), meta (0.9 — done), and the 11.0ms of flush sitting outside `mm`,
which has never been broken down. That remainder is the next thing worth a
profile after this programme, not before it.

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

- Delete shape: immediate splice vs tombstone-and-sweep (§ The idea) — the
  mid-iteration contract decides.
- chanIdx option 1 vs 2 — measure bucket-walk cost per dirty channel
  before choosing.
- Do any callers splice *during* a raw walk (inserts mid-iteration, not
  just deletes)? tm batches through `batchModify`, which suggests no, but
  phase 1 audits before relying on it.
