# Two-frame timing — drop intent, ppqL is logical truth

A working design doc for the timing-frame collapse. Future
`docs/timing.md` revision is distilled from this once code lands.

The three-frame model (logical / intent / realisation) is reduced to
two (logical / realisation). `ppqL`/`endppqL` stop being optional
sidecar stamps for reswing-on-demand and become the per-event source
of truth for logical position. Raw `ppq`/`endppq` become a derived
view, rebuilt from ppqL against the active swing.

---

## Motivation

UX: in the current system, per-event ppqL stamps mean events keep
their authoring-frame coordinate but reswing on column-swing change is
not the visible behaviour. Notes drift off the grid in apparently
meaningless ways; events with different swing histories in the same
column can reorder. Editing a column's swing changes the view of
existing events but not their realised positions.

Code: the intent frame answers no end-user question. It's the
arithmetic midpoint between logical and realised, and the boundary
where delay is added. Naming it as a frame forces every layer to know
which side of delay it lives on and forces tm to maintain a tidyCol
step purely to cross it.

The two changes are bundled because they share a target: swing is a
property of the take and column, not the event; ppqL is the canonical
position; raw is a function of ppqL.

---

## End-state model

Two frames:

- **logical** (vm and above) — what the musician edits. Row `r` sits
  at `r · logPerRow(rpb, denom, res)`.
- **realisation** (mm and the take's MIDI storage) — REAPER's frame.

tm sits on the boundary and holds the pair:

```
note = {
  ppq, endppq,         -- raw realised, what mm reads/writes
  ppqL, endppqL,       -- logical truth, persisted as event metadata
  delay,               -- per-note, ms-QN, signed; nudges note-on only
  ...
}
```

Transform (single direction, ppqL → raw):

```
ppq    = swing.fromLogical(ppqL,    cm.swing) + delayToPPQ(delay)
endppq = swing.fromLogical(endppqL, cm.swing)
```

The inverse (`swing.toLogical`) is used **only** at one place — the
load-time backfill (see Migration). Once ppqL is set, it is never
recomputed from raw. This is what makes reswing drift-free across
arbitrary edit sequences: ppqL is stored exactly; raw is reproduced.

Above tm, raw drops. ppqL is renamed `ppq` for vm/editCursor/
trackerPage; those layers see one frame, not two. `endppqL` likewise
renames to `endppq`. The "intent" name disappears from the codebase.

---

## Reswing

cm holds the swing config (take-global ∘ per-column). When the
resolved swing for a channel changes, tm receives a staleness signal
and triggers an immediate rebuild — raw `ppq`/`endppq` are recomputed
from each event's `ppqL`/`endppqL` against the new swing.

Triggers, all collapsing to "the swing this channel resolves to
changed":

- global swing edited
- this channel's per-column swing edited
- a library entry referenced by either is edited or renamed in place
- a slot is reassigned to a different library entry

Drift bound: zero, because ppqL is stored. Repeated swing edits do not
accumulate ε; each rebuild starts from the same ppqL and applies the
current swing afresh.

### Rebuild rule

The stale flag disambiguates intentional reswing from external edits.
For each event at rebuild:

- **stale = false, raw matches `swing.fromLogical(ppqL) + delay`** —
  no-op.
- **stale = false, raw disagrees** — external REAPER edit took place;
  recompute `ppqL = swing.toLogical(raw − delayToPPQ(delay))` and
  similarly for `endppqL`. Missing ppqL counts as disagreement and
  falls through this branch.
- **stale = true** — rebuild raw from ppqL; clear the flag.

"Disagrees" means `|raw − (swing.fromLogical(ppqL) + delay)| > ε`
with ε on the order of one ppq.

This single rule covers three cases that look distinct from the
outside but reduce to the same code path: a steady-state rebuild
where ppqL and raw agree (no-op); a user editing in REAPER's piano
roll between rebuilds (re-derive ppqL); and a project loading without
persisted ppqL on some or all events (re-derive ppqL). `swing.toLogical`
has exactly one call site.

---

## Persistence

ppqL and endppqL ride the existing per-event metadata channel — the
same mechanism aliases use (mm declares structural fields,
serialises everything else to take extension data via
`saveMetadatum`). No new wire format and no whitelist edit.

On reload, raw is read from REAPER's MIDI; ppqL is read from take
extension data. tm uses ppqL as truth and re-derives raw on first
rebuild. If raw and the recomputed value disagree (within rounding),
ppqL wins.

---

## Authoring and stamping

A new event stamps `ppqL = r · logPerRow` from cm's rpb/denom/res at
write time. No swing arithmetic at the stamping site — swing only
enters when raw is rebuilt. Note-off stamps `endppqL` the same way.

Delay is orthogonal: stamping does not consult or update delay.
Editing delay shifts raw `ppq` only; ppqL is delay-independent (a
property already stated in the current docs and preserved here).

rpb is purely a view concern. Changing rpb changes how rows map to
ppqL but does not change any event's ppqL. Events placed under one
rpb appear at non-integer rows under another. Same accepted
trade-off class as deliberately off-grid notes.

---

## Column allocation

`noteColumnAccepts` runs in logical. Same monotonic transform applies
to every event in the column, so overlap-in-logical iff
overlap-in-realised — the predicate is unchanged in shape, only the
frame name changes.

---

## Pitchbend: authored vs absorber

Two kinds of pb event coexist in mm; the two-frame model treats them
asymmetrically.

**Authored pbs** are first-class events. They stamp `ppqL` at write
time and follow the same rebuild rule as notes:
`raw = swing.fromLogical(ppqL)`. No delay term — pbs carry no delay
field.

**Absorber pbs** (`fake=true`, see `docs/tuning.md` §"The fake-pb
absorber") are derived. They exist to keep the logical pb stream
smooth across detune jumps at lane-1 note seats. Their position is
not authored; it is dictated by the host note. They do not stamp
`ppqL` and do not carry their own swing-position truth.

On rebuild, after notes' raw has been recomputed from their `ppqL`
and `delay`, `reconcileBoundary` walks lane-1 seats:

- Drop absorbers at seats with no detune jump (I2 second clause).
- Seat absorbers at seats with a new detune jump (I2 first clause).
- Reposition surviving absorbers to the host's current raw:
  `raw_absorber = swing.fromLogical(host.ppqL) + delayToPPQ(host.delay)`.

The absorber's position equals the host note-on's raw by
construction, so a delayed host and its absorber stay coincident in
mm without any per-absorber delay field. The current "fake pbs
inherit their host note's delay so tidyCol shifts them into intent
together" mechanism collapses: absorbers don't need a delay because
they don't need an intent-frame round-trip — they read host's raw
directly.

I1-I5 (`docs/tuning.md` §Invariants) survive unmodified. I1's
identity is per-ppq and frame-agnostic; I2's seating duty stays with
`reconcileBoundary`; I3-I5 are orthogonal to timing.

---

## Ownership

| layer        | sees           | duty                                           |
|--------------|----------------|------------------------------------------------|
| mm           | realisation    | REAPER's storage; raw ppq                      |
| tm           | both           | hold the pair; rebuild raw from ppqL on stale  |
| vm and above | logical        | row math only; never reads raw                 |

---

## Load and migration

No legacy data — pre-beta. Load needs no dedicated migration path.
mm reads raw from REAPER; tm reads ppqL from take extension data
where present. The first rebuild applies the rebuild rule above:
events with persisted ppqL that matches raw are no-ops; events
without ppqL (legacy takes) and events whose raw was edited externally
between save and load both fall through the disagreement branch and
get ppqL written. From that point on, ppqL is the truth.

---

## What goes away

- The "intent" name as a frame in source and prose.
- tidyCol's strip-delay step on read; the read path collapses to
  "raw is rebuilt from ppqL" so there is no read-time intent
  reconstruction.
- Absorber delay-inheritance — absorbers reseat from host's raw at
  rebuild, no `delay` field carried.
- Per-event reswing on swing-config change as a thing to wire — a
  flag flip is all there is.
- The "ppq comparisons run in realisation frame until tidyCol; from
  rebuild's exit onward everything tm exposes is intent" sentence in
  the doc, replaced by "tm holds both, vm sees logical only."

---

## Implementation plan

Phased so each step lands green and the system is usable between
phases. Compactions expected between phases — each phase is
self-contained against this doc. The phases are ordered to minimise
the risk of regressions in storage and to defer the largest mechanical
rename to last.

### Phase 0 — Reconnaissance

No code changes. Read and note:

- **mm** — structural fields list (what's whitelisted as first-class
  vs serialised through metadata pass-through). Pb event shape; how
  `fake=true` is set and read.
- **tm** — `tidyCol`, `rebuild`, `um:addEvent`, `um:assignEvent`,
  `swingSnapshot`, `reconcileBoundary`. Note every read/write site
  for `ppq`, `endppq`, `ppqL`, `endppqL`, `delay`.
- **vm** — `ctx:ppqToRow`, `ctx:rowToPPQ`, the swing call sites
  inside them, stamping paths.
- **cm** — swing config shape, the signal(s) emitted on swing change,
  the trigger surface (global, per-column, library-entry edit, slot
  reassign).
- **alias metadata pass-through** — confirm the mechanism that lets
  ppqL ride from mm to take extension data.

Output: short notes only as needed. Mostly groundwork for the
implementer's mental model.

### Phase 1 — ppqL universal and persistent

Goal: every authored event carries ppqL/endppqL, and they survive
save/load.

- Audit authoring sites; any path that writes an event without
  stamping ppqL gets fixed.
- Authored pbs gain ppqL stamping (notes have it; pbs may not yet).
- Confirm the metadata pass-through serialises ppqL/endppqL on both
  notes and ccs. Add to the structural-field list if performance
  warrants.
- Tests: round-trip a take through save/load; every event's ppqL is
  preserved exactly.

Lands green: existing behaviour unchanged; ppqL is now everywhere
and durable.

### Phase 2 — Rebuild rule with the stale flag

Goal: tm holds the two-case rebuild rule; intent frame still exists
underneath but is no longer the read path.

- Add a per-channel stale flag in tm (and a take-level setter that
  flips all channels at once).
- Implement the three-case rebuild rule (steady-state, disagreement,
  stale). Disagreement branch is the sole `swing.toLogical` call site.
- Run the rule on every rebuild. With cm.swing unchanged, all events
  hit the steady-state branch and behaviour is unchanged.
- Tests:
  - missing-ppqL event gets ppqL written on first rebuild (covers
    legacy-take load and externally-edited events);
  - matching-ppqL event is a no-op;
  - stale-true rebuilds raw from ppqL and clears the flag.

Lands green: tm has the rebuild rule wired but no trigger flips the
flag yet — behaviour unchanged.

### Phase 3 — Wire the reswing trigger

Goal: cm.swing change → stale flag → rebuild produces new raw.

- cm emits a signal on the trigger surface. tm subscribes via the
  existing `util.installHooks` protocol and flips the stale flag for
  the affected channels.
- Trigger covers all four cases collapsed in the Reswing section.
- Tests:
  - editing global swing reseats every channel's events; ppqL
    preserved;
  - editing per-column swing reseats only that channel's events;
  - editing a library entry referenced by current cm reseats matching
    channels;
  - reassigning a slot to a different library entry reseats that
    channel.

Lands green: column-swing edits now move notes — the UX fix is live.
Intent frame still exists internally.

### Phase 4 — Collapse intent at the authoring seam

Goal: every authoring path inside tm derives raw forward from
`(ppqL, delay)` rather than trusting a caller-supplied intent ppq.

Narrow cut: tidyCol stays. Removing it would leak raw onto vm's
~70 `evt.ppq` read sites, regressing render until Phase 6 routes
those sites onto ppqL. Phase 4 is contained to the authoring seam
so it lands green without vm touches.

- `um:addEvent` (note path): when `evt.ppqL` is present, write
  `evt.ppq = round(swing.fromLogical(ppqL)) + delayToPPQ(delay)`.
  Legacy callers without ppqL fall back to caller's ppq + delay.
- `realiseNoteUpdate`: derive `update.ppq` forward from
  `update.ppqL` (logical move); from `evt.ppqL` (delay-only edit);
  fall back to caller's ppq when neither is provided (legacy).
- `conformOverlaps` (vm): the same-onset 1-ppq tie-break and the
  tail-clip lift mirror their raw nudge into newPpqL, so tm's
  forward formula reproduces the nudge. Under identity swing the
  deltas are equal; under swing they differ by the local slope, an
  acceptable approximation for a tie-break.
- tidyCol's strip-delay and the "intent" name in tm survive Phase 4
  and retire in Phase 6 alongside the vm rename.

Tests: `tm_authoring_forward_spec` pins the new arithmetic under
c58 swing — caller's ppq is ignored when ppqL is supplied.

Lands green: tm's authoring seam speaks ppqL forward; tidyCol still
bridges raw → intent for vm consumers.

### Phase 5 — Simplify absorbers

Goal: absorbers stop carrying their own `delay`.

- Drop the absorber `delay` field (and any code that reads or writes
  it on absorbers).
- `reconcileBoundary` positions absorbers from host:
  `raw_absorber = swing.fromLogical(host.ppqL) + delayToPPQ(host.delay)`.
- Tests:
  - delayed lane-1 note with detune jump → absorber at host raw;
  - swing change moves both together;
  - delay change on the host moves the absorber;
  - removing a detune jump removes the absorber (I2 second clause).

Lands green: absorber arithmetic is one line; I1-I5 still hold.

### Phase 6 — vm rename and swing-strip

Goal: above tm, only one frame exists, and it's called `ppq`.

- tm exposes events to vm with `ppqL` renamed to `ppq` and `endppqL`
  to `endppq`. Raw is dropped from the consumer surface.
- vm's `ctx:ppqToRow` / `ctx:rowToPPQ` stop calling
  `swing.toLogical` / `swing.fromLogical`. Row math becomes pure
  division/multiplication against `logPerRow`.
- vm's `swingSnapshot` is removed (or reduced to identity for any
  remaining preview path).
- editCursor unchanged (already row-only).
- Stamping above tm sets `ppq = r · logPerRow` directly; tm receives
  it under that name and stores it as `ppqL` internally.
- Tests: vm spec for row↔ppq round-trip is now identity-without-swing.

Lands green: vm sees one frame; the largest mechanical change in the
refactor lands behind a clean tm boundary.

### Phase 7 — Docs and frame retirement

- Rewrite `docs/timing.md` for two frames. Most existing content on
  swing math (Shape, tile, composite, boundary clip) survives; the
  three-frame stack and the intent-frame ownership table go.
- Update `docs/tuning.md` §"The fake-pb absorber": absorbers reseat
  from host raw, no inherited delay.
- Move `design/timing_two_frames.md` to `design/archive/`.
- Update `docs/trackerManager.md` and any other module docs that
  reference the intent frame.

#### Cross-take reswing after frame retirement

Pre-Phase-7, `swingEditor.commit` → `seqMgr:reswingAll(name)` →
`vm:reswingPreset(name)` per take handles cross-take reswing. That
path keys off `e.frame.swing` / `e.frame.colSwing` and writes new raw
from `e.ppqL` directly via `tm:assignEvent`. Step 4.7's rule exempts
frame-bearing events, so the two paths partition: rule processes
non-frame events (currently empty), `reswingPreset` processes
frame-bearing events.

Once frame retires, `reswingPreset`'s include filter has nothing to
match. The rule becomes the sole reswing mechanism. `seqMgr:reswingAll`
re-routes through it: per affected take, bind → mark stale channels
→ rebuild. Eager (so playback hears the change project-wide
immediately); no persistent stale flag needed because the visit is
already there.

#### Granularity of stale marking

`tm:markSwingStale(nil)` walks all 16 channels and rebuilds raw for
every event in the take. Acceptable today (frame-exempt events skip
the rule, so the walk is O(events) returns-early). Wrong cut once the
rule is the sole path — most events in a take are unaffected by any
single library edit.

Refine the call sites against the trigger surface:

- **library entry edited (`swings` key)** — swingEditor knows the
  edited name. Per take, compute the set of channels whose resolved
  swing is that name: `chan` where `cm:get('swing') == name` or
  `cm:get('colSwing')[chan] == name`. Mark only those.
- **global swing change (`swing` key)** — all 16 channels (global
  applies everywhere). `markSwingStale(nil)` stays correct.
- **per-column swing change (`colSwing` key)** — only channels whose
  entry changed. The subscriber needs the previous `colSwing` table
  to diff against the new one; cache it inside tm and update on each
  configChanged for the key.
- **slot reassignment** — collapses to `swing` or `colSwing` change
  by name, handled above.

Phase 3 wiring leaves `markSwingStale(nil)` everywhere as a placeholder
that's correct under frame-exempt rules. Tighten in Phase 7 once the
rule processes all events.

Lands green: docs match code.
