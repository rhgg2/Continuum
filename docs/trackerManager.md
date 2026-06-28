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
| `pb`     | singleton column or nil                | mm cc, evType=`pb`       |
| `pc`     | singleton column or nil                | mm cc, evType=`pc`       |
| `at`     | singleton column or nil                | mm cc, evType=`at`       |
| `ccs`    | sparse dict keyed by CC number         | mm cc, evType=`cc`       |

Every column has `events` (array sorted by **logical** ppq). `cc` columns
additionally carry `cc` (the controller number). Presentation order is a
tv concern — tm imposes none.

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
- lanes only shrink via explicit user action in tv.

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

tm's write side — a staging layer folded into tm's own scope (the source
banners it `-- UPDATE MANAGER`), not a separate object. All mutations —
from tv and from tm's own rebuild-time housekeeping — funnel through
`tm:addEvent` / `tm:assignEvent` / `tm:deleteEvent`, which apply to a
local cache (`byToken`, `byUuid`, per-channel `chans`) and accumulate
mm-facing ops in `adds`/`assigns`/`deletes`. `tm:flush()` commits the
batch in one `mm:modify` call. `reload()` rebuilds that cache from
`mm:events()` — at module init and at the tail of every rebuild — so um's
view of mm always matches tm's own.

The sections below reference um by name because its frame and encoding
choices (cents not raw; realisation toward mm, logical at the public
surface) are the reason several conventions exist.

## Pitchbend: tm's role in the tuning model

See `docs/tuning.md` for the cross-cutting model — detune as intent,
pb as realisation, the absorber invariant, and the
orthogonality rule. tm is where the model is implemented. The
tm-specific facts:

- **Cents inside, raw at the boundary.** Inside `um`, `pb.val` is
  always cents. Conversion to raw happens only on load (`rawToCents`)
  and at flush (`centsToRaw`). The cents window is
  `cm:get('pbRange') * 100` per side.
- **Lane-1 drives detune.** Every note has a `detune` field, but
  only lane-1 notes feed the pb-realisation logic — `detuneAt` walks
  only `chans[chan].notes`, which is built from lane-1 entries (see
  `addLowlevel`). Higher lanes' detune is dead data for realisation
  purposes; it survives so display layers and any future
  lane-promotion paths can read it back.
- **Absorber persistence.** Absorbers carry `derived='absorber'` as
  pb metadata via mm's lazy-sidecar path. They are hidden from the pb
  column unless an interp shape pulls them into view
  (`hidden = pb.derived and (shape==nil or shape=='step')`); the host
  note for delay inheritance is the lane-1 note at the absorber's seat
  (`pb.ppq`), recovered geometrically — the host carries no marker.
- **No per-mutation upkeep.** There is no `markFake`/`reconcileBoundary`
  machinery: absorbers are not maintained on each edit. The absorber pass
  reseats the whole absorber set against the final post-walk lane-1
  layout, so a detune edit just writes `n.detune` and lets the next
  rebuild reconcile.

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
  absorber move together. Delay edits route through
  `realiseNoteUpdate` → `resizeNote` (which moves the host's raw
  onset); the absorber pass then reseats the absorber to the new seat.
- **I8 — Round-trip stability.** flush → rebuild → flush produces
  an identical pb dump. `derived='absorber'` survives via pb-sidecar
  metadata; an absorber's seat is the host's lane-1 onset, so the logical
  projection lands host and absorber onto the same logical row together.

Only lane-1 notes drive detune realisation (I3), enforced in rebuild's
absorber pass: it reads only lane-1 onsets, so higher-lane
detune never reaches the pb stream. Mutation entry points (`addNote`,
`assignNote`, `resizeNote`, `deleteNote`) write detune as plain
metadata; the next rebuild does the realisation.

## Where tm sits in the timing model

See `docs/timing.md` for the two-frame model (logical / realisation,
connected by swing) and the full conversion stack. Delay is a per-note
offset on the raw note-on, not a frame of its own. tm's role:

- **Public surface is logical.** Channel events expose logical ppq,
  sorted by logical ppq; `endppq` leaves as the authored logical
  ceiling (`endppqL`, or `util.OPEN`).
- **um and rebuild work in realisation** — REAPER's storage frame.
  Rebuild's logical-projection step (`projectToLogical`) is the sole shift to logical at
  rebuild's tail; `tm:addEvent` / `tm:assignEvent` translate logical to
  raw (adding delay back) on writes to mm.

A delay change with no ppq update pins the logical onset and shifts the
realised onset by the delta (`realiseNoteUpdate`).

An absorber's seat is its host's lane-1 onset, so logical projection lands host
and absorber onto the same logical row. Without this a delayed note and
its absorber would desynchronise at the tv boundary.

## Swing

tm is only a registry here. The named-swing library lives in
`cm:get('swings')`; per-channel assignments live in `ds:get('swing')`
(`chan → name`); `cm:get('defaultSwing')` is the global fallback. The
semantics — what a slot *is*, how factors compose, how
logical↔realisation works — live in `docs/timing.md`.

tm exposes the resolved transforms as `tm:fromLogical(chan, ppqL, off)`
and `tm:toLogical(chan, ppq)`, cached per `(cm, mm)` in `swingSnap` and
cleared at the head of each rebuild (`clearSwing`). `tm:markSwingStale`
flags channels whose resolved swing changed so the next rebuild
rederives their raw ppqs from `ppqL`.

## Mutation contract

Edits enter tm through the four methods below, which delegate to `um`.
Never reach around them to mm directly. Because `um` is rebuilt each
rebuild, **don't cache `loc` values across a flush** — their validity
ends there.

```
tm:addEvent(evt)                     -- local apply + stage add
tm:assignEvent(evt, update)          -- local apply + stage assign
tm:deleteEvent(evt)                  -- local apply + stage delete
tm:flush()                           -- commit staged ops in one mm:modify
```

Semantics:

- **Rejected updates.** Changing a note's `lane` via `assignEvent` is
  rejected (prints a warning, drops the call) — column membership is
  rebuild-owned. A `chan` change is accepted; rebuild's absorber pass
  reconciles fakes across both channels.
- **Single voice per (chan, pitch) — realised space.** MIDI permits
  one voice per `(chan, pitch)`. tv writes authored logical verbatim;
  distinct voices that collide in realised raw (swing/delay-collapsed,
  or a same-row detune cluster) are separated by a +1 nudge — not
  dropped — so each keeps its own pb absorber (§ Same-pitch onset
  separation). The divergence surfaces as `endppq ≠ endppqC` in the
  projection and as `delayC` on the onset. Separation lives entirely on
  the realisation side: `endppqL` retains the authored ceiling. A caller
  staging a coherent monotone plan can
  bypass the per-write logical→raw translation by setting
  `rawTime = true` on the payload — `tm:rescaleLength`'s
  plan-then-mutate path is the sole such caller; the flag is consumed
  in realise so it never reaches mm.
- **Detune changes (lane-1 notes).** `assignEvent` writes the new
  detune as plain metadata; rebuild's absorber pass reseats absorbers and
  recomputes the raw pb stream from the final post-walk layout.
- **PA follows host.** Resizing or moving a note shifts attached PAs
  with it when the shift preserves the window; otherwise PAs outside
  the new window are deleted and the last trimmed PA's value becomes
  the note's `vel`. `resizeNote` accepts an explicit `cullEnd` ceiling
  distinct from `P2`: for an open tail `stampEndppq` plants a provisional
  raw note-off (`ppq+1`) that the tail pass later overwrites, so culling
  against `P2` would drop every PA past the onset.
- **Pb edits don't maintain absorbers.** Adding or deleting a real pb
  stages only that pb; the absorber set is reconciled wholesale by
  rebuild's absorber pass, never adjusted per-edit.
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

The pipeline runs in this order; each step is named for the helper that
runs it, with a pointer to its detail where one exists.

- **Partition & internal lanes** (`rebuildInternals`). Split mm notes
  into stamped-and-consistent *internals*, foreign-or-diverged
  *externals*, and derived fxNotes. Each internal clones into its
  authored lane via `pickStampedLane` (the tail walk clips its note-off,
  so it can never overlap); stale-swing internals rederive `raw` from
  `ppqL` under the new swing here (see `docs/timing.md` §"Rebuild rule").
  Externals are deferred to their own step. → § Rebuild: partition.
- **CC walk** (`rebuildCCs`). Arm prior carriers and route them out of
  columns, reconcile each non-derived CC's `(raw, ppqL)` under the
  current swing (stale-swing CCs reseated here), then project
  `cc`/`at`/`pc` into columns. pb projection defers to the absorber pass,
  pa dispatch to its own step. → § Rebuild: CC walk.
- **Reconcile extras** (`rebuildExtraColumns`). Grow
  `extraColumns[chan].notes` if live allocation exceeded it; pad empty
  note lanes; materialise user-opened singleton/cc columns that carry no
  events. Writes back via `ds:assign` if the high-water mark grew.
- **Reintroduce externals** (`rebuildExternals`). In raw-ppq order, pack
  each external a lane against the placed internals, stamp
  `ppqL`/`endppqL` from raw, and backfill missing metadata. Tagged
  `evt.fixed` so the tail walk freezes its onset but clips its tail like
  any note. Placed up front — before fx expansion — so externals bound fx
  windows and walk alongside everything else. → § Rebuild: externals.
- **Region-replace parking** (`rebuildRegionPark`). Authored notes and
  ccs a replace-region covers leave the take; the prior parked set splits
  into still-covered carry-forward and restores that re-enter their
  columns token-less. The note del/adds ride the tail walk's atomic
  commit. See `design/note-macros-v2.md` § Generator output.
- **PA dispatch** (`rebuildPA`). Attach each `pa` to the note column
  whose voice it modulates. Runs after column layout so the view and fx
  expansion read PAs inline, and after externals so foreign-MIDI PAs find
  their host.
- **Fx expansion** (`rebuildFx`). First the read-only **window** pass:
  walk each channel's same-lane successor map in the logical frame, so
  each fx host's window is its voice extent (the next same-lane onset's
  `ppqL`, floored by the authored end). Then every note carrying `fx`
  runs its generator over its window; the derived fxNotes reconcile
  against the partition's set (`reconcileFx`), and continuous deltas
  colour into carrier CC codes. The note add/del is **deferred** to the
  tail walk's atomic commit; `fxLive` (the predicted set) feeds the tail
  walk and PC synthesis. See `design/archive/note-macros.md`.
- **Tail walk** (`rebuildTails`). Real notes, fixed externals, and the
  predicted fxNotes walk together: clamp same-pitch onset collisions
  (fixed onsets frozen), then clip each realised note-off against its
  same-lane and same-pitch successors. The clips commit WITH the fxNote
  del/add in one `mm:modify`, so each host's clip to its first fxNote
  lands with the inserts. → § Rebuild: tail walk.
- **Absorber reconciliation** (`rebuildPbs`). Reseat absorber pbs against
  the post-walk lane-1 layout, recompute their raw vals, and project the
  pb column. See `docs/tuning.md` § Absorber reconciliation.
- **PC synthesis** (`rebuildPCs`, trackerMode only). Re-derive each
  channel's PC stream from current note state. Runs after externals so a
  foreign-MIDI note inherits its sample from the prevailing PC.
  → § PC synthesis under trackerMode.
- **Project to logical** (`projectLogical`). Shift every column event
  onto the logical frame (`evt.ppq = evt.ppqL`), derive the
  `delayC`/`endppqC` render cues, and sort each column by logical ppq.
  → § Rebuild: logical projection.

All projection runs through `projectCC(cc, token, overlay)`: it clones the
source event, strips only `chan` and `cc`, and applies the caller's
`overlay` of derived fields. Everything else — including metadata not
known here — rides through verbatim, so new event fields reach
`col.events` without a change to this layer.

Then `reload()` reloads tm's local cache from mm and clears the staging
buffers, and tm fires the `'rebuild'` signal carrying the `takeChanged`
boolean — true only when this rebuild followed a `bindTake` (a take-tier
reload).

The universal tail pass resolves each note's realised
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

- **Rebuild step 4.5** does the full sweep: re-derives every channel's
  PC stream from current note state and writes the delta to mm.
- **Flush-time reconcile** (in `flush()`, gated on `dirtyPcChans`)
  does the same per-channel for any channel whose notes mutated since
  the last flush. `addNote`, `deleteNote`, and `assignNote` updates
  to `sample` / `ppq` (where ppq covers delay too — `realiseNoteUpdate`
  maps delay→ppq before assignNote sees it) all dirty the channel.

Both call sites build a `records` list from their available source
(lane events for rebuild; `byToken` notes + pending adds for flush) and
feed it through the same pure `reconcilePCsForChan` helper. Only the
rebuild path passes a `key` (the lane event itself), so only it receives
the shadow marking — records lost to lane priority get
`sampleShadowed = true` for renderer dimming. The flush path builds
keyless records: it refreshes the PC stream but marks no shadows (the
next rebuild re-derives them).

Group membership is by **realised** ppq, not logical — same-channel
simultaneity is a MIDI-realisation constraint (one PC stream per
channel at any moment), so the leftmost-wins rule fires only when
realised onsets actually collide. Notes split apart by delay get
their own PC each, even if their logical ppqs match.

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

tv owns the effective mute set (persistent mute ∪ solo-implied mute)
and pushes it via `tm:setMutedChannels(set)`. tm:

- stores it in `lastMuteSet` (used to tag later-added notes in um);
- idempotently syncs REAPER's native muted flag on every existing note
  through `um:assignEvent`, then flushes.

Mute state is a tv-side concern — it **does not** trigger a structural
rebuild (see `vmOnlyKeys`).

## Conventions

- **Channels 1..16**, inherited from mm.
- **Ppq throughout.** Logical frame at the tv boundary, realised frame
  inside um and toward mm. `timing.delayToPPQ` is the sole converter.
- **pb.val in cents** inside tm; raw conversion only at load and flush.
- **Absorber marker.** `pb.derived == 'absorber'` is the sole marker
  (persisted as pb metadata); reconciled by rebuild step 4.9, never
  toggled per-edit.
- **`util.REMOVE`** as a value in `assignEvent` deletes the field
  (passed through to mm).
- **Token lifetime.** A `token` is content-keyed and re-keyed each
  rebuild, valid only within one rebuild-to-flush window; um's
  `byToken` / `byUuid` caches are rebuilt fresh each rebuild. Use `uuid`
  (`tm:byUuid`) for a durable cross-rebuild handle.

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

## Same-pitch onset separation

MIDI voices one note per `(chan, pitch)`. Two *distinct* voices that
collide in realised raw — distinct `ppqL` collapsed by swing or delay, or
a same-row detune cluster — must be kept apart, not dropped: each needs
its own pb absorber, and the give-way surfaces as `delayC`. mm forbids
the collision outright — its content-keyed token and reload-dedup both
key on `(ppq, chan, pitch)`, so two such notes is illegal — so the
separation must happen on every path *before* a colliding raw reaches mm.

`nudgeSamePitchOnsets(records)` is the one separator: walk a
`(raw, ppqL)`-sorted list and bump each colliding successor to
`prev.ppq + 1` (cascading; `fixed` externals frozen). Pure geometry on
`evt.ppq`; it returns the moved records so each caller stages its own mm
write. Three sites call it:

- **reseat** (`rebuildInternals`) — a reswing recomputes raw from
  logical, so two distinct-`ppqL` notes can land on one raw. Separate
  before the reseat commit, else reload-dedup eats a voice.
- **pre-clip scan** (`flush`) — an edit moves a note onto a same-pitch
  peer. Separate before the flush commit.
- **tail walk** (`rebuildTails`) — real notes and predicted fxNotes walk
  together; separate before the atomic note commit, then clip tails.

**Kill, not nudge, for genuine duplicates.** The pre-clip scan still
dedups when the two are the *same* voice: a regenerable fxNote loses to
an authored note, or two notes sharing `ppqL` *and* `detune` collapse to
the longer. Distinct `ppqL` or distinct `detune` ⇒ distinct voices ⇒
nudge.

**Commit ordering.** mm tokens are keyed by realised ppq, so an occupying
move (an edit landing on a peer's slot) re-keys onto that peer's token
before the peer's own nudge applies — the peer's staged write then
resolves to the wrong note. The flush applies note moves by **descending
target ppq** so every vacate lands ahead of its occupy. The reseat path
is immune: reswing moves both notes to fresh raws, away from each other's
tokens.

## Pre-clip collision scan

Run inside `mm:modify`'s preflush, after `preflush` (propagated peers
already staged) and before the snapshot (separations/deletes ride this
flush). Scans ALL post-flush notes — `byToken` all lanes plus staged
adds — grouped by `(chan, pitch)` in one pass.

Not a per-self peer walk: two notes can collide without either being the
edited one, and repeated per-self truncation damages peers a later
same-flush op would resolve.

Each group is sorted `(raw, ppqL)` and walked: genuine duplicates killed,
distinct voices nudged apart, survivors' tails clipped to the next onset
(§ Same-pitch onset separation). This is the staging pre-clip only; the
authoritative raw tail is re-derived by rebuild step 4.8. `endppqL`
(intent) is never written here — deleting a blocker lets the raw tail
regrow to it.

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
projection strips fields a verbatim replica needs (cc number, pb derived
marker, user metadata). Since `oldPpq` sits on a swing-period boundary
(take length aligns to QN), shifting by `k·oldPpq` is identical in
logical and realised frames — one delta serves both `ppq` and `ppqL`
paths.

## Rebuild: partition

Internal events are stamped (`ppqL ~= nil`) AND have raw ppq consistent
with `fromLogical(ppqL, delay)`. The main rebuild flows them branchlessly.
External events are foreign-MIDI (no `ppqL`) or externally-edited stamped
records (Ctrl-Z, foreign script made raw diverge from `fromLogical`).
They re-enter at the externals step: notes get a fresh lane pack and
`ppqL`/`endppqL` stamp; CCs get `ppqL` stamped in-line in the CC walk.

**Exception for `realiseNoteUpdate`'s floor:** when authored delay pushes
the realised onset negative, raw is clamped to 0 while `ppqL`/`delay`
retain the intent. This divergence is intentional and surfaces as
`delayC` (tp paints `*`). Recognise the clamp shape
(`raw == 0 AND fromLogical(ppqL, delay) < 0`) and stay internal.

## Rebuild: CC walk

Reconciles each non-derived CC's `(raw, ppqL)` under the current swing, then
projects non-pb CCs into columns:

- `staleSwing[chan]`: ppqL is truth; reseat `raw = fromLogical(ppqL)`.
- Otherwise, if raw diverges from ppqL: external raw edit; restamp
  `ppqL = toLogical(raw)`.

Reconcile updates are mutated into the live cc record so the subsequent
column-event clone sees up-to-date values; `mm:assign` propagates them at
the end of the walk.

Derived events are handled separately: absorber pbs by the absorber pass
(against the post-walk lane-1 layout); synthesised PCs by PC synthesis.
Pb column projection is deferred to the absorber pass so it sees the
final reconciled absorbers and recomputed raw vals.

## Rebuild: externals

Reintroduced up front (after the stale-swing reseat, before the window pass),
so externals bound fx windows and walk alongside everything else. Per
external in raw-ppq order: pack a lane against the placed internals plus
any earlier externals (`noteColumnAccepts` sees raw tails; the walk clips
later); stamp `ppqL`/`endppqL` from raw; backfill missing metadata
(foreign-MIDI lacks all; stale-stamped notes arrive with authored
detune/delay intact). Column event inserted in lockstep so each subsequent
external's pack sees prior ones. Tagged `evt.fixed = true`: the tail walk
freezes its onset (the same-pitch clamp skips it) but clips its tail like
any other note, and it blocks neighbours' tails as a 'next' lookup.

## Rebuild: tail walk

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
tie-break): the successor is nudged to `prev.ppq + 1`
(`nudgeSamePitchOnsets`; § Same-pitch onset separation). Authored swap
survives: when raw order differs from logical order, whoever lands first
in raw becomes the realised predecessor.

Fixed records (externals, tagged `evt.fixed` by the externals step) keep their frozen
onset — the same-pitch clamp skips them — but their tails clip like any
other note, and their onsets appear as 'next' lookups so neighbours clip
against them. The predicted fxNotes (`fxLive`) walk here too; a record
with no token (a new fxNote) carries its clipped geometry into its
`mm:add` rather than a tail assign, and the clips commit with the fxNote
del/add in one modify.

## Rebuild: logical projection

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
