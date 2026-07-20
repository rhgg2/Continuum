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
local cache (`byUuid`, per-channel `rawIndex`) and accumulate
mm-facing ops in `adds`/`assigns`/`deletes`. `tm:flush()` commits the
batch in one `mm:modify` call. The cache is maintained incrementally at
every mm-write site (the verbs, flush, and rebuild's `mmBatch`), so a full
`reload()` from `mm:events()` runs only when mm re-reads its whole event
set — module init and wholesale reloads (§ Incremental index reconciliation).

The sections below reference um by name because its frame and encoding
choices (cents not raw; realisation toward mm, logical at the public
surface) are the reason several conventions exist.

### Incremental index reconciliation

`idxReconcile(uuid)` rebuilds one event's `byUuid`/`rawIndex` entry from mm's
canonical clone (`mm:byUuid`), producing an entry byte-identical to what a
full `reload()` would build for it — both funnel through the shared
`makeEntry` helper. Callers reconcile every touched uuid after the whole
`mm:modify` batch commits, not op-by-op: reconciling mid-batch would be
vulnerable to reseat sequences whose intermediate states collide, where an
op-by-op replay could net a live event out of the index.

An entry refreshes in place only when its `ppq` is unchanged; otherwise it is
removed and reinserted. `rawIndex[chan].notes`/`.pbs` are ppq-sorted while
`rawIndexListFor` keys on evType/chan/lane alone, so refreshing in place across a
moved onset would leave those lists out of order — and `refreshEntry`'s pb
branch never copies `ppq`, so that entry would keep a stale onset for good.
This check was free until 2026-07-17: mm addressed by content token, a ppq move
re-keyed it, and the remove-and-reinsert path followed automatically. A uuid
survives the move, so the condition has to be stated.

The eviction used to need a guard (`byUuid[uuid] == prev`): a reswing re-keyed
every note's token, the batch's `pairs(touched)` walk visits handles in hash
order, and a uuid's new-token insert could land before its old-token eviction —
so evicting unconditionally deleted the just-inserted live entry. Addressing by
uuid there is one key per event and one table, and the guard went with the
re-key.

Because every mm write maintains the index, it is authoritative and survives
across rebuilds. A rebuild only full-`reload()`s when mm re-read its entire
event set from REAPER; ordinary edit rebuilds keep the live index and just
`clearStaging()`. mm signals which case it is: its `'reload'` payload carries
`wholesale=true` from `load`/`reload` (every event object is new, index stale)
and `wholesale=false` from `modify` (in-place, index still valid). tm captures
that bit at the top of `rebuild`, before the pipeline's own nested `mm:modify`
calls re-fire `'reload'` and would otherwise clear it. The incremental path
was validated against a full `reload()` by a perf-gated shadow-compare during
the migration; that scaffolding is removed now that parity is established.

Note entries also carry `colEvt` — the seat stamp. As the rebuild seats a
column cell (internals, externals, or a restored parked note once its
deferred add lands), it files the cell on the note's entry via
`stampColEvt`. The stamp is how raw consumers reach the pass's live cell
without a per-pass column scan, and it must outlive reconciliation:
`refreshEntry`'s sweep spares um's own decoration (`realised`, `colEvt`),
and the remove-and-reinsert path carries the stamp onto the fresh entry.
Re-seating overwrites it; a wholesale reload rebuilds entries bare, and the
same pass's seating restamps them (the head reload runs before any stage).

### Interval seeds

um's low-level verbs (`addLowlevel`/`assignLowlevel`/`deleteLowlevel`) each drop a *birth
snapshot* of the event they touched -- its uuid, verb, both-frame position, lane, pitch, and
authored span -- into a `seeds[chan]` list separate from `adds`/`assigns`/`deletes`. `flush` folds
the seeds into `dirtyChans` via `absorbReloadDirt`, deduped by uuid (first-wins keeps the birth
state); an unseeded payload chan (mm-internal writes -- dedup, collision backstop) folds whole.

A move is one seed, not two: its snapshot records the vacated (old) position, while the surviving
event's current position is recovered live from `byUuid`. Membership (`seedCovers`) keys on the
logical row -- the snapshot `ppqL`, plus a survivor's live `ppqL` recovered from `byUuid` -- so a
move dirties both rows, an add covers its onset row, and a delete (uuid gone from `byUuid`) covers
only the death row. Position goes stale as things move and uuid dangles as things die; each consumer
reads whichever the seed still answers. See design/interval-dirt.md § The model, inverted for the
shape and § Phase 4.75 for the seek walk the snapshot feeds.

### Interval materialisation

Materialisation consumes the absorbed seed set directly — there is no closure. `seedCovers` builds
the set of dirty logical rows from the seeds (snapshot `ppqL` ∪ each survivor's live `ppqL`);
`exciseNotes` (trackerManager.lua) drops every carried column event whose row a seed covers, and
`rebuildInternals` re-clones that row from mm: an add finds the new note, a delete finds nothing and
the event vanishes, a move seeded both rows and gets both. Membership keys on the row, not the full
seat, because same-pitch/PC shadowing is a same-`ppqL` cross-lane relation: a deleted shadower must
re-materialise the survivor sharing its row, and a seat key (ppqL + lane + pitch) would skip it. This
is the row-keyed successor to the old `intervals.intersects`, which keyed on `ppqL` endpoints for the
same reason.

Widening a seed to its neighbouring onsets buys nothing *here*. No stage reads a neighbour's
column event expecting a fresh clone — every raw consumer reads um's raw index, which holds every
mm note in the raw frame and resolves carried and freshly-cloned events alike, writing its
results back through the `colEvt` seat stamp. A carried event whose mm note did not change is
already correct. Closure belongs to the tail walk, computed against that same index — see
design/interval-dirt.md § Phase 4 and § Phase 4.5.

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
  only lane-1 notes feed the pb-realisation logic — `detuneAt` seeks
  `rawIndex[chan].notes` (which holds every lane) through a lane-1
  filter. Higher lanes' detune is dead data for realisation
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
  Every note seat projects at ingestion (the externals lane packer
  tests overlap against um's raw index, not the columns); cc-family
  columns flip as they build (`projectEvent`), and the tail walk
  re-stamps the notes it moves or clips. `tm:addEvent` /
  `tm:assignEvent` translate logical to raw (adding delay back) on
  writes to mm.

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

- **Lane / chan changes.** Both are accepted by `assignEvent`. A note's
  `lane` is persisted per note and taken verbatim by the next rebuild
  (`pickStampedLane`), so an in-place lane assign reseats the note's
  column without shedding its identity (the note index spans all lanes,
  so nothing migrates). A `chan` change is likewise accepted, migrating
  the index entry between channel lists; rebuild's absorber pass
  reconciles fakes across both channels.
- **Single voice per (chan, pitch) — realised space.** MIDI permits
  one voice per `(chan, pitch)`. tv writes authored logical verbatim;
  distinct voices that collide in realised raw (swing/delay-collapsed,
  or a same-row detune cluster) are separated by a +1 nudge — not
  dropped — so each keeps its own pb absorber (§ Same-pitch onset
  separation). The divergence surfaces as `endppq ≠ endppqC` in the
  projection and as `delayC` on the onset. Separation lives entirely on
  the realisation side: the authored ceiling on `endppq` stands. A caller
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

## Anticipative-FX guard

While playing, `mm`'s `flushTake` releases notes REAPER is actively sounding
through the per-event API *before* its wholesale `MIDI_SetAllEvts`, so an edit
to a live note doesn't strand the old note-off (see docs/midiManager.md §
Live-edit note release). That release tests against the `GetPlayPosition2`
scheduling frontier — but anticipative FX processing buffers a track's synth
*past* that frontier, reopening the stranding window. So tm turns anticipative
FX off on the bound track (`I_PERFFLAGS &2`) for the duration of editing.

The prior flags are captured and persisted (`ds` project key `guardedTrack =
{guid, flags}`) the moment a track is guarded, and restored on the next unbind:
`bindTake` restores the outgoing track before guarding the incoming one,
`detach` restores when the take dies, and Continuum's quit restores through the
`tracker` facade's `restorePerfFlags`. Because the prior is persisted, a crash
that skips the restore is healed on the next boot — tm's construction calls
`restoreGuarded` once before the first bind, putting any leaked track back and
clearing the record. Capturing the prior only when guarding a fresh track (the
restore always runs first) means the stored value is never a Continuum-modified
one, so it can't latch.

## Rebuild

Triggered by:
- mm `'reload'` signal — always rebuilds. Its `wholesale` payload bit says
  whether mm re-read its whole event set (`load`/`reload`) or mutated in
  place (`modify`); the former drives a full index reload (§ Incremental
  index reconciliation). The take-swap flag travels via the separate mm
  `'takeSwapped'` signal, captured into a transient flag and consumed by
  the next reload (mm guarantees the firing order);
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
- **CC walk** (`rebuildCCs`). Route markerless cc seats (a cc inside a
  prior cc window) out of columns for fresh reconciliation, reconcile each
  non-derived CC's `(raw, ppqL)` under the current swing (stale-swing CCs
  reseated here), then project `cc`/`at`/`pc` into columns. pb projection
  defers to the absorber pass, pa dispatch to its own step. → § Rebuild: CC walk.
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
  ccs a replace-region covers leave the take — and so does any note
  hosting its own discrete-replace kind (note-host replace parks the
  host; see `design/note-macros-v2.md` § Note-host replace parks). The
  prior parked set splits into still-covered carry-forward and restores
  that re-enter their columns unrealised, keeping their uuid and fx. A
  restored cc lands on the exact ppq of the fill seat the wider window
  left on the take; under uuid addressing the two are distinct events, so
  the fill reconcile deletes that seat by its own handle and the authored
  value stands. (While mm addressed by content token the two shared a
  `cc|chan|cc|ppq` key: the restore had to delete the seat itself and hide
  it from `fx.ccExisting`, or the reconcile deleted the authored event
  instead and the value drifted to the fill on every window round-trip.)
  Carried-forward tails clip against on-take note
  bounds the same way the tail walk clips real notes, so a parked tail
  stops at the first successor past its region, not just the next
  parked member. Lane bound only, never pitch: a parked cell never
  reaches mm, so it carries pure intent — the same extent
  `computeFxWindows` gives an on-take host. The note del/adds ride the
  tail walk's atomic commit. See `design/note-macros-v2.md` § Generator output. Each pass's
  `scan` builds its `spec` inline at the scan site, where that pass's
  `chan`/`lane`/`cc` are in scope; `reconcilePark`'s optional `onPark`
  callback fires only for specs newly parked this rebuild (e.g. marking
  the note pass's channel dirty), never for carried-forward priors.
  `covered()` — the same predicate `reconcilePark` applies — gates both
  scan loops before they clone a `parkSpec`, so a take with no fx
  windows builds an empty scan and pays nothing per event; it accepts a
  stash spec or a column event — both logical, so it keys `ppq` directly.
  A `pa` rides its host note, so it parks exactly when the host does:
  deleted from the take (silent — a stale PA against a fresh derived
  stream is meaningless; the generator owns any new realisation PAs),
  stashed in `fxParked` tagged `pa`, reconciled against the parked-note
  set rather than in its own window pass.
- **PA dispatch** (`rebuildPA`). Attach each `pa` to the note column
  whose voice it modulates. Runs after column layout so the view and fx
  expansion read PAs inline, and after externals so foreign-MIDI PAs find
  their host. A parked PA is gone from `mm`, so it is re-projected from
  `channels[chan].parkedPA` into its parked host's lane — visible
  off-take, riding the note column as an on-take PA would. Returns the
  per-chan touched set — the columns whose onset order it broke — so
  `computeFxWindows`' second sort gates on it instead of resorting every
  dirty chan.
- **Fx expansion** (`rebuildFx`). First the read-only **window** pass:
  walk each channel's same-lane successor map in the logical frame, so
  each fx host's window is its voice extent (the next same-lane onset's
  `ppq`, floored by the authored end). Then every producer runs —
  on-take fx notes (augment hosts), parked note hosts (window = the
  realised parked extent), and fx regions; the derived fxNotes reconcile
  against the partition's set (`reconcileFx`), and continuous streams seat
  offline — cc-augment sums per target into markerless cc seats, pb defers
  to the absorber pass. The note add/del is **deferred** to the tail walk's
  atomic commit; `fxLive` (the predicted set) feeds the tail walk and PC
  synthesis. See `design/note-macros-v2.md` § Offline continuous realisation.
- **Tail walk** (`rebuildTails`). Real notes, fixed externals, and the
  predicted fxNotes walk together: clamp same-pitch onset collisions
  (fixed onsets frozen), then clip each realised note-off against its
  same-lane and same-pitch successors. The clips commit WITH the fxNote
  del/add and parked restores in one `mm:modify`. → § Rebuild: tail walk.
- **Absorber reconciliation** (`rebuildPbs`). Reseat absorber pbs against
  the post-walk lane-1 layout, recompute their raw vals, and project the
  pb column. See `docs/tuning.md` § Absorber reconciliation.
- **PC synthesis** (`rebuildPCs`, trackerMode only). Re-derive each
  channel's PC stream from current note state. Runs after externals so a
  foreign-MIDI note inherits its sample from the prevailing PC.
  → § PC synthesis under trackerMode.
- There is no tail projection pass: every note seat projects as it
  lands (interval seats splice into the carried lane; wholesale lanes
  append and order once at build end), cc-family columns flip as they
  build (`projectEvent`), and the tail walk re-stamps the
  `delayC`/`endppqC` render cues on the notes it moves or clips.
  → § Rebuild: logical projection.

All projection runs through `projectCC(cc, overlay)`: it clones the
source event, strips only `chan` and `cc`, and applies the caller's
`overlay` of derived fields. Everything else — including metadata not
known here — rides through verbatim, so new event fields reach
`col.events` without a change to this layer.

Then `clearStaging()` drops un-flushed ops. The index itself needs no tail
step: on a wholesale reload it was fully `reload()`ed at the pipeline head,
before any stage read it, and the pipeline's own commits maintained it from
there; edit rebuilds kept the live index throughout (§ Incremental index
reconciliation). tm fires the `'rebuild'` signal carrying the `takeChanged`
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

### Span-covered fx scans

`coverInto(list, spans, admit, emit)` builds the span cover of a ppq-sorted list: the governing
entry at-or-before each span's start (so `evalCurve`/`sliceCurve` reads within the span see the
right precursor), every entry through the span, then the closing entry past its end. `admit`
filters entries out of governance and emission alike — a skipped entry never governs; spans dedup
across a call by resuming from the last consumed index rather than rescanning from 1.

`eachWindowNote(chan, startL, endL, fn)` covers rather than scans a lane's onsets: it seeks the
governing onset at-or-before `startL` (its sounding tail may reach into the window) and walks
forward through one closing onset past `endL`. Membership is still overlap, not storage —
authored notes are re-queried each rebuild, one walk feeding both generator events and fixed lane
occupancy. See `design/note-macros-v2.md` § The anchor generalized.

`pbBaseFor(chan, spans)` / `ccBasesFor(chan, spans)` build the absolute authored base (ppq-keyed,
logical) covering only the caller's merged producer windows, not the whole channel: every read of
the base — `channelStreams`' slices, the cc fold, `rebuildPbs`' fold — is itself span-bounded, so
the cover is exact there and the scan is never O(channel). Parked events are authoritative at
their ppq (deduped against the cover); the maintained pb index is raw-sorted, and since pbs carry
no delay and swing is monotone, the raw-frame cover equals the logical-frame cover — spans convert
via `tm:fromLogical` before the walk. "Authored" means the cents sidecar is present (seats and
foreign pbs carry none).

`nextSameLaneNote(host)` looks up the strict next same-lane note by seeking directly in the host's
lane column instead of building a per-channel map up front. A parked host is not the column's own
cell (it was pulled out of it), so it has no successor in the column — the seat check (walking
back from the found insertion point to confirm the note itself is still present there) preserves
that.

`rebuildRegionPark`'s note/cc scans are span-covered the same way: `coverOnsets` walks each
channel's window extents (merged per-channel for notes, per `(chan, cc)` for ccs) rather than the
whole column, since a covered event sits inside a current window by definition — the extents are
the complete cover set. Self-parking fx hosts are the one exception: `parkWindows` suppresses their
own note-arm window, so they carry none, and the note pass sources them separately from the
fx-host set (`hostWindows`), gated by `generators.parksNotes` and deduped against the
window-driven scan by event identity.

### Derivation dirt: the gated spine

Two axes of dirt drive rebuild. *Materialisation dirt* (the `wholesale`
bit) is object identity: on a wholesale reload every record is new, so
columns reproject and the um index fully reloads. *Derivation dirt* is a
per-channel set, `dirtyChans`, marked by edit verbs (via mm's `reload`
`chans` payload), swing (`markSwingStale`), any non-tv config change (all
16), fx-region and parking edits, and pipeline-internal movers (a tail-walk
nudge marks the captured set so the later pbs pass sees it). It is captured
and cleared at the rebuild head, consumed by the gated stages, and wiped at
the tail. The pipeline's own `ds:assign`s during a rebuild (persisting
`fxParked`/`fxParkedCC`/`extraColumns`) fire `dataChanged` re-entrantly; the
subscriber drops them while `rebuilding` — they are converged output, not
edits, and marking all 16 dirty mid-rebuild would defeat retention (a channel
clean in the CC walk but dirty in fx double-derives its seats).

A channel absent from `dirtyChans` **freezes**. Under frame retention (B1) the
freeze is total: rebuild carries the channel's whole prior `channels[i]` —
columns and all — forward, so materialisation itself skips (internals places
nothing, the CC walk clones nothing, `rebuildPA` and the pc-refresh reproject
nothing) alongside the derive/synthesise half of `ccs`, `fx`, `regionPark`,
`tails`, `pbs`, and `pcs`. Its derived notes/CCs/absorbers/PCs stand
untouched in mm and its carried columns are already logical, so tv sees a
complete frame at no cost. Sound by I8 (rebuild is a one-pass fixpoint, so a
channel with no dirty source re-derives nothing) and by blast radius: every
rule (tail clip/regrow, same-pitch cascades, absorber reseats, PC streams, fx
windows) is intra-channel, so a whole dirty channel over-approximates the
closure.

`fx` is the pivot: for a clean channel it skips its generators and leaves
`noteLive` empty — which is exactly why the downstream stages that read
`noteLive` (`tails`, `pbs`, `pcs`) skip it too. One gate, no cross-stage
dirt plumbing. `regionPark`'s `fxParked`/`fxParkedCC` need no seed:
`reconcilePark` *partitions the prior set* rather than rebuilding it, so a
clean channel's parked spec carries through untouched by construction — the
gate skips only the scan that hunts new parks. (`extraColumns` is grow-only,
so it is merge-safe too.)

`projectLogical` gates with the rest: a carried column is already projected,
and re-projecting it would corrupt `delayC` (recomputing `evt.ppq - baseline`
from an already-logical `ppq`). Only dirty channels, freshly materialised,
reach it.

Interval dirt (design/interval-dirt.md) narrows this freeze one producer at a time: a channel whose
only dirt is note-column edits still carries its CC/park/pb state forward like a clean channel would,
but hands `rebuildInternals` a live channel to excise and re-clone the closed note span into (§
Interval materialisation). Every other producer — `ccs`, `regionPark`, `pbs` — doesn't yet
distinguish interval dirt from wholesale dirt, so it still replaces the whole channel; folding them
in is the rest of phase 3.

### Dormant guard

When the tracker page is not active, `bindTake(nil)` clears cm's take context
while mm still holds the last take. The shared cm fires `configChanged` every
frame regardless of which page is active (e.g. samplePage's per-frame tick). A rebuild
fired in this state would resolve swing/trackerMode off empty take tiers, causing
a mm/cm mismatch. The `configChanged` subscriber therefore returns early if
`cm:boundTake()` is nil; the next real `bindTake` call fires a coherent rebuild.

That guard **drops** the change, which was harmless only while every rebind
marked all 16 channels dirty anyway. Under the converged-rebind gate
(midiManager.md § Converged load) a rebind may mark nothing, so what happened
while the tracker was away has to be recovered at the bind.

Replaying the missed signals is not enough, because the worst case fires no
signal at all: take-scoped ds/cm state (`swing`, `fxRegions`, `extraColumns`,
`fxParked`, the take config tier) is rewound by a REAPER undo while `ps` watches
only the *bound* take's slots — nothing is listening, and cm/ds simply refill
their caches from storage at the next `setContext`. The same blind spot swallows
the `trackerMode` re-seed, which `bindTake` writes under its own suppression
window.

So the bind compares rather than listens: `derivationInputs()` gathers everything
the pipeline derives from beyond the take itself, each rebuild stashes it as
`derivedInputs`, and `bindTake` diffs the two before `mm:load`. A difference
means the frame was derived under inputs that no longer hold, and
`markSwingStale(nil)` covers both halves of the answer — every channel dirty,
and the raw reseat that a swing change (unlike a config change) additionally
needs. A spurious diff costs one derivation; a missed one writes stale output,
which is why the diff is over values and not over a change counter that only
ticks when someone remembered to tick it.

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
(lane events for rebuild; `byUuid` notes + pending adds for flush) and
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

Ownership in um is a separate question from column binding, and um tests
it in the **logical** frame (`forEachAttachedPA`). A PA carries its own
`ppqL` and the CC walk reswings it from that seat, exactly as it does a
note — a PA is not slaved to its host's raw onset. So a host's
realisation moves independently of the PAs it owns: a forward delay
pushes a note's raw onset clean past a PA at its own logical seat, and
the tail walk's same-pitch nudge does the same for a tick. A raw-frame
test calls those PAs detached, and um then declines to move or cull them
with their host — orphaning them in `mm`.

`resizeNote` follows the same rule, and has to follow it twice: once to
decide whether a move is a translation, and again to perform the carry.

The translation test compares **logical lengths** (`L2 - L1 == endL -
startL`), not raw deltas at the two endpoints. Swing is a periodic warp,
so a whole-note logical move is a whole-note raw move only when the
note's length is an exact multiple of the swing period — only then do
both endpoints keep their phase and shift by the same amount. At any
other length they warp differently, and a raw-frame test reads the move
as a resize, culling every PA the new span excludes. That is also why the
function takes the logical span rather than the older `cullEnd`
parameter, which existed only to smuggle the logical `OPEN` sentinel into
a raw-frame test. In the logical frame `OPEN` is just `math.huge`, and
since `math.huge` minus either seat is `math.huge`, an open tail that
stays open satisfies the same equality with no special case.

The carry is logical for the same reason, and for a sharper one. It moves
the PA's seat by the host's logical shift and realises that seat through
`fromLogical`, rather than adding the host's raw delta to the PA's raw.
Under swing those two disagree — and a PA whose raw and seat disagree is
not merely imprecise. On a settled channel the CC walk reads the
divergence as an external raw edit and restamps `ppqL` from the raw
(`rebuildCCs`), so a fabricated realisation silently overwrites the very
intent the carry set out to preserve. Only a `staleSwing` channel gets
the reverse treatment, its seat reswung into raw; everywhere else, raw
wins the disagreement.

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
- **Handles and `realised`.** An event's `uuid` is its handle everywhere:
  durable across rebuilds and reloads, stable under any assign, and what
  `tm:byUuid` and every mm verb take. What um's records add is `realised` —
  set on entries built from an mm clone, absent on staged adds and on
  restored parked cells until their deferred `mm:add` lands. Presence, not
  the uuid, is what says "this event exists in mm, write through to it";
  a parked spec keeps its uuid the whole time it is off-take.

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
its own pb absorber, and the give-way surfaces as `delayC`. The verdict
policy — which collisions are duplicates to kill, which are distinct
voices to nudge — is `voicing`'s; see `docs/voicing.md`.

mm owns the `(ppq, chan, pitch)` invariant and enforces it itself: a
colliding write is repaired by the backstop at `modify`'s unwind, an
external collapse by intent-aware load-dedup (`docs/midiManager.md`
§ Mutation contract). tm's separation site is therefore not load-bearing
for take integrity — a missed collision is resolved by mm and surfaced
via `collisionsResolved` instead of silently eating a voice.

`voicing.separateOnset(e, prev)` is the separation *verdict*: given a
record and its settled same-pitch predecessor, it returns the raw onset
that gives way — `prev.ppq + 1` — or nil if the record stands (a `fixed`
external never gives way). Pure geometry on `evt.ppq`; the caller stages
its own mm write.

The traversal is deliberately not `voicing`'s. Which predecessor counts
as settled, and how far a cascade runs, depends on which notes the pass
has news for — and that is interval dirt, which only the caller knows
(§ Rebuild: tail walk). `voicing` owned the walk too until 2026-07-17,
when the tail walk went interval-native and the whole-channel traversal
it exported stopped being the one anybody wanted.

**One site separates**: the tail walk (`rebuildTails`), where real notes
and predicted fxNotes walk together — separate before the atomic note
commit, then clip tails.

The reseat (`rebuildInternals`) and the flush scan nudged too until
2026-07-17. Both went for one reason: a nudge they skip is not a lost
voice but a collision riding one stage further, to a site that separates
it before anything can read it. The reseat's notes reach the walk through
um's raw index, in the same pass and the same `mm:batch` nest, so mm's
backstop — which resolves at the *outermost* unwind — still finds
nothing. The flush scan's staged add reaches that same backstop at
flush's own unwind, ahead of the rebuild it triggers.

The walk and the backstop are **independently sufficient** for the reseat
case: disabling either still separates, and it takes disabling both to
land two voices on one raw (`tm_reseat_collision_spec`, which pins the
surviving voice and deliberately names no layer). The backstop is a real
second line here, not a formality — it is simply never reached, because
the walk gets there first.

What had made both necessary was token addressing: a transient collision
left two notes sharing a token, so a staged write could resolve to the
wrong one, and each stage had to clear its own collisions before
committing. Uuid addressing (2026-07-16) made a collision merely
transient rather than unnameable — and the two nudges became the pipeline
separating one collision three times.

**Commit ordering.** Notes are addressed by uuid, but `collisionIdx` is
keyed by realised ppq, so an occupying move (an edit landing on a peer's
seat) reaches that seat before the peer vacates it. The flush applies note
moves by **descending target ppq** so every vacate leads its occupy. The
reseat path is immune: reswing moves both notes to fresh raws, away from
each other's seats.

The sort stopped being load-bearing on 2026-07-17, when `assignNote` began
evicting only the slot it still owns: the occupier's clobber no longer
strands the peer, and either order now leaves the index correct. What
descending still buys is silence. An ascending commit records a transient
same-seat collision, and every pending key costs the backstop a full
`sparsePairs` walk of the note array at the unwind — measured at ~65µs on
glasswork, against a ~17.7ms flush. Defensive rather than load-bearing,
and too cheap to be worth removing.

## Flush collision scan

Run inside `mm:modify`'s preflush, after `preflush` (propagated peers
already staged) and before the snapshot (separations/deletes ride this
flush). Scans ALL post-flush notes — `byUuid` all lanes plus staged
adds — grouped by `(chan, pitch)` in one pass.

Not a per-self peer walk: two notes can collide without either being the
edited one, and repeated per-self truncation damages peers a later
same-flush op would resolve.

Each group runs `voicing.resolveGroup` for its **kill** verdicts alone
(see `docs/voicing.md`). Neither tails nor onsets are touched: the scan
clipped tails and nudged onsets until 2026-07-17, and both were the same
vestige, from the days when this scan *was* the truncation and separation
site. The walk's tail bound is strictly stronger — post-walk rather than
staged geometry — and a rebuild always follows a flush, so every tail the
loop wrote was overwritten moments later; the onsets it separated the
walk separates just as surely (§ Same-pitch onset separation).

The kills do not follow them out, and the asymmetry is precisely why:
the walk separates but never kills. A duplicate that reaches the
walk is separated rather than collapsed — and a separated pair is no
longer a collision, so mm's backstop finds nothing left to dedup either.
This scan is the only site in the stack that dedups a staged add against
a committed note, and killing through um's verbs is what carries the
semantics mm shouldn't own (PA culling, detune-aware resize). It went
uncovered once already; `tm_flush_collision_scan_spec` now pins it.
`endppqL` (intent) is never written here — deleting a blocker lets the
raw tail regrow to it.

## Length operations

### setLength(newPpq)

Shrink deletes events at-or-past the new end and clamps spanning notes;
grow touches no events. The subtlety is what "clamp" means for a note
whose `endppqL` is `util.OPEN` — the freshly-placed legato note with no
authored ceiling. Stamping a concrete `endppqL` on it is lossy: the
sentinel is *intent*, and a resize is not an edit of intent. Grow the
take back and a concreted note stays short forever.

So OPEN notes are left out of the clamp list, and the tail walk clips
their raw note-off instead — which it does anyway, `takeLen` being one of
its bounds. That inverts an ordering. `setLength` must clamp and flush
*before* `mm:setLength` moves the EOT, because `setEot` cannot place the
EOT behind a live note-off: the take will not shrink while a tail still
spans the boundary. But the rebuild inside that flush reads the take
length from mm, which is still long — so it would regrow the OPEN tail to
the *old* end and deadlock the shrink.

`pendingLen` is the seam. Held across the shrink flush, it makes
`tm:length()` report the new end, so every stage that bounds on take
length (tail clip, fx windows, parked realisation) sees the take tm is
about to create rather than the one it still has. All 16 channels are
marked dirty, because any of them may hold a spanning OPEN tail and a
clean channel's frame would otherwise carry forward unclipped — this is
also the explicit all-16 take-length dirty source that
`design/archive/dirty-channels.md` asked for.

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
so externals bound fx windows and walk alongside everything else. Overlap
testing is realised-time by design, but columns are logical by now — so the
packer's occupancy is um's raw index (the seated internals' entries, reseats
already committed) plus the probes it has placed this pass, whose staged lane
assignments reach the index only at the batch commit. Per external in raw-ppq
order: pack a lane (`laneAccepts` sees raw tails; the walk clips later); stamp
`ppqL`/`endppqL` from raw; backfill missing metadata (foreign-MIDI lacks all;
stale-stamped notes arrive with authored detune/delay intact); project and
splice the column clone. Tagged `evt.fixed = true`: the tail walk freezes its
onset (the same-pitch clamp skips it) but clips its tail like any other note,
and it blocks neighbours' tails as a 'next' lookup.

## Rebuild: tail walk

Two tail targets per internal note, and the split is the model — the lane
bound is intent, the raw bound is realisation:

```
laneBound = max(onset + 1, min(
  fromLogical(endppqL),                       -- authored ceiling; math.huge for util.OPEN
  fromLogical(nextSameLane.ppqL) + overlap,   -- same-lane next (INTENT)
  takeLen))

rawBound  = max(onset + 1, min(
  laneBound,
  nextSamePitch.ppq))                         -- same-pitch next (RAW)
```

The lane bound drives `endppqC`, and so the screen. The raw bound is the
only value that reaches mm.

Same-lane uses INTENT (`ppqL`) so authored music geometry wins over
realisation delays. Same-pitch uses RAW because MIDI physics is realised.
"Next" is strict-greater on raw ppq — a chord-mate at the same onset is
not following.

Why the split, and why it is not symmetric: a column is monophonic — a
note ends at the next onset in its own lane — and that would hold if MIDI
did not exist. It is intent, and two notes overlapping in one lane are
unrepresentable anyway, the column having nowhere to draw the second. One
voice per `(chan, pitch)` is a fact about MIDI, not about trackers, and
two notes overlapping at the same pitch *across* lanes are perfectly
drawable — the overlap is right there on screen, so the truncation is
inferable from what is displayed. The rule that decides the boundary:
clip what the view can't draw; don't clip what it can. Same-pitch is
therefore realisation, exactly like swing — true on the wire, absent from
the screen, and no cue, because a cue earns its place only where the cause
is invisible. See design/interval-dirt.md § Same-pitch is a projection
artefact.

Collision (current raw `<=` prev same-pitch raw, raw-order with ppqL
tie-break): the successor is nudged to `prev.ppq + 1`
(`voicing.separateOnset`; § Same-pitch onset separation). Authored swap
survives: when raw order differs from logical order, whoever lands first
in raw becomes the realised predecessor.

Parked members bound on-take tails' lanes too: a parked cell has already
left the columns, but its lane geometry still applies to a preceding
on-take tail sharing that lane. Parked is off-take, so it never bounds
the wire (pitch), and a region's own tiles never read parked bounds at
all — they'd already be cut by the members they replaced. Only on-take
notes read them.

Fixed records (externals, tagged `evt.fixed` by the externals step) keep their frozen
onset — the same-pitch clamp skips them — but their tails clip like any
other note, and their onsets appear as 'next' lookups so neighbours clip
against them. The predicted fxNotes (`fxLive`) walk here too; a record
with no token (a new fxNote) carries its clipped geometry into its
`mm:add` rather than a tail assign, and the clips commit with the fxNote
del/add in one modify.

### What the walk visits, and what it emits

The walk reads its whole channel but does work only where the pass has
news. `dirtyChans[chan]` arrives as seed dirt (§ Interval seeds), and
a note the dirt does not name kept its raw and its ceiling — last pass
left it separated and clipped against neighbours that also stood still.
`disturbed` is that judgement and it is the whole of the walk: a note is
disturbed if a seed names it, if it is derived, or if a nudge moved it. A
seed names by uuid where it still answers one — a survivor, recovered
live from `byUuid` — and by logical seat otherwise: an add, whose uuid
lands only at commit, and a delete, whose uuid is already gone. Derived
notes seed unconditionally because `rebuildFx` regenerates `noteLive`
wholesale, so a tile's raw is this pass's news whatever the dirt says —
`design/interval-dirt.md` § phase 5 narrows that.

Separation narrows on the same judgement. Only a disturbed note can
collide, and only onto its same-pitch predecessor — so a nudge marks its
own note disturbed and the cascade carries forward under its own power.
That is what keeps the walk from fencing a chain: the walk never has to
know in advance how far a cascade will run.

The set of notes to re-bound is seed-driven, not span-tested. A note is
bound if it is disturbed, or if it is the nearest same-lane or same-pitch
strict predecessor of an *anchor* — a seed position (dead seeds included)
or a disturbed onset, found by one `util.seek 'before'` probe per axis.
Probing the predecessor subsumes the old authored-span stale-test: a
shield standing between a seed and an open note behind it is itself that
seed's nearest same-lane predecessor and holds the clip, and a deleted
neighbour that can no longer be asked for its onset is reached because its
death position is a seed and the note it bounded is that seed's
predecessor. See design/interval-dirt.md § Span-staleness.

Successors come from one backward pass carrying, per lane and per pitch,
the note last seen and that note's strict next — a neighbour sharing the
current note's raw is no successor of it, so it hands over its own. That
replaced the `strictNextMap` bucket-and-map build the walk used until
2026-07-17, and the separate parked-bound bucket with it: parked cells
are few enough to scan, and only for the notes the sweep bounds.

The walk **emits**. A nudged lane-1 onset moved every absorber seat
between it and the next lane-1 onset, so the walk seeds that interval
into `dirtyChans[chan]` and `rebuildPbs` consumes it later in the same
pass. This replaced a `dirtyChan(chan)` widen carrying the same fact on
the same trigger: being the coarse mechanism it would have written `true`
over the very set the emission builds. See `design/interval-dirt.md`
§ The widen and the emission are the same fact.

Two walks share these rules; a seed-count threshold picks between them.
The **linear walk** is authoritative for dense and wholesale dirt: one
forward onset pass, one predecessor probe per axis to build the bound
set, one backward pass to clip and emit — over the whole channel. It is
the degenerate fallback (§ Phase 4.75, § The degenerate case gates on
seed count). The **frontier probe walk** takes the common sparse-seed
channel: it seeks to each seed by name and probes a bounded few rows for
its lane and pitch neighbours, with no whole-channel traversal and no
`mergeIndexed` — the sorted index and the small extras list stay separate
probe sources. Both drove identical results under a scratch-copy shadow-
compare (gated on `_G.CONTINUUM_SHADOW_FRONTIER`) until the frontier went
live 2026-07-18; that shadow, the earlier span-based sweep it replaced,
and `intervals.lua` are all retired now. See `design/interval-dirt.md`
§ Phase 4.75 and § Retirement of intervals.

## Rebuild: logical projection

Projection is build-time: every note seat projects at ingestion (the
frame law — a lane is never part-raw, part-logical; interval seats
splice into the carried lane, wholesale lanes append and order once at
build end); cc-family columns flip as they build (`projectEvent`);
and the tail walk re-stamps `delayC`/`endppqC` on the notes it moves
or clips — there is no note flip pass and no end-of-pipeline pass.
The raw frame the externals packer needs lives in um's index, not the
columns. The frame contract is unchanged:

tv surface is logical-only: both onset and tail leave here in the
authoring frame; raw stays private to tm/mm. `evt.ppq` and `evt.endppq`
are floats — the logical frame is float by design, and the on-grid
predicate (`ctx:isOnGrid`) is the sole owner of row-membership tolerance.
Rounding here would silently widen that tolerance to 1 ppq.

Projection assumes every event it sees is sidecar-stamped, and the CC
walk guarantees it: `rawDivergesFromLogical` counts a missing `ppqL` as
divergence, so foreign MIDI is anchored (`ppqL = toLogical(raw)`) on the
first rebuild that dirties its channel. Notes get the same guarantee from
the externals pass. That stamp — not A2's now-retired duplicate — is what
makes "columns are logical" true; gate it and sidecar-less events reach
columns in the raw frame, where `rescaleLength` would warp them through
swing twice. See § Swing for why the anchor is not optional.

`evt.endppq` is the AUTHORED logical ceiling (mm's `endppqL` stamp, or
`util.OPEN` for a deliberately-unbounded tail). `evt.endppqC` is the
LANE-clipped logical ceiling — render-only, plus the sounding extent a
parked cell hands a generator. It is not the inversion of mm's raw
`endppq`: the walk clips the wire further at the next same-pitch onset,
and that clip never shows (§ Rebuild: tail walk). An uncached note (no
`endppqL` stamp in mm) has no authored ceiling, so it falls back to
`endppqC` — the lane bound, not the realised one.

Every seat projects exactly once, at ingestion; carried events were projected by the pass that
seated them, and nothing walks a column to re-project — a second projection would corrupt `delayC`.
