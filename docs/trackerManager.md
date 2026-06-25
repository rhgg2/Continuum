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
tm:assignEvent(type, evt, upd)       -- local apply + stage assign
tm:deleteEvent(type, evt)            -- local apply + stage delete
tm:flush()                           -- commit staged ops in one mm:modify
```

Semantics:

- **Rejected updates.** Changing a note's `chan` or `lane` via
  `assignEvent` is rejected (prints a warning and drops the call).
- **Single voice per (chan, pitch) — realised space.** MIDI permits
  one voice per `(chan, pitch)`, so a realised collision must shorten
  or drop a note regardless of intent geometry. vm writes authored
  intent verbatim; `tm:rebuild` step 4.8 (universal tail walk,
  grouped by pitch within channel) is the sole gate — it clamps each
  note's realised onset against the next same-pitch onset and
  surfaces the divergence as `endppq ≠ endppqC` in the projection.
  The clamp lives entirely on the realisation side: `endppqL` retains
  the authored ceiling. A caller staging a coherent monotone plan can
  bypass the per-write logical→raw translation by setting
  `rawTime = true` on the payload — `tm:rescaleLength`'s
  plan-then-mutate path is the sole such caller; the flag is consumed
  in realise so it never reaches mm.
- **Detune changes (col-1 notes).** `assignNote` seats a pb at the
  boundary if needed, retunes the raw stream forward to the next note,
  then drops the boundary if it became redundant.
- **PA follows host.** Resizing or moving a note shifts attached PAs
  with it when the shift preserves the window; otherwise PAs outside
  the new window are deleted and the last trimmed PA's value becomes
  the note's `vel`. `resizeNote` accepts an explicit `cullEnd` ceiling
  distinct from `P2`: for an open tail `stampEndppq` plants a provisional
  raw note-off (`ppq+1`) that the tail pass later overwrites, so culling
  against `P2` would drop every PA past the onset.
- **Fake-pb housekeeping.** Adding a pb unmarks fake on the affected
  boundary; deleting one either really deletes or re-marks fake
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

Reentrancy-guarded by `rebuilding`. Also guarded against a dead take: if
`mm:take()` is nil (take deleted under us) `rebuild` returns immediately,
retaining tv's last rendered frame. This is the same liveTake guard every
other mm consumer applies; without it a foreign-track `configChanged` fired
during arrange's take-delete sequence would crash on a nil resolution.

Steps:

1. **Seed + normalise notes.** Walk mm notes once. Any note lacking
   `detune`/`delay` is seeded with `0` via metadata-only `assignNote`
   (no lock). Under `trackerMode`, missing `sample` is also seeded —
   from the prevailing PC at the note's realised onset (or `0` if no
   prior PC). Same rule serves the on-toggle reverse-derive and the
   steady-state default. Build `(chan,pitch)` groups, then truncate
   overlaps under a single `mm:modify` so every subsequent walk sees
   clean intervals.
2. **Allocate lanes.** A *stamped* note (`ppqL ~= nil`: authored
   tracker data) is model-governed — the universal tail pass clips its
   realised note-off to its lane neighbour, so it can never overlap;
   `allocateNoteColumn` returns its authored `note.lane` verbatim,
   pushing columns until it exists. Only an *unstamped* raw note
   (`ppqL == nil`: foreign-MIDI import) runs first-fit and spills to a
   new column. Lane changes write back via `mm:assignNote`.
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
4.6. **Macro expansion.** Each lane-1 note carrying `fx` runs its
   generator (`generators.<kind>`, a pure module); the derived `fxNote`s
   reconcile against the set parsed out at step 0 — `reconcileFx`: keep
   geometry-identical, add new, drop stale, mirroring `reconcilePCsForChan`
   at the note level. fxNotes carry `derived = <hostUuid>` and route out
   of columns (invisible to vm, the absorber pass, render), but union
   into the tail walk — so the host's realised tail truncates to fxNote 2
   and fxNotes clip each other with no bespoke truncation — and into PC
   synthesis, carrying the host's `sample`. See `design/note-macros.md`.
   After reconcile, `fxLive` (the post-expansion derived set the tail walk
   and PC synthesis consume) is rebuilt by re-scanning `mm:notes()` for fresh
   tokens — but only when reconcile actually churned the take. On a no-churn
   rebuild the derived set is untouched, so `fxExisting` (gathered at step 0)
   already lists it with current tokens, and the full re-scan is skipped.
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

The universal tail pass (step 4.8) resolves each note's realised
note-off against its same-lane and same-pitch successors. The "strict
next" — first group member with a strictly greater ppq, chord-mates at
equal ppq skipped — is precomputed once per ppq-sorted group in a
back-to-front pass, then looked up per note. It used to be rescanned
linearly per note: a retrig host expands to a long run of same-pitch
fxNotes, so that scan made the walk O(k²) inside the group and dominated
rebuild on macro-heavy takes.

### Dormant guard

When the tracker page is not active, `bindTake(nil)` clears cm's take context
while mm still holds the last take. The shared cm fires `configChanged` every
frame regardless of which page is active (e.g. samplePage's per-frame tick). A rebuild
fired in this state would resolve swing/trackerMode off empty take tiers, causing
a mm/cm mismatch. The `configChanged` subscriber therefore returns early if
`cm:boundTake()` is nil; the next real `bindTake` call fires a coherent rebuild.

## PC synthesis under trackerMode

`note.sample` is per-note authoring intent (which sample the note
plays); the PC stream is the realisation MIDI synths consume. tm owns
the reconciliation.

`trackerMode` itself is wiring-derived, not a per-frame probe: on each
`bindTake` the page asks `wm:samplerReachable(take.track)` — does the
take's MIDI cone reach a Continuum Sampler — and seeds the transient
tier inside the bind's suppression window. So the mode tracks the
*bound* take, never lagging on the arrange cursor mid-navigation (the
bug that leaked synthetic PCs onto a non-tracker take's note-ons).

Synthesis runs in two places:

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

`noteColumnAccepts` is consulted only for unstamped raw notes; a
stamped note never reaches it (see Rebuild step 2). For an unstamped
candidate, `noteColumnAccepts(col, note)`:

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

## Aliases

tm holds the alias substrate: the spec-tree walker that runs inside
`rebuild`, two side tables (`specOf` keyed by uuid, `nodeMeta` keyed
by spec-node identity) for in-memory navigation, and the routing /
severance / cascade-delete primitives consumed by vm. The model and
the contract for each primitive are in `docs/aliases.md`. Two
tm-local commitments worth recording here:

- **Side-table lifetime.** Both maps are cleared at the head of every
  `rebuild` and rebuilt by the walker. They never persist. Code outside
  tm reaches them only through `tm:specOf` / `tm:nodeMeta`; reaching
  past those accessors couples to the rebuild boundary.
- **Mutation primitives flush nothing.** `tm:routeRelative`,
  `tm:severBatch`, `tm:sever`, `tm:deleteAliased`, `tm:createAlias`
  stage ops on `um` and return. The caller drives a single `tm:flush`
  across a batch, so a structural delete that promotes ten children
  flushes once.

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

## Staged-update bounds

When `realiseNoteUpdate` stages a delay or endppq change, the raw onset
and raw tail are clamped immediately (`onset ≥ 0`, `tail ≤ takeLen`).
This is NOT the authoritative clip — step 4.8 re-applies the full
same-pitch and take-edge constraints against the final post-walk geometry,
and flush re-applies on every write. Clamping here keeps the staged raw
value in range so interim mm readers (before the next rebuild) never see
out-of-range values. Divergence surfaces as `delay ~= delayC` (tp paints
`*` next to the delay digits) and `endppq ~= endppqC`; the renderer draws
`endppqC`, so no separate endppq cue is needed.

## Pre-clip collision scan

Run inside `mm:modify`'s preflush, after `preflush` (propagated peers
already staged) and before the snapshot (clamps/deletes ride this flush).
Scans ALL post-flush notes — `byToken` all lanes plus staged adds — for
same-`(chan, pitch)` MIDI legality in one pass.

Not a per-self peer walk: two notes can collide without either being the
edited one, and repeated per-self truncation damages peers a later
same-flush op would resolve.

This is the staging pre-clip only; the authoritative raw tail is
re-derived by rebuild step 4.8. `endppqL` (intent) is never written here
— deleting a blocker lets the raw tail regrow to it.

## Length operations

### rescaleLength(newPpq)

Stretches the take by linearly remapping the logical frame. Each event on
logical row `r` ends up at row `f·r` where `f = newPpq/oldPpq`. `ppqL`
stamps scale by `f`; raw ppqs are rederived through swing, so under
non-identity swing raw ppqs are NOT linearly scaled — rows are preserved,
which keeps reswing well-defined. Note delays scale by `f`. Frame stamps
(`rpb`, swing slot names) are untouched. No events are deleted.

### tileLength(newPpq)

Loops `[0, oldPpq)` at offsets `k·oldPpq` for `k = 1 .. ceil(newPpq/oldPpq)-1`.
Copies whose shifted ppq lands at-or-past `newPpq` are dropped; note
`endppq`s extending past `newPpq` are clamped. Originals untouched.
Shrinks fall through to `setLength`.

Walks mm-level events directly rather than column-projected ones because
projection strips fields a verbatim replica needs (cc number, pb fake
flag, user metadata). Since `oldPpq` sits on a swing-period boundary
(take length aligns to QN), shifting by `k·oldPpq` is identical in
logical and realised frames — one delta serves both `ppq` and `ppqL`
paths.

## Rebuild: step 0 — internal/external partition

Internal events are stamped (`ppqL ~= nil`) AND have raw ppq consistent
with `fromLogical(ppqL, delay)`. The main rebuild flows them branchlessly.
External events are foreign-MIDI (no `ppqL`) or externally-edited stamped
records (Ctrl-Z, foreign script made raw diverge from `fromLogical`).
They re-enter at step 6: notes get a fresh lane pack and
`ppqL`/`endppqL` stamp; CCs get `ppqL` stamped in-line in step 3.

**Exception for `realiseNoteUpdate`'s floor:** when authored delay pushes
the realised onset negative, raw is clamped to 0 while `ppqL`/`delay`
retain the intent. This divergence is intentional and surfaces as
`delayC` (tp paints `*`). Recognise the clamp shape
(`raw == 0 AND fromLogical(ppqL, delay) < 0`) and stay internal.

## Rebuild: step 3 — CC walk

Reconciles each non-fake CC's `(raw, ppqL)` under the current swing, then
projects non-pb CCs into columns:

- `staleSwing[chan]`: ppqL is truth; reseat `raw = fromLogical(ppqL)`.
- Otherwise, if raw diverges from ppqL: external raw edit; restamp
  `ppqL = toLogical(raw)`.

Reconcile updates are mutated into the live cc record so the subsequent
column-event clone sees up-to-date values; `mm:assign` propagates them at
the end of the walk.

Fakes are handled separately: fake pbs by step 4.9 (whole absorber pass
against post-walk lane-1 layout); fake PCs by step 4.5. Pb column
projection is deferred to step 4.9 so it sees the final reconciled fakes
and recomputed raw vals.

## Rebuild: step 6 — externals

Per external in raw-ppq order: pack a lane against the now-settled
internals plus any earlier externals already placed (`noteColumnAccepts`
sees realised tails); stamp `ppqL`/`endppqL` from raw; backfill missing
metadata (foreign-MIDI lacks all; stale-stamped notes arrive with authored
detune/delay intact). Column event inserted in lockstep so each subsequent
external's pack sees prior ones. Tagged `evt.external = true` so step 4.8
treats it as a BLOCKER — its onset shows up as 'next' for internals — but
the walk never writes to its tail or clamps its onset.

## Rebuild: step 4.8 — tail walk

Tail target for each internal note:

```
max(onset + 1, min(
  fromLogical(endppqL),                       -- authored ceiling; math.huge for util.OPEN
  fromLogical(nextSameLane.ppqL) + overlap,   -- same-lane next (INTENT)
  nextSamePitch.ppq,                          -- same-pitch next (RAW)
  takeLen))
```

Same-lane uses INTENT (`ppqL`) so authored music geometry wins over
realisation delays. Same-pitch uses RAW because MIDI physics is realised.
"Next" is strict-greater on raw ppq — a chord-mate at the same onset is
not following.

Collision (current raw `<=` prev same-pitch raw, raw-order with ppqL
tie-break): the successor is clamped to `prev.ppq + 1`. Authored swap
survives: when raw order differs from logical order, whoever lands first
in raw becomes the realised predecessor.

Externals (tagged `evt.external` by step 6) participate as BLOCKERS only
— their onsets appear as 'next' lookups so internal tails clip against
them — but the walk never writes to them.

## Rebuild: step 5 — project to logical

tv surface is logical-only: both onset and tail leave here in the
authoring frame; raw stays private to tm/mm. `evt.ppq` and `evt.endppq`
are floats — the logical frame is float by design, and the on-grid
predicate (`ctx:isOnGrid`) is the sole owner of row-membership tolerance.
Rounding here would silently widen that tolerance to 1 ppq.

`evt.endppq` is the AUTHORED logical ceiling (`endppqL` or `util.OPEN`
for a deliberately-unbounded tail). The tail pass already folded every
blocker into mm's raw endppq; inverting gives `evt.endppqC`, the CLIPPED
logical ceiling — render-only, sole consumer is the tp tail build. An
uncached note (no `endppqL`) has no authored stamp, so its authored
ceiling equals the realised one.
