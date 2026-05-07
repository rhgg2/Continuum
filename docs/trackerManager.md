# trackerManager

Parses a midiManager's MIDI stream into tracker-style channels with typed
columns, resolves tuning and timing (swing + per-note delay), and
exposes a batched mutation interface that writes back to mm. Rebuilds
automatically whenever mm or cm fires.

## Channel & column model

16 channels, one per MIDI channel. Each channel carries a `columns` table:

| kind     | shape                                  | source                    |
|----------|----------------------------------------|---------------------------|
| `notes`  | dense array, index = lane              | mm notes (lane in metadata) |
| `pb`     | singleton column or nil                | mm cc, msgType=`pb`       |
| `pc`     | singleton column or nil                | mm cc, msgType=`pc`       |
| `at`     | singleton column or nil                | mm cc, msgType=`at`       |
| `ccs`    | sparse dict keyed by CC number         | mm cc, msgType=`cc`       |

Every column has `events` (array sorted by **intent** ppq). `cc` columns
additionally carry `cc` (the controller number). Presentation order is a
vm concern — tm imposes none.

Poly-aftertouch (`pa`) events do **not** get their own column. They
attach to the note column whose voice they modulate (see *PA binding*
below), appearing as `{ type='pa', pitch, vel, ppq }` entries mixed into
that column's `events`.

## Lane identity

Note columns carry no identity beyond their position among note columns
in the channel. A note's "lane" is that position, persisted per note
under the `lane` key. Lane counts are stable across rebuilds via
`cfg.extraColumns[chan].notes`, a per-channel high-water mark:

- rebuild grows it when live allocation exceeds it;
- lanes only shrink via explicit user action in vm.

`extraColumns` is also the single source of "columns the user has opened
per channel" — columns present in extras but not backed by events are
materialised as empty, so consumers see a uniform `channel.columns`
irrespective of whether a column is data-driven or user-opened.

```
extraColumns[chan] = {
  notes = <count>,
  pc = true, pb = true, at = true,
  ccs = { [ccNum] = true },
}
```

## Update manager (um)

tm's private write-side object. All mutations — from vm and from tm's
own rebuild-time housekeeping — funnel through `um`, which applies them
to a local cache and accumulates mm-facing ops. `um:flush()` commits the
batch in one `mm:modify` call. `um` is re-created once per rebuild, so
its view of mm matches tm's own.

The sections below reference `um` by name because its frame and
encoding choices (cents not raw, realised not intent) are the reason
several conventions exist.

## Pitchbend: tm's role in the tuning model

See `docs/tuning.md` for the cross-cutting model — detune as intent,
pb as realisation, the fake-pb absorber invariant, and the
orthogonality rule. tm is where the model is implemented. The
tm-specific facts:

- **Cents inside, raw at the boundary.** Inside `um`, `pb.val` is
  always cents. Conversion to raw happens only on load (`rawToCents`)
  and at flush (`centsToRaw`). The cents window is
  `cm:get('pbRange') * 100` per side.
- **Lane-1 drives detune.** Every note has a `detune` field, but
  only lane-1 notes feed the pb-realisation logic — `detuneAt` /
  `detuneBefore` walk only `chans[chan].notes`, which is built from
  lane-1 entries (see `addLowlevel`). Higher lanes' detune is dead
  data for realisation purposes; it survives so display layers and
  any future lane-promotion paths can read it back.
- **Fake-pb persistence.** Absorbers carry `fake=true` as cc
  metadata via `mm:assignCC` / `mm:addCC`'s lazy-sidecar path. Fake
  pbs are hidden from the pb column unless an interp shape pulls
  them into view (`hidden = cc.fake and (shape==nil or 'step')`);
  the host note for delay inheritance is the lane-1 note at exactly
  `cc.ppq` whenever `cc.fake` is set.
- **Helpers.** `markFake` / `unmarkFake` toggle the flag;
  `reconcileBoundary` runs the both-directions absorber check
  (drop-redundant + seat-missing) after every detune mutation that
  crosses a seat. The host note carries no marker — it's recovered
  geometrically.

### Implementation invariants

Cross-cutting invariants I1-I5 (see `docs/tuning.md`) define the
contract. The three below are tm-specific — they capture *how* tm
fulfils that contract, and would change shape if the realisation
mechanism did:

- **I6 — Cents inside, raw at boundary.** Inside `um`, `pb.val` is
  always cents. Conversion to raw happens only on load
  (`rawToCents`) and at flush (`centsToRaw`). The cents window is
  `cm:get('pbRange') * 100` per side.
- **I7 — Delay topology.** A pure delay change on a lane-1 note
  shifts the absorber along with the host. Pb count and the
  logical stream are preserved; only the realised ppq of host and
  absorber move together. Implemented by routing delay changes
  through `realiseNoteUpdate` → `resizeNote`, which deletes the
  fake at the old seat and reconciles a fresh one at the new seat.
- **I8 — Round-trip stability.** flush → rebuild → flush produces
  an identical pb dump. `fake=true` survives via cc-sidecar
  metadata; absorbers inherit host delay at rebuild so `tidyCol`
  shifts host and absorber into intent together.

Mutation entry points that touch detune realisation —
`addNote`, `assignNote`-detune, `resizeNote`, `deleteNote` — all
gate on `n.lane == 1` to uphold I3. The fake-pb cleanup,
`retuneLowlevel`, and `reconcileBoundary` calls are lane-1-only.

## Where tm sits in the timing model

See `docs/timing.md` for the three-frame model (logical / intent /
realisation) and the full conversion stack. tm's role in it:

- **Public surface is intent.** Channel events expose intent ppq,
  sorted by intent ppq; `endppq` is intent at every layer.
- **`um` and rebuild work in realisation** — REAPER's storage frame.
  `tidyCol` is the sole shift into intent at rebuild's tail;
  `um:addEvent` / `um:assignEvent` add delay back on writes to mm.

A delay change with no ppq update pins intent and shifts realised
onset by the delta (`realiseNoteUpdate`).

Fake pbs inherit their host note's `delay` at rebuild time so
`tidyCol` shifts host and absorber into intent together. Without
this, a delayed note and its absorber would desynchronise at the vm
boundary.

## Swing

tm is only a registry here: `cfg.swing` (global) and `cfg.colSwing[c]`
(per column) hold slot names referring into `cfg.swings`. The
semantics — what a slot *is*, how factors compose, how
logical↔intent works — live in `docs/timing.md`.

`tm:swingSnapshot(override)` hands callers a frozen view of the
currently registered swing with `fromLogical`/`toLogical` closures
ready to use. Pass `override` to substitute alternative slot names or
shadow the library (preset edits need the authoring and target
composites for the same name side-by-side).

## Mutation contract

Edits enter tm through the four methods below, which delegate to `um`.
Never reach around them to mm directly. Because `um` is rebuilt each
rebuild, **don't cache `loc` values across a flush** — their validity
ends there.

```
tm:addEvent(type, evt)               -- local apply + stage add
tm:assignEvent(type, evt, upd, opts) -- local apply + stage assign
tm:deleteEvent(type, evt)            -- local apply + stage delete
tm:flush()                           -- commit staged ops in one mm:modify
```

Semantics:

- **Rejected updates.** Changing a note's `chan` or `lane` via
  `assignEvent` is rejected (prints a warning and drops the call).
- **Single voice per (chan, pitch) — realised space.** `clearSameKeyRange`
  truncates or deletes overlapping same-key notes around any add or
  move. The MIDI spec gives one voice per `(chan, pitch)`, so a
  *realised* collision must always shorten or drop a note regardless
  of intent geometry. The reconciliation therefore compares onsets in
  realised space (`n.ppq` from `notesByLoc` is realised), and the
  resulting `endppq` write — though `endppq` is intent at every layer
  per F3 — is the moment we now intend to end, forced by the voice
  collision. vm-side `delayRange` is the user-facing gate that keeps
  legitimate edits from creating these collisions in the first place;
  rebuild's group-by-pitch pass is the backstop for foreign MIDI.
  A caller staging a coherent monotone batch (where the end-state has
  no new same-key overlaps) can pass `opts.trustGeometry` on
  `assignEvent` to skip the per-write clamp. Reswing uses this —
  without it, the first-processed of two legato siblings sees its
  endppq clipped against the second's still-old ppq.
- **Detune changes (col-1 notes).** `assignNote` seats a pb at the
  boundary if needed, retunes the raw stream forward to the next note,
  then drops the boundary if it became redundant.
- **PA follows host.** Resizing or moving a note shifts attached PAs
  with it when the shift preserves the window; otherwise PAs outside
  the new window are deleted and the last trimmed PA's value becomes
  the note's `vel`.
- **Fake-pb housekeeping.** `addPb` unmarks fake on the affected
  boundary; `deletePb` either really deletes or re-marks fake
  depending on whether detune and neighbour detune agree.
- **Flush re-entrancy.** `flush` snapshots and clears `adds/assigns/
  deletes` **before** calling `mm:modify`, because mm's callbacks can
  reach back into the same um (e.g. via `setMutedChannels`). Without
  the up-front clear, in-flight ops would be re-emitted.

## Rebuild

Triggered by:
- mm `'reload'` signal — always rebuilds. The take-swap flag travels via
  the separate mm `'takeSwapped'` signal, captured into a transient flag
  and consumed by the next reload (mm guarantees the firing order);
- cm `'configChanged'` signal, except for `vmOnlyKeys` (`mutedChannels`,
  `soloedChannels`) which do not touch tm's structural view.

tm also forwards the reconciliation signals it receives from mm
(`takeSwapped`, `notesDeduped`, `uuidsReassigned`) to its own subscribers,
so layers above tm needn't reach into mm.

Reentrancy-guarded by `rebuilding`. Steps:

1. **Seed + normalise notes.** Walk mm notes once. Any note lacking
   `detune`/`delay` is seeded with `0` via metadata-only `assignNote`
   (no lock). Under `trackerMode`, missing `sample` is also seeded —
   from the prevailing PC at the note's realised onset (or `0` if no
   prior PC). Same rule serves the on-toggle reverse-derive and the
   steady-state default. Build `(chan,pitch)` groups, then truncate
   overlaps under a single `mm:modify` so every subsequent walk sees
   clean intervals.
2. **Allocate lanes.** `allocateNoteColumn` prefers the persisted
   `note.lane`; falls through to first-fit, then spills to a new
   column. If the preferred lane doesn't exist yet, columns are pushed
   until it does. Lane changes write back via `mm:assignNote`.
3. **Single CC walk.** Distributes by `msgType`:
   - `pb` — emit logical-cents events with detune context and hidden
     flag; accumulate per channel so the column installs only when at
     least one event is visible.
   - `pa` — attach to note column containing `(pitch, ppq)`.
   - `cc` — append to `ccs[cc]`.
   - `at` / `pc` — append to the channel's singleton column.

   All four branches go through `projectCC(cc, loc, overlay)`, which
   strips only the routing fields the destination col owns
   (`chan`, `msgType`, `cc`) and overlays the per-msgType derived
   fields. Anything else on the source — including custom metadata
   fields not yet known here — rides through verbatim. The strip set
   is rule-based, not a fixed allowlist, so future event metadata
   reaches `col.events` without changes to this layer.
4. **Reconcile extras.** Grow `extraColumns[chan].notes` if live
   allocation exceeded it; pad empty note lanes; materialise
   user-opened singletons/ccs that carry no events. Writes back via
   `cm:set` if the high-water mark grew.
4½. **PC synthesis (trackerMode only).** For each channel, group lane
   events (still in realised frame here, so `realised(n) = n.ppq`
   directly) by realised ppq. Leftmost lane wins: its sample becomes
   the PC val, others get `n.sampleShadowed = true` for renderer
   dimming. Synthesised PCs land at realised ppq with `delay=0`, so
   tidyCol below is a no-op for them. The reconcile helper
   (`reconcilePCsForChan`) carries locs forward where `(ppq, val)`
   matches existing fake PCs — steady state writes nothing. After the
   `mm:modify`, mm's reindex moves PC locs around (sort by `(ppq,
   chan, ...)`), so `c.pc.events` is refreshed from a fresh
   `mm:ccs()` walk to give flush-time reconciles stable locs.
5. **tidyCol.** Strip delay into intent frame and sort each column's
   events by intent ppq.

Then `um = createUpdateManager()` and tm fires the `'rebuild'` signal
(no payload).

## PC synthesis under trackerMode

`note.sample` is per-note authoring intent (which sample the note
plays); the PC stream is the realisation MIDI synths consume. tm owns
the reconciliation. Synthesis runs in two places:

- **Rebuild step 4½** does the full sweep: re-derives every channel's
  PC stream from current note state and writes the delta to mm.
- **Flush-time reconcile** (in `um:flush`, gated on `dirtyPcChans`)
  does the same per-channel for any channel whose notes mutated since
  the last flush. `addNote`, `deleteNote`, and `assignNote` updates
  to `sample` / `ppq` (where ppq covers delay too — `realiseNoteUpdate`
  maps delay→ppq before assignNote sees it) all dirty the channel.

Both call sites build a `records` list `{ ppq, lane, sample, key }`
from their available source (lane events for rebuild; `notesByLoc` +
pending adds for flush) and feed it through the same pure
`reconcilePCsForChan` helper. The `key` is a record-identity opaque
to the helper — callers receive a `shadowed` set keyed by it and
stamp `sampleShadowed = true` on whichever object should render
dimmed. At flush time that's the lane event found via a one-pass
`loc → laneEvent` cross-walk; at rebuild it's the lane event itself.

Group membership is by **realised** ppq, not intent — same-channel
simultaneity is a MIDI-realisation constraint (one PC stream per
channel at any moment), so the leftmost-wins rule fires only when
realised onsets actually collide. Notes split apart by delay get
their own PC each, even if their intent ppqs match.

## Column allocation rules

`noteColumnAccepts(col, note)`:

Comparisons run in **intent space**: the candidate's note-on has its
delay subtracted, and each existing event's note-on has its own delay
subtracted. `endppq` is already intent in storage (delay never shifts
the note-off — see `docs/timing.md`). This keeps column allocation
independent of delay: changing a note's delay can never push it into
a different column or spring a new one.

The overlap threshold is **per-pair**: same-pitch comparisons get
a hard `0` (MIDI allows only one voice per `(chan, pitch)`), while
different-pitch comparisons get the configured leniency
`cm:get('overlapOffset') * resolution`.

- same intent start tick as any existing note ⇒ reject (always spill);
- intent overlap amount > pair threshold with any single existing
  note ⇒ reject;
- two or more existing notes overlap this one in intent ⇒ reject.

Otherwise the column accepts.

Cross-column same-pitch non-overlap is held by the rebuild
truncation pass and `clearSameKeyRange`; the per-pair threshold
above is defence in depth.

## PA binding

`findNoteColumnForPitch(chan, pitch, ppq)` prefers the **active voice**
— a note whose interval contains `ppq` with matching pitch. If no voice
is active, any column containing any note of that pitch accepts. PAs
with no matching pitch anywhere in the channel are dropped.

## Muting

vm owns the effective mute set (persistent mute ∪ solo-implied mute)
and pushes it via `tm:setMutedChannels(set)`. tm:

- stores it in `lastMuteSet` (used to tag later-added notes in um);
- idempotently syncs REAPER's native muted flag on every existing note
  through `um:assignEvent`, then flushes.

Mute state is a vm-side concern — it **does not** trigger a structural
rebuild (see `vmOnlyKeys`).

## Conventions

- **Channels 1..16**, inherited from mm.
- **Ppq throughout.** Intent frame at the vm boundary, realised frame
  inside um and toward mm. `timing.delayToPPQ` is the sole converter.
- **pb.val in cents** inside tm; raw conversion only at load and flush.
- **Fake pb flag.** `pb.fake` is the sole marker (persisted as cc
  metadata); always toggle through `markFake`/`unmarkFake`.
- **`util.REMOVE`** as a value in `assignEvent` deletes the field
  (passed through to mm).
- **Location lifetime.** `loc` values are valid only within a single
  rebuild-to-flush window; um's `notesByLoc` / `ccsByLoc` are rebuilt
  fresh each rebuild.
