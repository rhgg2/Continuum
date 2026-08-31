# trackerManager

Parses a midiManager's MIDI stream into tracker-style channels with typed
columns, resolves tuning and timing (swing + per-note delay), and
exposes a batched mutation interface that writes back to mm. Rebuilds
automatically whenever mm or cm fires.

## Channel & column model

16 channels, numbered 1..16 as in mm, one per MIDI channel. Each channel
carries a `columns` table:

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

An fx region stored at channel 0 names no MIDI channel of its own: it is authored on
a view surface meant for every channel at once (`docs/trackerView.md` § Addressing a
chain). The rebuild expands it, at the head snapshot of document keys its passes read,
into one ordinary region per channel in use, carrying its span and its chain, each
identified by the stored uuid qualified by the channel it lands on. That qualified uuid
is opaque and never split back apart: the window store and the park stash carry it, so
seat recognition matches on it unchanged (`docs/generators.md` § Route-by-window). Every
pass below the snapshot therefore sees per-channel producers only.

A channel is in use when it carries an authored note, when the park stash holds a note
taken out of it, or when it has a pb or cc lane of its own. Derived output is no
evidence of use: a chain emits its curve with or without material, so a channel counted
in on the strength of a chain's own output would stay in the set for good.

Expansion appends those producers after all the stored channel regions, so a channel's
own chains take precedence over a global one on it; among globals it is their storage
order, which the master strip shows as their column order. The stored region holds the
intent, so editing it seeds derivation dirt on all sixteen channels at once — wider than
the set in use, so a channel that has just left it gets a pass to clear what the chain
left there.

Explode persists the expansion. The stored channel-0 region gives way to the per-channel
producers themselves, each kept under the uuid it was expanded with, and each taking the
expansion's own place in storage order — after the channel regions, before any global
still stored. The passes below the snapshot therefore read the producer list they read
before, so nothing re-derives and no channel is dirtied; the one rebuild is for the maps
keyed by the stored region, whose union entry goes with it. A chain reaching no channel
refuses to explode, since the expansion is empty and the chain would be lost.

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

One kind of column is opened from elsewhere: a cc lane driving an fx param.
That binding is the *track's* (`paramAutomation`, ds track scope), so its
column is derived at rebuild from the track's bindings and appears in every
take on the track — `extraColumns` never records it. See
`docs/trackerView.md` § Extra columns & delay sub-column.

```
extraColumns[chan] = {
  notes = <count>,
  pc = true, pb = true, at = true,
  ccs = { [ccNum] = true },
}
```

## Update manager (um)

Two `do ... end` blocks folded into tm's own scope, not separate objects:
the source banners them `-- RAW INDEX` and `-- STAGER`. The index owns
`rawIndex`/`byUuid`/`fxHosts` and the upkeep that keeps them true, and
hangs its doors on one `index` table; the stager accumulates mm-facing
ops and commits them, hanging its own on `stager`. The arrow runs one way — staging reaches the index
through its doors (`index.add`, `index.delete`, `index.move`,
`index.sync`, `index.forget`, `index.load`) and never the reverse — so the type→list mapping
(`rawIndexListFor`) stays inside the index.

Maintenance through those doors is identity-based: `index.delete` finds its
entry by object identity, so a caller hands the verbs mm's canonical record and
never a projection of one. A projected column cell carries the same uuid and is
a different table, so removing one strands the raw entry — invisible to a
uuid-holed read of mm, and exposed the moment a splice reads the index.
`deleteLowlevel` resolves through `byUuid` before removing, for that reason.

The index is the primary structure and the stager is one of its clients.
`rawIndex[chan]` holds every event on the channel, one
`index.order`-sorted list per type; the whole rebuild pipeline reads it
in place, ~40 sites of it, against ~10 callers for the write verbs — nearly
all of those tm's own forwarders. The index lives inside um because um is
what keeps it true. `index.raw(chan)` is the single read door, covering
all six lists.

An event's `uuid` is its handle everywhere: durable across rebuilds and
reloads, stable under any assign, and what `tm:byUuid` and every mm verb
take. What um's records add is `realised` — set on entries built from an mm
clone, absent on staged adds and on restored parked cells until the park
stage's `mm:add` lands. Presence, and not the uuid, is what says "this event
exists in mm, write through to it"; a parked spec keeps its uuid the whole
time it is off-take.

`index.order` is a total order: raw tick, then logical seat, then authored
before generated, then lane, then pitch. The tail carries weight. Records can
share a tick and a pitch — a nudge lands a derived note on an authored one —
and `(ppq, ppqL)` alone leaves them in Lua's unstable sort order, which is
exactly the order the frontier walk reconstructs settlement from (§ What the
walk visits, and what it emits). The tail's one preference is meaningful:
authored settles before generated.

Staging proper: all mutations — from tv and from tm's own rebuild-time
housekeeping — funnel through `tm:addEvent` / `tm:assignEvent` /
`tm:deleteEvent`, which apply to the index and accumulate mm-facing ops in
`adds`/`assigns`/`deletes`. `tm:flush()` commits the batch in one
`mm:modify` call and drives the follow-on rebuild; the stager's own
`stager.flush` only reports whether the caller still owes one, because a
stager that calls `tm:rebuild` is the layering inversion in miniature. The
index is maintained at every mm-write site (the verbs, flush, and rebuild's
`mmBatch`), so a full `index.load()` from `mm:events()` runs only when mm
re-reads its whole event set — module init and wholesale reloads
(§ Incremental index reconciliation).

Derivation that happens to run at flush time is not staging, and sits
outside both blocks: `collisionKills` (§ Flush collision scan) is at file
scope, called by `stager.flush` before the commit because tm's kill verdicts have
to land before mm ever sees a same-pitch collision.

The sections below reference um by name because its frame and encoding
choices — cents inside and raw at the boundary, realisation toward mm and
logical at the public surface — shape the rules they state.

### The entry mutation contract

Index entries are live shared records — the rebuild reads them in place
rather than copying, which is why the index is two blocks in tm rather than
a module with a published interface. Three stages write to an entry, and
that is the whole set:

- `settleOnset` writes `ppq` — the +1 same-pitch nudge.
- `boundNote` writes `endppq` — the clipped tail.
- `stampSamples` writes `sample` — the prevailing PC's sample.

Three further writes sit outside the contract: `rebuildPbs` clones at the
boundary, `rebuildInternals` writes mm's own column clones, and
`colEvt`/`realised` are um's own decoration, set through `index.stampColEvt` and
the entry lifecycle.

All three go through `index.assign(entry, field, value)`, the entry-side twin of
`setCell` for column cells (§ Note-lane renewal): skip the no-op, and
where the field is one of `index.order`'s keys, re-true the containing
list — inline, or flagged for the open `index.withDeferredSort` block to sort
once at its close. Only `ppq` of the three actually stains a sort key, but
the door is the same for all of them so the rule lives in one place instead
of at the call site.

`anyNudge` gates the walk's own scratch lists. `linearTails`'s merged
`notes` and `frontierTails`'s `extras` share um's records but are the walk's
own tables, so nothing can flag them, and an ungated repair would put an
unconditional whole-channel sort on the dense path every pass.

The contract is declared and checked, not enforced at runtime: a metatable
proxy would miss the write that matters, since `__newindex` does not fire
for a key that already exists. `tm_raw_index_order_spec` is the backstop. It
stains the index with a real nudge and catches a binary-seek reader
answering from the stale order, and it pins every entry's `ppq` against
mm's. The order half is checked through a consumer, since asserting on the
lists themselves would publish a read accessor whose only caller is a spec.
So a new stage writing `entry.ppq` directly is a live bug, visible only
where a reader downstream reads the stale order.

### Incremental index reconciliation

`index.sync(uuid)` rebuilds one event's `byUuid`/`rawIndex` entry from mm's
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
branch never copies `ppq`, so that entry would keep a stale onset. A uuid
survives the move, so the condition has to be stated explicitly.

Reseating is a splice. The list an entry moves within is ordered everywhere
except at that one entry, so `index.add` binary-searches its seat
(`util.insertSorted`) and `assignLowlevel` reseats a moved entry by removing
and reinserting it — the same path a channel migration takes. Re-sorting the
whole list is O(n log n) Lua comparator calls to place a single event: ~8ms per
added note on a dense single-channel take (8.4k notes all on channel 1),
against ~0.2ms for the identity scan and shift it replaces. Bulk paths keep the
sort: `index.withDeferredSort` appends and sorts each touched list once at the end,
since N splices into one list beat N sorts only for small N.

`tm_raw_index_order_spec` pins both mechanics against the bulk-built index: the
tail walk reads these lists in order to find each note's same-pitch successor,
so a misplaced entry surfaces as a mis-clipped tail rather than as anything
visibly index-shaped.

Because every mm write maintains the index, it is authoritative and survives
across rebuilds. A rebuild calls `stager.reload` — drop staging, re-read the
index whole — only under materialisation dirt (§ Derivation dirt: the gated
spine), where every event object is new; ordinary edit rebuilds keep the live
index and just `stager.clear()`. tm
captures the `wholesale` bit at the top of `rebuild`, before the pipeline's
own nested `mm:modify` calls re-fire `'reload'` and would otherwise clear it.

Note entries also carry `colEvt` — the seat stamp. As the rebuild seats a
column cell (internals, externals, or a restored parked note as the park
stage's own commit lands it), it files the cell on the note's entry via
`index.stampColEvt`. The stamp is how raw consumers reach the pass's live cell
without a per-pass column scan, and it must outlive reconciliation:
`refreshEntry`'s sweep spares um's own decoration (`realised`, `colEvt`),
and the remove-and-reinsert path carries the stamp onto the fresh entry.
Re-seating overwrites it; a wholesale reload rebuilds entries bare, and the
same pass's seating restamps them (the head reload runs before any stage).
A restored park cell's stamp is likewise a bare write rather than a `setCell`:
`realised` is bookkeeping no renderer reads, and the restore already renewed
its lane when it re-entered the column.

### Interval seeds

um's low-level verbs (`addLowlevel`/`assignLowlevel`/`deleteLowlevel`) each drop a *birth
snapshot* of the event they touched -- its uuid, verb, both-frame position, lane, pitch, and
authored span -- into a `seeds[chan]` list separate from `adds`/`assigns`/`deletes`.
`stager.flushDirt` folds the seeds into the dirt journal, deduped by uuid (first-wins keeps the
birth state); an unseeded payload chan (mm-internal writes -- dedup, collision backstop) folds whole.

A move is one seed, not two: its snapshot records the vacated (old) position, while the surviving
event's current position is recovered live from `byUuid`. Membership (`seedCovers`) keys on the
logical row -- the snapshot `ppqL`, plus a survivor's live `ppqL` recovered from `byUuid` -- so a
move dirties both rows, an add covers its onset row, and a delete (uuid gone from `byUuid`) covers
only the death row. Position goes stale as things move and uuid dangles as things die; each consumer
reads whichever the seed still answers; the seek walk the snapshot feeds is § What the walk
visits, and what it emits.

A chan reassign counts as a move too: the vacated slot lands in the *old* channel's dirt, which no
other seed for this pass would otherwise reach, so `assignLowlevel` snapshots it exactly like an
onset shift.

### Interval materialisation

Materialisation consumes the absorbed seed set directly — there is no closure. `seedCovers` builds
the set of dirty logical rows from the seeds (snapshot `ppqL` ∪ each survivor's live `ppqL`);
`exciseNotes` (trackerManager.lua) drops every carried column event whose row a seed covers, and
`rebuildInternals` re-clones that row from mm: an add finds the new note, a delete finds nothing and
the event vanishes, a move seeded both rows and gets both. Membership keys on the row, not the full
seat, because same-pitch/PC shadowing is a same-`ppqL` cross-lane relation: a deleted shadower must
re-materialise the survivor sharing its row, and a seat key (ppqL + lane + pitch) would skip it.

A seed covers its own rows and no more. Every raw consumer reads um's raw index, which holds every
mm note in the raw frame and resolves carried and freshly-cloned events alike, writing its results
back through the `colEvt` seat stamp — so a carried event whose mm note did not change is already
correct. Closure belongs to the tail walk, computed against that same index (§ What the walk
visits, and what it emits).

The cc family splices seed by seed rather than row by row (`spliceChannelCCs`):
each cc/at/pc seed excises the cell it carries — an exact-row seek matched on
uuid — and re-clones its survivor from `mm:byUuid`, so neither O(channel) pass
remains. A fresh add has no uuid when its seed is born, mm stamping one at
commit, so the seed holds the snapshotted record itself and reads the uuid off
it late. Resolution goes through `byUuid` rather than a positional query
because the rebuild runs inside `mm:modify` before the reindex, where a binary
search cannot see a fresh add or a move.

## Pitchbend: tm's role in the tuning model

See `docs/tuning.md` for the cross-cutting model — the ladder from a
note's intent cents through detune to pb, the absorber invariant, and
the orthogonality rule. tm is where the model is implemented. The
tm-specific facts:

- **A window change rescales the wire.** `pbRange` is derivation
  config, so changing it dirties every channel. Each authored pb
  re-converts from its `cents` sidecar under the new window: the raw
  moves and the intent stands. A foreign pb arrives with no sidecar,
  but the first rebuild after it lands back-derives one and persists
  it, so from then on it rescales like any other.
- **Lane-1 drives detune.** Every note has a `detune` field, but
  only lane-1 notes feed the pb-realisation logic — `index.detuneAt` seeks
  `rawIndex[chan].notes` (which holds every lane) through a lane-1
  filter, and the absorber pass reads only lane-1 onsets, so higher-lane
  detune never reaches the pb stream (I3). It survives as dead data for
  realisation, readable by display layers and any future lane-promotion
  path. The seek lands at-or-before
  `P` by binary search, then walks back to the nearest lane-1 note,
  because `tm:fxCurveAt` calls it once per row per frame and
  `util.seek`'s head-of-list scan would cost `O(rows × channel notes)`.
- **Absorber persistence.** `pb.derived == 'absorber'` is the sole
  absorber marker, carried as pb metadata via mm's lazy-sidecar path.
  Absorbers are hidden from the pb
  column unless an interp shape pulls them into view
  (`hidden = pb.derived and (shape==nil or shape=='step')`); the host
  note for delay inheritance is the lane-1 note at the absorber's seat
  (`pb.ppq`), recovered geometrically — the host carries no marker.
- **Upkeep is wholesale.** The absorber pass reseats the whole absorber
  set against the final post-walk lane-1 layout, toggling no marker per
  edit. So the mutation entry points (`addNote`, `assignNote`,
  `resizeNote`, `deleteNote`) write detune as plain metadata and let the
  next rebuild realise it.

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
  writes to mm, through `timing.delayToPPQ`, the sole delay converter.

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
and `tm:toLogical(chan, ppq)`, cached per `(cm, mm)` in a file-local
`swing` snapshot and cleared at the head of each rebuild (`clearSwing`). `tm:markSwingStale`
flags channels whose resolved swing changed so the next rebuild
rederives their raw ppqs from `ppqL`.

## Mutation contract

This is the *edit* contract — how a caller gets a change into tm. The
separate contract governing in-place writes to a live index entry is
§ The entry mutation contract.

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
  (`rebuildInternals` seats each note at its own `note.lane`), so an
  in-place lane assign reseats the note's
  column without shedding its identity (the note index spans all lanes,
  so nothing migrates). A `chan` change is likewise accepted, migrating
  the index entry between channel lists; rebuild's absorber pass
  reconciles fakes across both channels.
- **Field deletion.** `util.REMOVE` as a value in `assignEvent` deletes the
  field, passed through to mm.
- **Single voice per (chan, pitch) — realised space.** MIDI permits
  one voice per `(chan, pitch)`. tv writes authored logical verbatim;
  distinct voices that collide in realised raw (swing/delay-collapsed,
  or a same-row detune cluster) are separated by a +1 nudge — not
  dropped — so each keeps its own pb absorber (§ Same-pitch onset
  separation). The divergence surfaces in the projection's render cues
  (§ Logical projection). Separation lives entirely on
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
- **Pb edits stage only the pb.** Adding or deleting a real pb touches no
  absorber; the set is reconciled wholesale by rebuild's absorber pass
  (§ Pitchbend: tm's role in the tuning model).
- **Parked edits stage.** `ds:assign` fires `dataChanged` → `tm:rebuild`
  synchronously, and a rebuild reloads the um cache — so a parked edit
  writing `ds` mid-loop during a multi-select (a transpose spanning a parked
  chord and normal notes) would rebuild and discard the still-staged mm
  edits. Parked edits therefore ride `flush` like every other staged edit,
  through a `parkedEdits` buffer peer to `adds`/`assigns`/`deletes`. Flush applies them to a cloned stash under a guard suppressing
  the inline rebuild, then either rides the mm reload's rebuild or drives one
  explicit rebuild where the edit was parked-only.
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

**A rebuild is one gated pass.** Each stage reads what the previous one left
in `channels`, and they share one `fx` accumulator and one deferred mmBatch.
Which stages run, and on which channels, is decided by dirt.

Triggered by:
- mm `'reload'` signal, carrying the `wholesale` bit that says which axis of
  dirt it brings (§ Derivation dirt: the gated spine). The take-swap flag
  travels via the separate mm
  `'takeSwapped'` signal, captured into a transient flag and consumed by
  the next reload (mm guarantees the firing order);
- cm `'configChanged'` signal, except for `tvOnlyKeys` — `defaultSwing` and
  `fxPatches` — which tv consumes without a structural rebuild. Neither feeds
  a derivation: a patch catalogue is a vocabulary of chains to instantiate
  from, and no realisation reads it;
- ds `'dataChanged'` on the project data tm derives from: `swing`,
  `fxRegions`, `fxParked`, `extraColumns`, `paramAutomation` and `noteDelay`.

tm also forwards the reconciliation signals it receives from mm
(`takeSwapped`, `notesDeduped`, `uuidsReassigned`) to its own subscribers,
so layers above tm needn't reach into mm.

Reentrancy-guarded by `rebuilding`. Also guarded against a dead take: if
`mm:take()` is nil (take deleted under us) `rebuild` returns immediately,
retaining tv's last rendered frame. This is the same liveTake guard every
other mm consumer applies — a foreign-track `configChanged` can fire during
arrange's take-delete sequence, against a take that no longer resolves.

A third gate makes an idle trigger free. `rebuild(∅)` — no dirt, no stale
swing, no wholesale re-read, no take swap, no `requestRebuild` — returns
before the channel carry, because every stage would converge on the frame
already held. So a trigger is not a rebuild: mm's converged rebind fires
`reload{wholesale=false, chans={}}` precisely so that dirt marked while tm
was dormant gets consumed, and when there is none this gate stops the pass.

### Derivation dirt: the gated spine

Two axes of dirt drive rebuild. *Materialisation dirt* is object identity,
carried by mm's `'reload'` payload as `wholesale`: true from `load`/`reload`,
where every record is new, so columns reproject and the um index fully
reloads (§ Incremental index reconciliation); false from `modify`, where mm
mutated in place and both stand. *Derivation dirt* is a
per-channel journal, `dirt.lua`, marked by edit verbs (via mm's `reload`
`chans` payload), swing (`markSwingStale`), any non-tv config change (all
16), fx-region and parking edits, and pipeline-internal movers (a tail-walk
nudge marks the captured set so the later pbs pass sees it). It is captured
and cleared at the rebuild head, consumed by the gated stages, and wiped at
the tail. The pipeline's own `ds:assign`s during a rebuild (persisting
`fxParked`/`fxParkedCC`/`extraColumns`) fire `dataChanged` re-entrantly; the
subscriber drops them while `rebuilding` — they are converged output, not
edits, and marking all 16 dirty mid-rebuild would defeat retention (a channel
clean in the CC walk but dirty in fx double-derives its seats).

A channel absent from the journal **freezes**. Under frame retention (B1) the
freeze is total: rebuild carries the channel's whole prior `frame.channels[i]` —
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

Projection gates by construction: columns are born logical — internals
projects at ingestion, splices carry only logical events — so a carried
column is logical by invariant, and the re-projection that would corrupt
`delayC` (recomputing `evt.ppq - baseline` from an already-logical `ppq`)
has no stage left to run in.

Interval dirt narrows the freeze below channel grain: a channel whose only dirt is note-column
edits carries its CC/park/pb state forward like a clean channel and splices just the closed spans —
`rebuildInternals` excises and re-clones the note span (§ Interval materialisation), `rebuildCCs`
splices the seed-touched windows, `rebuildPbs` gathers span-bounded. Wholesale dirt
still replaces the whole channel.

Dirt is a lattice — `nil` < seed list < `true` — held by `dirt.lua`, one journal
per tracker, which the edit side and the rebuild share. Every writer calls `add`,
which **joins**: it raises a channel's entry and never lowers it, so a pass may
discover more dirt, never less. What that protects is dirt that survives no
restatement: `setLength` marks all 16 wholesale for OPEN tails spanning the new
end, and an OPEN tail stages no mm op, so it leaves no seed to be rediscovered
from. A demotion to a co-occurring kill's seed would leave that OPEN tail uncut.
Pinned in `tm_tail_gating_spec`, and the lattice itself in `dirt_spec`.

Past the cap the dirt collapses to the whole channel, so `rebuildInternals`' excise-skip and its
fresh column build agree with the tail walk. `add` enforces the cap, so the tail walk's own
mid-pass emission collapses on the same terms as an edit's seeds.

### The pipeline

The stages run in this order, each stage named for the helper that
runs it.

1. **Partition and internal lanes** (`rebuildInternals`)
1. **CC walk** (`rebuildCCs`)
1. **Extra columns** (`rebuildExtraColumns`)
1. **Externals** (`rebuildExternals`)
1. **Sample stamp** (`stampSamples`)
1. **Note fx spans and windows** (`computeNoteFxSpans`, `windowSet`)
1. **Region-replace parking** (`rebuildRegionPark`)
1. **PA dispatch** (`rebuildPA`)
1. **Fx expansion** (`rebuildFx`)
1. **Tail walk** (`rebuildTails`)
1. **Absorber reconciliation** (`rebuildPbs`)
1. **PC synthesis** (`rebuildPCs`)

Logical projection has no stage of its own: every seat projects as it lands
(§ Logical projection).

### Partition and internal lanes

`rebuildInternals` splits mm notes into stamped-and-consistent
*internals*, foreign-or-diverged *externals*, and derived fxNotes. Each
internal clones into its authored lane, extending the channel's note
columns to reach it — the tail walk clips its note-off, so it can never
overlap. Stale-swing internals rederive `raw` from `ppqL` under the new
swing here (`docs/timing.md` § Rebuild rule). Externals are deferred to
§ Externals.

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

### CC walk

`rebuildCCs` routes markerless cc seats (a cc inside a prior cc window) out
of columns for fresh reconciliation, reconciles each non-derived CC's
`(raw, ppqL)` under the current swing — stale-swing CCs reseat here — then
projects `cc`/`at`/`pc` into columns. Pb projection defers to
§ Absorber reconciliation, pa dispatch to § PA dispatch.

The reconcile has two rules:

- A swing-stale channel: ppqL is truth; reseat `raw = fromLogical(ppqL)`.
- Otherwise, if raw diverges from ppqL: external raw edit; restamp
  `ppqL = toLogical(raw)`.

Reconcile updates are mutated into the live cc record so the subsequent
column-event clone sees up-to-date values; `mm:assign` propagates them at
the end of the walk.

A markerless pb seat (nil `ppqL`) inside a previous pb window skips this
reconcile: it's a generated seat `deriveChan` owns, not foreign MIDI, so it
stays markerless — and a genuine in-window pb from the user is
indistinguishable, so it's absorbed the same way (docs/generators.md
§ Route-by-window). The window test is half-open, since the re-centre seat folds
at `endRaw - 1` and the end row carries no seat (mirrors `inSeatWindow`).

`ccExisting` covers only the seed-touched prior cc windows, edge-inclusive
(`windowSeeded`). A clean window appears in neither the existing set nor the
predicted one — emission clips to the emit scope — and the reconcile deletes
from `existing` alone, so a clean window's seats are never visited and never
rewritten. Edge inclusion is load-bearing: deleting a window's bounding onset
seeds exactly its end edge, and admitting `row <= end` keeps that window's
prior seats in `existing` to be matched rather than duplicated.

Derived events are handled separately: absorber pbs by the absorber pass
(against the post-walk lane-1 layout); synthesised PCs by PC synthesis.
Pb column projection is deferred to the absorber pass so it sees the
final reconciled absorbers and recomputed raw vals.

### Extra columns

`rebuildExtraColumns` grows `extraColumns[chan].notes` if live allocation
exceeded it, pads empty note lanes, and materialises user-opened
singleton/cc columns that carry no events, along with the cc columns the
track's param bindings imply. It writes back via `ds:assign` if the
high-water mark grew.

### Externals

`rebuildExternals` reintroduces the partition's externals, up front (after
the stale-swing reseat, before the window pass),
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

### Sample stamp

`stampSamples` runs under trackerMode only (§ PC synthesis). Every note
bears a sample, stamped once from the PC prevailing at its onset, and
inheritance freezes at stamp time. Only a note with no sample is stamped,
and the sweep is dirt-gated: a wholesale channel walks every note, where
interval dirt visits just the seeded uuids.

### Note fx spans and windows

`computeNoteFxSpans` walks each channel's note columns in the logical
frame, so a note's fx reaches to the next same-lane onset, floored by the
authored end or the take length, with chord-mates held open to a common
clip. A region's span is authored, so only the note hosts are computed. The
fx window set is those spans plus the fx regions, each parked or
still-producing host entering as a degenerate one-note region. The set is
assembled twice: a head set for the note pass, and a settled set
(`settleWindows`, called from inside the park stage) for cc/pb membership
and `rebuildFx` (§ Note fx span cache).

`windowSet` holds each set. Every stream a host parks takes the host's own
span, so one window per host is the whole fact — channel, span, host type,
and the targets its chain reaches, from `generators.chainTargets`. The set
answers in whichever shape a reader wants: membership for the park scans,
the windows themselves for the tail's maps, and the per-target list,
ordered note, pb, then cc ascending, for the stages that walk one and for
the `prevWindows` write.

### Region-replace parking

Under `rebuildRegionPark` the authored notes and ccs a replace-region
covers leave the take — and so does any note
hosting its own discrete-replace kind (note-host replace parks the
host; see `docs/generators.md` § Hosts and membership). The
prior parked set splits into still-covered carry-forward and restores
that re-enter their columns unrealised until the same stage's commit
lands them, keeping their uuid and fx. A
restored cc lands on the exact ppq of the fill seat the wider window
left on the take; under uuid addressing the two are distinct events, so
the fill reconcile deletes that seat by its own handle and the authored
value stands. Carried-forward tails clip against on-take note
bounds the same way the tail walk clips real notes, so a parked tail
stops at the first successor past its region, not just the next
parked member. `realiseParked` caches each member's render clip
(`endppqC`) per uuid in `parkedClipEnd`, dirt-gated exactly as the
fx span cache (§ Note fx span cache): a member reseeks only when its
channel is wholesale-dirty, it is uncached, its own uuid is seeded, or
a seed ppq falls inside its cached span; else the cached end rides. The
reseek is a binary seek into the member's sorted lane column
(`nextLaneOnset`, shared with `clippedSpanEnd`) plus a small member-only
strict-next map for parked neighbours. The cache is take-scoped, and drops at the
take-tier seam alongside `noteFxClipEnd` (§ Note fx span cache). Lane bound only, never pitch: a parked cell never
reaches mm, so it carries pure intent — the same span
`computeNoteFxSpans` gives an on-take host. The note del/adds ride the
tail walk's atomic commit. See `docs/generators.md` § Output. Each pass's
`scan` builds its `spec` inline at the scan site, where that pass's
`chan`/`lane`/`cc` are in scope; `reconcilePark`'s optional `onPark`
callback fires only for specs newly parked this rebuild (e.g. marking
the note pass's channel dirty), never for carried-forward priors.
`covered()` — the same predicate `reconcilePark` applies — gates both
scan loops before they clone a `parkSpec`, so a take with no fx
windows builds an empty scan and pays nothing per event; it accepts a
stash spec or a column event — both logical, so it keys `ppq` directly.
`covered()` wraps `coveredBy()`, which answers the parking producer's
uuid rather than a bare bool: a `currentWindows` entry is checked
first, and only then the spec's own `fx`, because a self-parking host
inside a region's window is that region's membership rather than its
own producer — the same reading `rebuildFx` takes.
A `pa` rides its host note, so it parks exactly when the host does:
deleted from the take (silent — a stale PA against a fresh derived
stream is meaningless; the generator owns any new realisation PAs),
stashed in `fxParked` tagged `pa`, reconciled against the parked-note
set rather than in its own window pass.

### PA dispatch

`rebuildPA` attaches each `pa` to the note column whose voice it
modulates. It runs after column layout so the view and fx expansion read
PAs inline, and after externals so foreign-MIDI PAs find their host. A parked PA is gone from `mm`, so it is re-projected from
`frame.channels[chan].parkedPA` into its parked host's lane — visible
off-take, riding the note column as an on-take PA would. Both passes
splice in order (`spliceCell`), so nothing downstream re-sorts.

### Fx expansion

`rebuildFx` receives the settled windows as a parameter, the window pass
being its own earlier stage. Every producer the gate does not keep runs
(§ The producer gate)
— on-take fx notes (augment hosts), parked
note hosts (window = the realised parked extent), and fx regions; the
derived fxNotes reconcile
against the partition's set (`reconcileFx`), and continuous streams seat
offline — cc-augment sums per target into markerless cc seats, pb defers
to the absorber pass. The note add/del leaves `rebuildFx` as data
(`fxOut.noteOps`); the tail walk seeds its own batch with it and commits
atomically, so every stage can read what crosses the boundary.
`fxOut.noteLive` (the predicted set) feeds the tail walk and PC synthesis. See `docs/generators.md` § Offline continuous realisation.

### Tail walk

Under `rebuildTails` real notes, fixed externals and the predicted fxNotes
walk together: clamp same-pitch onset collisions with fixed onsets frozen,
then clip each realised note-off against its same-lane and same-pitch
successors. The clips commit with the fxNote del/add in one `mm:modify`.

The universal tail pass resolves each note's realised
note-off against its same-lane and same-pitch successors. The "strict
next" — first group member with a strictly greater ppq, chord-mates at
equal ppq skipped — is precomputed once per ppq-sorted group in a
back-to-front pass, then looked up per note. A retrig host expands to a long
run of same-pitch fxNotes, so a per-note rescan would make the walk O(k²)
inside the group.

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
is invisible.

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
against them. The predicted fxNotes (`fxOut.noteLive`) walk here too; a record
with no token (a new fxNote) carries its clipped geometry into its
`mm:add` rather than a tail assign, and the clips commit with the fxNote
del/add in one modify.

#### What the walk visits, and what it emits

The walk reads its whole channel but does work only where the pass has
news. The channel's dirt arrives as seed dirt (§ Interval seeds), and
a note the dirt does not name kept its raw and its ceiling — last pass
left it separated and clipped against neighbours that also stood still.
`disturbed` is that judgement and it is the whole of the walk: a note is
disturbed if a seed names it, if it is derived, or if a nudge moved it. A
seed names by uuid where it still answers one — a survivor, recovered
live from `byUuid` — and by logical seat otherwise: an add, whose uuid
lands only at commit, and a delete, whose uuid is already gone. Derived
notes seed only where their producer re-ran: `rebuildFx` regenerates those
tiles, so their raw is this pass's news whatever the dirt says. A kept
producer's specs come back verbatim, settled and clipped last pass, so they
ride as bound anchors only and don't count toward the frontier threshold.

Separation narrows on the same judgement. Only a disturbed note can
collide, and only onto its same-pitch predecessor — so a nudge marks its
own note disturbed and the cascade carries forward under its own power.
That is what keeps the walk from fencing a chain: the walk never has to
know in advance how far a cascade will run.

Settlement runs against a pristine index. Each pitch's cascade chain is
gathered first and settled by position afterwards: probing an index the pass is
mutating unsorts the list the probe binary-searches, and the search cycles.
Seed resolution is scoped to a note on this channel for a neighbouring reason —
`index.byUuid` answers pbs and ccs too, and a seed resolving to one buckets on a
nil pitch.

The set of notes to re-bound is seed-driven, not span-tested. A note is
bound if it is disturbed, or if it is the nearest same-lane or same-pitch
strict predecessor of an *anchor* — a seed position (dead seeds included)
or a disturbed onset, found by one `util.seek 'before'` probe per axis.
Probing the predecessor subsumes the old authored-span stale-test: a
shield standing between a seed and an open note behind it is itself that
seed's nearest same-lane predecessor and holds the clip, and a deleted
neighbour that can no longer be asked for its onset is reached because its
death position is a seed and the note it bounded is that seed's
predecessor.

Successors come from one backward pass carrying, per lane and per pitch,
the note last seen and that note's strict next — a neighbour sharing the
current note's raw is no successor of it, so it hands over its own. Parked
bounds come from a scan instead of a bucket, parked cells being few and read
only for the notes the sweep bounds.

The walk **emits**. A nudged lane-1 onset moved every absorber seat
between it and the next lane-1 onset, so the walk adds that interval to
the channel's dirt and `rebuildPbs` consumes it later in the same pass.

Two walks share these rules; a seed-count threshold picks between them.
The **linear walk** is authoritative for dense and wholesale dirt: one
forward onset pass, one predecessor probe per axis to build the bound
set, one backward pass to clip and emit — over the whole channel. It is
the degenerate fallback. The **frontier probe walk** takes the common sparse-seed
channel: it seeks to each seed by name and probes a bounded few rows for
its lane and pitch neighbours, with no whole-channel traversal and no
`mergeIndexed` — the sorted index and the small extras list stay separate
probe sources.

### Absorber reconciliation

`rebuildPbs` reseats absorber pbs against the post-walk lane-1 layout,
recomputes their raw vals, and projects the pb column. See
`docs/tuning.md` § Absorber reconciliation.

### PC synthesis

`rebuildPCs` re-derives each channel's PC stream from current note state,
under trackerMode only. It runs after externals so a foreign-MIDI note
inherits its sample from the prevailing PC.

`note.sample` is per-note authoring intent (which sample the note
plays); the PC stream is the realisation MIDI synths consume. tm owns
the reconciliation.

`trackerMode` itself is wiring-derived, not a per-frame probe: on each
`bindTake` the page asks `wm:samplerReachable(take.track)` — does the
take's MIDI cone reach a Ctm Sampler — and seeds the transient
tier inside the bind's suppression window. So the mode tracks the
*bound* take, never lagging on the arrange cursor mid-navigation (the
bug that leaked synthetic PCs onto a non-tracker take's note-ons).

Synthesis runs in one place, and this stage is it. The delta goes to mm.
Its `records` list comes from the channel's raw-index notes plus the
fx-derived live ones, and feeds through the pure `reconcilePCsForChan`
helper; records lost to lane priority get `sampleShadowed = true` for
renderer dimming. A raw-index note carries its column cell as `cell` and
marks through `setCell`; an fx-derived note holds no cell, so it carries
the spec as `spec` and the field is written direct (§ Note-lane
renewal). The flag is realisation, re-derived every rebuild, so a park
round-trip drops it.

Seed dirt narrows the sweep to spans rather than rows. `pcSeedSpans` closes
each seed onset to `[onset, next onset)` — the interval over which one note's
PC prevails — and the existing set, the records and the pc-column splice all
filter on them. A span carries both frames, since a projected column cell tests
logical where an mm record tests raw. Fresh derived output ungates the channel:
an fx-born onset has no verb seed to name it, so a pass holding any unkept
`noteLive` spec synthesises wholesale.

Group membership is by **realised** ppq, not logical — same-channel
simultaneity is a MIDI-realisation constraint (one PC stream per
channel at any moment), so the leftmost-wins rule fires only when
realised onsets actually collide. Notes split apart by delay get
their own PC each, even if their logical ppqs match.

### Logical projection

All projection runs through `projectCC(cc, overlay)`: it clones the
source event, strips only `chan` and `cc`, and applies the caller's
`overlay` of derived fields. Everything else — including metadata not
known here — rides through verbatim, so new event fields reach
`col.events` without a change to this layer.

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
the externals pass. That stamp is what makes "columns are logical" true;
gate it and sidecar-less events reach columns in the raw frame, where
`rescaleLength` would warp them through swing twice.

`evt.endppq` is the AUTHORED logical ceiling (mm's `endppqL` stamp, or
`util.OPEN` for a deliberately-unbounded tail). `evt.endppqC` is the
LANE-clipped logical ceiling — render-only, plus the sounding extent a
parked cell hands a generator. It is not the inversion of mm's raw
`endppq`: the walk clips the wire further at the next same-pitch onset,
and that clip never shows (§ Tail walk). An uncached note (no
`endppqL` stamp in mm) has no authored ceiling, so it falls back to
`endppqC` — the lane bound, not the realised one.

Every seat projects exactly once, at ingestion; carried events were projected by the pass that
seated them, and nothing walks a column to re-project — a second projection would corrupt `delayC`.

### Closing the pass

The pipeline then persists its own window set: `settledWindows` goes to
`ds:assign('prevWindows', …)` when it differs from the set this pass read,
so the next rebuild recognises seats against it. `stager.clear()` drops
un-flushed ops, the pass's dirt folds into `muteConform` and clears,
and `derivedInputs` re-snapshots once the pipeline's own ds writes have
settled. The index itself needs no tail step: on a wholesale reload
`stager.reload` re-read it whole at the pipeline head,
before any stage read it, and the pipeline's own commits maintained it from
there; edit rebuilds kept the live index throughout (§ Incremental index
reconciliation). tm fires the `'rebuild'` signal carrying the `takeChanged`
boolean — true only when this rebuild followed a `bindTake` (a take-tier
reload).

## Span-covered fx scans

`coverInto(list, spanSet, admit, emit)` builds the span cover of a ppq-sorted list: the governing
entry at-or-before each span's start (so `curves.eval`/`curves.slice` reads within the span see the
right precursor), every entry through the span, then the closing entry past its end. `admit`
filters entries out of governance and emission alike — a skipped entry never governs; spans dedup
across a call by resuming from the last consumed index rather than rescanning from 1.

`eachWindowNote(chan, startL, endL, fn)` covers rather than scans a lane's onsets: it seeks the
governing onset at-or-before `startL` (its sounding tail may reach into the window) and walks
forward through one closing onset past `endL`. Membership is still overlap, not storage —
authored notes are re-queried each rebuild, one walk feeding both generator events and fixed lane
occupancy. See `docs/generators.md` § Hosts and membership.

`pbBaseFor(chan, spanSet)` / `ccBasesFor(chan, spanSet)` build the absolute authored base (ppq-keyed,
logical) covering only the caller's merged producer windows, not the whole channel: every read of
the base — `channelStreams`' slices, the cc fold, `rebuildPbs`' fold — is itself span-bounded, so
the cover is exact there and the scan is never O(channel). Parked events are authoritative at
their ppq (deduped against the cover); the maintained pb index is raw-sorted, and since pbs carry
no delay and swing is monotone, the raw-frame cover equals the logical-frame cover — spans convert
via `tm:fromLogical` before the walk. "Authored" means the cents sidecar is present (seats and
foreign pbs carry none).

`nextSameLaneNote(host)` looks up the strict next same-lane note by seeking directly in the host's
lane column instead of building a per-channel map up front, then takes the nearer of that and the
lane's parked cells. Lane occupancy is column ∪ parked — the same union `renderUnion` puts on the
grid — so a parked host has a successor despite being off-take, and a parked successor is the
target a slide aims at. The subject is the *producer's* lane rather than the stream note's: a
region spans lanes, carries none, and resolves to nil, which is also what keeps a region-hosted
`target='next'` off a member record that carries no channel.

`rebuildRegionPark`'s note/cc scans are span-covered the same way: `coverOnsets` walks each
channel's window spans (merged per-channel for notes, per `(chan, cc)` for ccs) rather than the
whole column, since a covered event sits inside a current window by definition — the spans are
the complete cover set. Self-parking fx hosts are the one exception: `chainTargets` suppresses their
own note target, so they carry no note window, and the note pass sources them separately from the
fx-host set (`noteFxSpans`), gated by `generators.parksNotes` and deduped against the
window-driven scan by event identity.

The PA scan closes the rule from the mm side: a PA rides its host note, so a newly parked host's PAs
are exactly those in the host's logical span. `mm:ccsRawBetween(chan, loPpq, hiPpq)` binary-searches
the maintained cc index (raw-sorted, hole-free right after the pipeline's last reindex — every
committed stage ends in one) for that channel's slice; each parked member's span converts to raw via
`tm:fromLogical` before the query, and since PAs carry no delay the raw bound equals the logical
span. The exact `hostParked` pitch/logical filter still gates each candidate — the bound only
replaces the per-channel `mm:ccsRaw` walk, so work scales with parked members, not channel cc count.

## Note fx span cache

An fx note-host's span is `[onset, spanEnd)`, where `spanEnd` is the authored (or take-end)
ceiling clipped to the host's strict-next same-lane onset — the ground a vibrato or tension producer
seats across. `computeNoteFxSpans` caches each host's `spanEnd` per uuid (`noteFxClipEnd`) and
recomputes one only when the dirt reaches it: the host's own uuid seeded (its move or length
mutation), or a seed ppq fell inside the host's cached span (a neighbour onset that becomes the
new clip). Everything else rides the cached end.

The reseek is walk-free. `byUuid[uuid].colEvt` (the seat stamp, § Incremental index reconciliation)
back-links a host uuid to its live column cell, so a dirty host reclips by seeking its own lane
column through `index.colEvtFor(uuid)` rather than the old per-channel walk that built every column's
successor map up front. `clippedSpanEnd(cell, takeLenL)` does the clip against `nextLaneOnset`.

Two paths still walk the channel. A wholesale-dirty channel carries no seed positions to test a
span against, and a restored fx host (unparked this rebuild) is not yet stamped onto `byUuid` when
the post-park call runs — both fall to `walkChannel`, which recomputes every host on the channel and
refreshes the cache. `perHost` returns false (forcing the walk) the moment it meets an indexed host
with no live cell, so an unstamped host is never silently skipped.

The cache is scoped to the bound take. `tm:rebuild` drops it, with `parkedClipEnd`, on the branch a
take swap or a wholesale re-read enters (`forgetCaches`); mm mints uuids per take, so an entry
surviving that seam addresses an event of the take just left.

A take-length change reclips every OPEN span, yet needs no guard of its own. Length moves only
through `mm:setLength`, which fires a `wholesale=true` reload — that same branch — so every fx
channel walks afresh at the new `takeLen`.

The two calls per rebuild (head `headFxSpans` feeding the note pass, post-settlement `settledFxSpans` —
computed by `settleWindows` from within the park stage — feeding cc/pb membership and `rebuildFx`)
share the one `noteFxClipEnd`. Park and restore seed the channels they touch, so the settlement call
recomputes exactly those and reuses the rest.

**The reuse arm is unexercised by the suite.** Removing `perHost`'s seed-driven invalidation
outright (`local dirty = cached == nil`, dropping `seededUuid[uuid]`) leaves every spec green, so
nothing distinguishes a host riding a stale cached span from one that recomputes. A fixture
reaching the arm needs all three of a warm cache, seeded dirt naming the host, and a span end
that moves. Until one exists, treat any change to this cache as unguarded.

## The placement fixpoint

Parking is realisation→intent feedback inside one pass: windows decide park
membership, parking moves note onsets, and note onsets clip fx spans
(`clippedSpanEnd`'s strict-next-lane-onset bound). The pass closes the loop
by splitting membership across the settlement point.

Note membership reads the head window set, and is exact there: note
windows come only from authored `fxRegions` (`chainTargets` suppresses the
note target on a note host's own window) and a note host parks itself by predicate,
so note membership reads nothing the pass moves.

Continuous (cc/pb) membership reads the settled set: after the note and
PA passes, `rebuildRegionPark` calls the pipeline's `settleWindows` to
recompute the note fx spans from the settled columns and reassemble the window
set — the same call feeds fx expansion, so there is no extra window pass.
One settlement step suffices by construction: cc/pb parks remove no note
onsets, so continuous parking moves no window, and a second continuous
pass could create no new coverage.

The dirt gates stay sound under the split: a note park only moves windows on
its own channel, and the note and cc scans share the same per-channel gate,
so any channel whose windows can move mid-pass is already dirty when the cc
scan runs.

The over-approximation arm is looser still: restores narrow windows, so at
worst the settled set carries a member the layout no longer covers, and the
prior-set partition — ungated — restores it at the next rebuild.

## Fx window census

`windowSet` builds the pass's fx windows from three sources — authored `fxRegions`, on-take
note hosts (`noteFxSpans`, from `computeNoteFxSpans`), and parked fx hosts (`parkedSpecs`) — and the
latter two are disjoint only because `settleWindows` declares the pass's parks to `computeNoteFxSpans`.
The fx-host index turns over a rebuild late: `reconcilePark` unlinks a parked host's cell at once,
but its mm delete waits for the tail-walk's atomic commit and index membership rides that commit, so
in between the index still names a host that has left the take. `perHost` resolves uuids straight out
of it, so undeclared, a self-parking host would land in both arms — and fx expansion, whose producer
bucket is `noteFxSpans`' keys plus `frame.channels[chan].parked`, would run its chain twice and
`curves.foldChains`
would sum the two pb curves to twice the authored depth. The declaration therefore sits at the
writer, where one statement serves every reader.

`windowSet` holds the pass's windows once: the window per host is the fact, and the per-target list
a view over it. Every window is minted inside the set, so stamping `targets` touches no record the
document owns.

`freezeRegion`'s resync drops the frozen producer's entries from `prevWindows` (the
seat-recognition baseline) by their stamped `id`: every per-target entry the set emits carries its
producer's uuid. The stamp is identity for subtraction only — seat recognition still matches on
spans, so nothing downstream reads it. Identity is what the subtraction needs: two producers can
emit identical windows (a same-target overlap, or two on-take hosts riding the same fx), and a
value match could take a surviving neighbour's entry, leaving the next rebuild to read its seats as
freshly authored and park them off-take. The `id` drop also holds for a persisted window that no
longer recomputes field-for-field (a kind deregistered, a clipping context changed): it still
leaves with its producer.

The same census answers freeze eligibility, through the window set the pass holds: the rebuild
publishes it beside the rects, and it outlives the pass.

`freezeRefused` makes one pass over the producers on the frozen one's channel and refuses on
three counts. An overlapping neighbour claiming a target the frozen producer claims would be left
standing over the raw output the freeze creates. An fx-carrying host whose onset the frozen note
window covers is destroyed with the chord that window parks, and emits no note window to be caught by
the first count — a `hostType = 'note'` window suppresses a note-dest host's, and a continuous-only
chain has no note arm to suppress in the first place. A note-dest host emits no window at all, so it is tested the
other way round, its own span against the neighbours' note windows. The overlap test is half-open on
every target: the pb re-centre seat folds at `endppq - 1`, so abutting windows share nothing and are
disjoint in fact as well as in the test.

`tm:freezeEligible` and `freezeRegion`'s gate both compute refusal from the published set, so
the button and the verb answer from one source. Freeze then reads coverage from that same set,
narrowed to the frozen uuid: the gate has refused every neighbour sharing a target inside the
frozen span, so whatever the set covers there it covers on the frozen window's behalf, and freeze
builds no set of its own. Refusal is silent and total — false, computed before
any gather, so nothing of freeze's own is staged. A region stored on channel 0 refuses ahead of all
this: it runs sixteen producers and is none of them, so no one channel's output is the one to convert
(§ Channel & column model). Its expansions are producers of their own, so a chain overlapping a
global chain's output is refused like any other neighbour's.

The published set states *what is committed* — `fxRegions`, the maintained fx-host index, the stash,
as the last rebuild settled them — so `freezeRegion` flushes before it asks. A host staged and not yet flushed is absent from the index and
invisible to the gate, and freeze's own closing flush would then commit it: a live window over the
seats just frozen, which are markerless, so its producer re-derives them — with success reported.
The leading flush is a no-op when nothing is staged, at the price of one empty `preflush` (which
`flush` fires ahead of its no-op check).

## The producer gate

Under seed dirt a producer whose window no seed touches does not run. Its
derived specs come back verbatim from the last pass (`keptFor`), and
`reconcileFx` self-matches them by `fxKey`, so a kept producer writes nothing
to mm and re-derives nothing.

Keeping is decided against the emit scope, not by the kind of chain. A
continuous producer is keepable when no target's emit scope intersects its
window: emission clips to that scope, so a kept window and a fresh emission can
never claim the same seat. A kept pb window still records its geometry, tagged
`kept`, because pb seats are markerless downstream — a window absent from the
record would leave its seats reading as authored pbs.

The verdict reaches the tail walk, which is where the gate pays. A kept spec
was settled and clipped last pass and is identity-kept in mm, so it rides as a
bound anchor only and does not count toward the frontier threshold (§ What the
walk visits, and what it emits). Without that, a channel dense in parked hosts
re-clips every kept derived note on any edit, and a one-note change falls off
the frontier onto the linear walk.

## Note-lane renewal

tv's cell carry keys on a column's `events` **table identity**: the same
table coming back means reuse the built cells and ghosts. That makes the
identity a protocol — a lane's `events` table must change identity exactly
when something a renderer can see about that lane changed. **Renewing** a
lane is replacing that table with a clone of itself, and a renewal without
cause costs tv a re-place of the whole take — 7.8ms of `place` on a dense
one.

Renewal is precise, and every mutator of a seated lane owns it:

- **membership** — `exciseNotes` assigns only when it actually dropped a
  cell; the splices (`rebuildInternals`, `rebuildExternals`, `rebuildPA`,
  the park restore) go through `spliceCell(chan, lane, cell)`, which renews
  before it splices, and the park unlink calls `renewLane(chan, lane)` itself.
  It takes the seeded rows and seeks each one into each lane rather than
  testing every cell against a predicate, so a lane holding no seeded row
  costs a binary search and nothing else. A `claims` refinement narrows
  within the row cluster, which is how the parking PA sweep reuses it
  (matching PA type + uuid) instead of hand-rolling a second filtered copy.
  The seek stands on cells being projected — `ppq` holds the logical row,
  so a seed's row is the lane's own sort key, and the cluster at it is
  contiguous whatever the note-before-PA tie-break does inside.
- **content** — an in-place field write on an already-seated cell goes
  through `setCell(cell, field, value)`, which renews only when the value
  moves. Writing unconditionally would renew every bounded lane on every
  pass, because the tail walk restamps `endppqC` for each note it binds.
  A record holding no cell is written direct instead: `setCell` reads
  `(chan, lane)` off whatever it is handed, so an off-take fx spec would
  renew the lane its number names while that lane's own cells stand.

A lane renews at most once a pass. `renewLane` keeps the memo of what it
has already cloned, and a caller that replaced the table itself records it
through `markRenewed`; `newPass` clears the memo with the channels map it
belongs to.

The failure is asymmetric — too pessimistic costs a re-place, too
optimistic silently renders a stale cell — which is why the enumeration,
not the conditional, is the work. The tail walk is the reach to watch:
`settleOnset`'s `delayC` and `boundNote`'s `endppqC`/`endppq` land on notes
no seed covered, in lanes otherwise carried whole.

Two cases need no renewal. Wholesale and stale-swing channels get a
brand-new `columns.notes`, so their identity is fresh by construction. And
a local bound to `col.events` that outlives a renewal operates on the dead
table — the read-only walks (`eachWindowNote`, `channelStreams`,
`coverOnsets`) do not care, but the park scan did, which is why a note
carry stores its lane index and resolves the table at unlink time.

## Dormant guard

When the tracker page is not active, `bindTake(nil)` clears cm's take context
while mm still holds the last take. The shared cm fires `configChanged` every
frame regardless of which page is active (e.g. samplePage's per-frame tick). A rebuild
fired in this state would resolve swing/trackerMode off empty take tiers, causing
a mm/cm mismatch. The `configChanged` subscriber therefore returns early if
`cm:boundTake()` is nil; the next real `bindTake` call fires a coherent rebuild.

That guard **drops** the change. Under the converged-rebind gate
(midiManager.md § Converged load) a rebind may mark nothing, so what happened
while the tracker was away has to be recovered at the bind.

The worst case fires no signal at all: the ds/cm state under the bound take
and its track (`swing`, `fxRegions`, `extraColumns`, `fxParked`,
`paramAutomation`, the take config tier) is rewound by a REAPER undo while
`ps` watches only the *bound* take's slots, and cm/ds refill their caches
from storage at the next `setContext`. The same blind spot swallows the
`trackerMode` re-seed, which `bindTake` writes under its own suppression
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

## Fx as rebuild phases

Fx is a set of phases woven into tm's one rebuild, sharing the `fx`
accumulator and the deferred mmBatch; the tail walk fuses authored, external
and derived notes into one atomic commit. Parked edits coordinate with
`adds`/`assigns`/`deletes` inside `flush` besides (§ Mutation contract). Both
therefore live where tm's `channels`, `fx` and `deferred` live, since
lifting either out would mean reaching across a layer for them.

Pressure on tm's size goes to `generators`, which takes the *pure* fx logic
(`docs/generators.md` § The ctx discipline). If size forces a structural
split, the seam is the whole rebuild pipeline lifted to a `trackerRebuild`
file with `channels`/`fx`/`deferred` as an explicit ctx.

## Column allocation rules

`noteColumnAccepts` is consulted only for unstamped raw notes; a
stamped note never reaches it (§ Partition and internal lanes). For an
unstamped
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
it in the **logical** frame (`index.forEachAttachedPA`). A PA carries its own
`ppqL` and the CC walk reswings it from that seat, exactly as it does a
note. So a host's realisation moves independently of the PAs it owns: a
forward delay pushes a note's raw onset clean past a PA at its own logical
seat, and the tail walk's same-pitch nudge does the same for a tick. Only
the logical test still counts those PAs as attached, so only it moves and
culls them with their host; a raw-frame test would orphan them in `mm`.

Reading um's index rather than mm also widens what counts as attached: the
index carries staged adds, so a PA added this gesture and not yet flushed
follows its host's resize or delete.

`index.forEachAttachedPA` gathers its matches into a list before invoking `fn` on each, rather than
calling `fn` inline mid-walk. `fn` is `deleteLowlevel` or `assignLowlevel`, and both remove from
and reinsert into the very `pas` list being walked — a `table.remove` mid-`ipairs` shifts the next
entry into the removed slot, so an inline call would skip it.

`resizeNote` follows the same rule, and has to follow it twice: once to
decide whether a move is a translation, and again to perform the carry.

The translation test compares **logical lengths** (`L2 - L1 == endL -
startL`). Swing is a periodic warp, so a whole-note logical move is a
whole-note raw move only when the note's length is an exact multiple of the
swing period — only then do both endpoints keep their phase and shift by the
same amount. At any other length they warp differently, and a raw-frame test
reads the move as a resize, culling every PA the new span excludes. The
function therefore takes the logical span. In the logical frame `OPEN` is
just `math.huge`, and
since `math.huge` minus either seat is `math.huge`, an open tail that
stays open satisfies the same equality with no special case.

The carry is logical for the same reason, and for a sharper one. It moves
the PA's seat by the host's logical shift and realises that seat through
`fromLogical`, rather than adding the host's raw delta to the PA's raw.
Under swing those two disagree — and a PA whose raw and seat disagree is
not merely imprecise. On a settled channel the CC walk reads the
divergence as an external raw edit and restamps `ppqL` from the raw
(`rebuildCCs`), so a fabricated realisation silently overwrites the very
intent the carry set out to preserve. Only a swing-stale channel gets
the reverse treatment, its seat reswung into raw; everywhere else, raw
wins the disagreement.

## Park identity

`fxParked` is one flat list holding every parked type, and `findParked`
is what an edit to a parked cell resolves through. Notes key by `uuid`;
everything else by `(evType, chan, cc, pitch, ppq)`.

`pitch` is there for PAs, which are the only type that can put two
cells on one `(chan, ppq)` — one per host note. It is `pitch` and not
`lane` because lane is a display attribute, and keying on it would
mint a distinction the take cannot hold: two parked PAs differing only
by lane would collapse into one the moment they were restored.

A stash spec is **logical only**. It drops realised `ppq`/`endppq` and derives
them fresh on restore via `fromLogical` under current swing, so a swing change
under a parked chord reaches it as it reaches everything else. What a parked
cell carries besides is the fields its backing addresses it by (`chan` +
`uuid` for notes, `chan` + `ppqL` for ccs) plus the authored ceiling as
`endppq` — which is what lets the note move and resize machinery work on
parked cells unchanged.

## Realisation by producer

**1** The ghost overlay asks one question — what does *this* chain realise —
and asks it per frame, off a caret that moves without a rebuild
(`docs/trackerView.md` § Ghost sampling). Answering at read time would mean
walking every channel's derived notes and every parked cell in the document,
per frame, to discard nearly all of both. The rebuild already holds the
answer: a derived spec carries its producer's uuid as it is emitted, a park
window carries the id of the chain that opened it, and the census names every
producer on the take. So tm keys those three outputs by producer as it builds
them and gathers them into one entry per chain at the pipeline tail;
`tm:fxRealisation` hands a host its entry and the view's query is a lookup.

**2** The claimed continuous targets come off the **census**, not the
emission. Emission is dirt-gated — a producer outside the dirty interval is
kept rather than re-run, and a kept producer emits no record — so a target set
read off it would vanish on the first edit elsewhere in the channel and return
with the dirt. The note half can ride the emission because the reconcile
re-adds a kept producer's specs verbatim; nothing re-adds its curve. What does
not blink is `chainTargets`, which already names a target per continuous cc
dest and one for pb, blind to dirt and blind to bypass, so the target set is
the window set the rebuild computes for parking anyway.

**3** One thing follows from taking the census whole: a note host claims its
targets exactly as a region does, so a note carrying an lfo ghosts into the cc
column it modulates, wherever the channel carries one.

**4** `tm:fxCurveAt` is the sampling half — what one chain realises on one
claimed target at one logical ppq, called once per row per frame. The channel
it reads on comes in as an argument rather than off the entry, since one chain
can realise on sixteen of them.

**5** A stored global region runs no producer of its own (§ Channel & column
model), so its uuid answers with the union
of the producers it expanded into — their derived notes, their claimed targets
and the cells they parked. The entry therefore names the channels it realises
on rather than one channel, and each note in it carries the channel of the
producer that emitted it.

**6** The claimed spans are logical, not raw. Each expanded producer claims its
target over the same logical window, so the union merges back to the stored
region's own span, while raw spans would be as many different intervals as
there are channels under per-channel swing. The conversion to raw happens at
the sample point, where the take is read.

## Muting

tv owns the effective mute set (persistent mute ∪ solo-implied mute)
and pushes it via `tm:setMutedChannels(set)`. tm:

- stores it in `lastMuteSet` (used to tag later-added notes in um);
- idempotently syncs REAPER's native muted flag on every existing note
  through `tm:assignEvent`, then flushes.

Mute state is a tv-side concern — it **does not** trigger a structural
rebuild. `mutedChannels`/`soloedChannels` live in `ds`, not `cm`, and are
not among the `dataChanged` keys tm rebuilds on (§ Rebuild).

## Staged-update bounds

When `realiseNoteUpdate` stages a delay or endppq change, the raw onset
and raw tail are clamped immediately (`onset ≥ 0`, `tail ≤ takeLen`).
The authoritative clip is the tail walk's, which re-applies the full
same-pitch and take-edge constraints against the final post-walk geometry;
flush re-applies on every write. Clamping here keeps the staged raw value in
range, so interim mm readers (before the next rebuild) see only in-range
values. Divergence surfaces in the render cues: `delay ~= delayC`, which tp
paints as a `*` beside the delay digits, and `endppq ~= endppqC`, which needs
no cue of its own because the renderer draws `endppqC`
(§ Logical projection).

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

The traversal belongs to the caller. Which predecessor counts as settled,
and how far a cascade runs, depends on which notes the pass has news for —
and that is interval dirt, which only the caller knows (§ Tail walk).

**One site separates**: the tail walk (`rebuildTails`), where real notes
and predicted fxNotes walk together — separate before the atomic note
commit, then clip tails.

A collision an earlier stage passes over is a collision riding one stage
further, to a site that separates it before anything can read it. The
reseat's notes reach the walk through um's raw index, in the same pass and
the same `mm:batch` nest, so mm's backstop — which resolves at the
*outermost* unwind — finds nothing. A flush scan's staged add reaches that
same backstop at flush's own unwind, ahead of the rebuild it triggers.

The walk and the backstop are **independently sufficient** for the reseat
case: disabling either still separates, and it takes disabling both to land
two voices on one raw (`tm_reseat_collision_spec`, which pins the surviving
voice and names no layer). The backstop is a real second line, simply never
reached, because the walk gets there first.

**Commit ordering.** Notes are addressed by uuid, but `collisionIdx` is
keyed by realised ppq, so an occupying move (an edit landing on a peer's
seat) reaches that seat before the peer vacates it. The flush applies note
moves by **descending target ppq** so every vacate leads its occupy. The
reseat path is immune: reswing moves both notes to fresh raws, away from
each other's seats.

Either order leaves the index correct, since `assignNote` evicts only the
slot it still owns. What descending buys is silence: an ascending commit
records a transient same-seat collision, and every pending key costs the
backstop a full walk of the note array at the unwind — ~65µs on glasswork,
against a ~17.7ms flush. Defensive, and too cheap to be worth removing.

## Flush collision scan

Run inside `mm:modify`'s preflush, after `preflush` (propagated peers
already staged) and before the snapshot (separations/deletes ride this
flush). Walks `rawIndex[chan].notes` for each of the 16 channels,
bucketing by pitch, and reports as the `collide` span.

`collisionKills` sits at file scope, not in the stager: it reads the raw
index and returns verdicts, holding no staging state of its own, and the
stager applies them because `deleteNote` is the stager's. It cannot move
into the rebuild either. Running pre-commit is what lands tm's kill
verdicts before mm ever sees a same-pitch collision, which is why mm's own
backstop at the outermost `modify` unwind fires ~never; after the commit, mm's
`resolveGroup` would always pre-empt `voicing.resolveSorted` and the
verdict would be mm's rather than tm's.

That list is exactly the post-flush note set, because every site that files
a note into `byUuid` files it into `rawIndex` too: `makeEntry` is `byUuid`'s
only writer and its only callers (`index.sync`, `index.load`) file into
both, `addLowlevel` files a staged add into `rawIndex` and `adds` together,
and `deleteLowlevel` removes from both. Parked edits are in neither. It is
also already sorted, by `index.order`, a strict *refinement* of the
`(ppq, ppqL)` order the verdict needs: it settles ties `table.sort` would
leave arbitrary, and in those ties the verdict is order-symmetric anyway —
`supersedes` kills the derived note from either side, and with derived-ness
equal the longer `endppqL` wins from either side.

So the scan sorts nothing and hashes nothing: one array walk per channel,
singleton buckets skipped because a lone note cannot collide.

Not a per-self peer walk: two notes can collide without either being the
edited one, and repeated per-self truncation damages peers a later
same-flush op would resolve.

Each group runs `voicing.resolveSorted` for its **kill** verdicts alone
(see `docs/voicing.md`). Tails and onsets belong to the tail walk, whose
bound is the stronger one — post-walk geometry against this scan's staged
geometry — and a rebuild always follows a flush (§ Same-pitch onset
separation).

Kills stay here, and the asymmetry is why: the walk separates but never
kills. A duplicate reaching the walk is separated, and a separated pair is
no longer a collision, so mm's backstop finds nothing left to dedup. This
scan is the only site in the stack that dedups a staged add against a
committed note, and killing through um's verbs carries the semantics mm does
not own (PA culling, detune-aware resize). Pinned by
`tm_flush_collision_scan_spec`. `endppqL` (intent) is never written here, so
deleting a blocker lets the raw tail regrow to it.

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
clean channel's frame would otherwise carry forward unclipped.

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
