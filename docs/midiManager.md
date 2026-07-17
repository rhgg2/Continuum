# midiManager

Abstraction over REAPER's MIDI take API. Provides stable per-event identity
(notes and ccs), per-event metadata that survives save/load, and a batched
mutation lock.

## Identity & persistence

Every non-plain event has a metadata blob persisted by **`eventMeta`**, keyed by
the take's **pool guid** (its `POOLEDEVTS` source identity), not the take. mm
derives that guid from the item chunk on take-swap and caches it (`poolGuid`).

Keying by pool rather than take is load-bearing. Pooled instances share one MIDI
source — and therefore the in-stream uuid sidecars — but each is a *separate*
take with its own ext-data. Storing the blob per take let a pooled sibling (or a
parked survivor of a delete) keep the uuid yet lose the metadata; keyed by pool,
every instance resolves the one blob. See docs/eventMeta.md for the model and
storage shape.

UUIDs are monotonic integers, base-36 encoded; the namespace is unified across
notes and ccs, and is per-pool — the sidecars that carry them ride the pool.

### Plain ccs — identity without persistence

Every event mm hands out carries a uuid. Not every event carries one *durably*: a
cc that nothing has ever tagged is **plain**, and its uuid is minted in memory,
re-minted on every load, and written nowhere.

The split is the point. A uuid that persists costs a `}RDM` sidecar in the take
and an `eventMeta` bucket in the project. That price is worth paying for anything
a user authored and expects to survive a round trip, and worth paying for nothing
else — and "nothing else" is most of a dense pb stream. `rebuildPbs` resynthesises
absorber seats wholesale every rebuild and recognises the last rebuild's by
*window*, not by id (docs/trackerManager.md § Route-by-window). Those seats want to
be plain native MIDI, and they are.

What they still need is to be addressable while they live. Identity and
persistence used to be a single decision — a cc got a uuid exactly when it got a
sidecar — so a markerless seat had no handle at all, and could only be named by
content-keyed token. Separating them costs one table store per event and buys a
single addressing scheme across everything mm holds.

Hence the invariant: **plain ⟺ no sidecar in the take**. It round-trips by
construction rather than by bookkeeping. Load *derives* `plain` from what it
observes — a cc that bound no sidecar is one — and `plain` is itself a structural
field, so it can never ride a metadata blob and contradict what the take says.
The first metadata write promotes: `plain` clears, `flushTake` emits the sidecar,
and the uuid is durable from that moment. Promotion is one-way, and it takes the
lock even when nothing structural changed, because it inserts an event into the
take.

The mint itself happens at the end of `load`, after every persisted uuid has
been read (`maxUUID`) — so a fresh in-memory mint can never collide with one
still arriving from the sidecar sweep.

The rule this puts on callers is the obvious one: **nothing may hold a plain cc's
uuid across a reload**. It will resolve — to a different event, or to nothing.

### Metadata I/O

`load` reads the pool's metadata once, up front (`eventMeta:load(poolGuid)`),
and joins it onto the events it parses — at sidecar binding, and again in
`rebuild`. It never *edits* what it read. The store's bytes flow onto the event
records and no further, which means that for every uuid that survives the load,
the store is already correct and there is nothing to write back.

Two things do change, and they are the whole of what `load` persists:

- **The reassignment clones.** When two notes claim one uuid, the loser is
  minted a fresh one and the metadata is cloned onto it. That entry is new; it
  goes out. A note minted a uuid from *nothing* (a foreign note, no sidecar) has
  empty metadata, and an empty entry is indistinguishable from an absent one —
  so it is not written at all.
- **The deaths.** Every uuid the store knows about that no surviving event
  claims: dedup kills, orphaned sidecars, the losers of a reconcile. Swept.

This used to be an `eventMeta:saveAll` — the entire pool rewritten on every
load, O(all uuids), whatever had changed. It was doubly wasteful. On a foreign
bind it wrote 33 buckets of *empty* field tables (~30ms), which the rebuild
pipeline then superseded outright a few milliseconds later when it stamped
`ppqL` onto all 10k events and rewrote all 40 buckets. Worse, those 33 buckets
now **existed**, so `eventMeta:flush` had to read-modify-write each one rather
than write it fresh — load's redundant write made the real write more expensive
than it needed to be. Persisting only the delta leaves a foreign pool's bucket
index empty, and the pipeline writes each bucket exactly once.

### Index re-read elision

After the first read pass, `load` would re-read every note, cc and sysex
a second time to refresh `idx`/`uuidIdx`. That pass exists only because
two in-load steps mutate the take and re-sort it — note dedup and the
sidecar-reconcile flush — shifting every event's REAPER index out from
under the first read. When neither fires (`takeDirty` stays false) the
take is identical to when `load` began, the first-pass indices still
hold, and the whole re-read is skipped. Self-inflicted reloads are always
clean, so this elides the second `MIDI_GetNote` sweep on every keystroke;
foreign-MIDI / undo loads that need fixups still pay it.

### Converged load — the rebind gate

The third elision, and the one that pays at bind rather than at keystroke.
Re-binding a take Continuum itself last wrote — leave the tracker page, come
back — re-read and re-parsed a blob that could not have changed, and handed tm
a `wholesale` reload, which tm reads as "every event object is new" and answers
by marking all 16 channels dirty. A converged take then paid a full derivation
pass to stage exactly zero writes.

So mm keeps `loadedBlob`: the take's bytes as of the last moment its model
agreed with them, stashed by `flushTake` (re-read *after* `MIDI_Sort`, since
REAPER's canonical encoding need not be the one we handed it) and by a clean
`load`. A `load` of the same take whose bytes still equal it re-reads nothing —
and since nothing was re-parsed, no event object was replaced, so the reload it
fires is **not** wholesale and carries an empty dirty set. tm keeps its
incremental index and carries its whole frame. The signal still fires, because a
rebuild must run to consume dirt marked while the page was away.

The blob, not a hash: a pure-Lua digest over a few hundred KB is not obviously
cheap, `MIDI_GetHash`'s coverage of text events is not something to bet
correctness on, and Lua string equality is a memcmp. The cost is one retained
string per bound take.

What the bytes *don't* cover has to be invalidated by hand. `eventMeta` lives
outside the blob, so a metadata-only undo (`poolsRewound`) moves derivation
inputs with the take untouched: that subscriber drops `loadedBlob` before
reloading. The take's *length* needs no such care — REAPER's end-of-track marker
is an event in the blob, so a resize moves the bytes (see trackerManager.md §
Length operations).

### Notes — notation-event carrier

Every note carries a UUID stored as a REAPER **notation event**
`NOTE <chan> <pitch> custom ctm_<base36uuid>`, co-located with the note at
the same ppq. UUIDs are universal: every note gets one on load whether or not
it carries metadata.

On load, duplicates, missing UUIDs, and collisions are reconciled:
1. Scan notation events into `noteSidecars`, bind to notes by tag, and join
   each bound uuid's metadata onto its note. Binding is collision-aware —
   notes and sidecars bucket by `(ppq, chan, pitch)` and pair off in order —
   and runs ahead of dedup so the voicing verdicts see intent (`ppqL`,
   `detune`, `derived`).
2. Dedup same-`(ppq, chan, pitch)` notes via `voicing.resolveGroup` (see
   `docs/voicing.md`): true duplicates are killed (foreign MIDI, carrying no
   intent, degrades to keep-the-longest); distinct voices are nudged apart
   rather than eaten. Kills fire `notesDeduped`, nudges `collisionsResolved`.
3. Any note with a shared UUID is reassigned a fresh one (metadata cloned);
   any note without a UUID gets a new one and a queued notation-event insert.
   Notation events that didn't claim a note (no surviving note at that tag, or
   a duplicate at a tag already claimed) are queued for deletion.
4. All sysex mutations — set/delete/insert — flush in a single bracketed pass
   alongside the cc dedup deletes and reconcile rewrites. A closing read pass
   refreshes `idx` and `uuidIdx` on the surviving entries.

### CCs — sidecar-sysex carrier (sidecar-on-touch)

CCs (and the cc-family events `pa`/`pb`/`pc`/`at`) acquire a UUID **only when
metadata is written**. Plain automation streams stay free of overhead until
Continuum touches them.

The carrier is a coincident sysex with a Continuum magic prefix
(`F0 7D 52 44 4D ... F7` on disk; `7D 52 44 4D ...` body when handled via
`MIDI_*TextSysexEvt(... type=-1 ...)` — REAPER frames it). The body encodes
`(uuid, msgType, chan, [cc|pitch], val)` so the carrier can re-bind to its
event at load time even after drift.

Sidecars sit alongside ordinary sysex but are routed to an internal
`sidecars` table during load — Continuum only surfaces notes and CCs to its
upper layers, so plain sysex/text events have no public accessors.

**Reconciliation (load-time).** Sidecars don't have a REAPER-side anchor to
their target the way notation events have to notes, so matching has to handle
drift. The reconcile pass runs four stages, each rebucketing the still-unbound
sidecars and ccs by a key chosen for that stage's notion of "same" — finer
early, coarser late. A uuid can't migrate to a different controller, so
`(msgType, chan, id)` is always part of the key. Bound pairs are spliced
out of the working sets so the next stage's buckets are automatically
clean. Bias is to keep metadata attached to *something* and route
uncertainty via the `ccsReconciled` signal — silent loss is worse than a
flagged guess.

1. **Stage 1 — exact.** Bucket by `(msgType, chan, id, ppq, val)` and
   pair off. Catches everything that moved as a unit (glue, item shift).
   Silent — bind only, no event and no sidecar rewrite.
2. **Stage 2 — value-drifted.** Bucket by `(msgType, chan, id, ppq)` and
   pair off; val may differ. Catches an external value-edit that didn't
   move the cc. Emits `valueRebound` with `oldVal`/`newVal`.
3. **Stage 3 — consensus offset.** Bucket by `(msgType, chan, id)`.
   Histogram offsets implied by every (sidecar, candidate) pair. If a unique top
   vote-getter passes the threshold (≥ 50% of bucket sidecars, minimum 2
   voters), apply that offset across the bucket. Emits `consensusRebound`
   per bind. Catches the common "user dragged a group of ccs in REAPER's
   editor" case (selection is per-event-type, so sidecars stay behind while
   ccs move uniformly).
4. **Stage 4 — per-orphan.** For each remaining sidecar, count candidates
   left in its bucket: 0 → `orphaned`, 1 → `guessedRebound`, ≥2 →
   `ambiguous`. Multi-candidate ambiguity drops the metadata rather than
   guessing — better to surface a flagged loss than attach metadata to a
   provably-wrong event.

After binding the bound cc gets `uuid` and `uuidIdx` (the sysex index of its
sidecar); metadata from `ctm_<uuid>` is merged onto the cc just like for
notes. Non-silent binds (stages 2-4) also rewrite the sidecar's ppq + body
so the next load is stage-1 silent. Sidecars unbound after reconcile
(orphaned / ambiguous) are deleted from the take and their `ctm_<uuid>`
ext-data is purged by the stale-key sweep.

**Dedup (pre-reconciliation).** ccs are dedup'd by `(ppq, chan, msgType,
id)`. Survivor in each group is picked to match what reconciliation will
do next:

1. **Prefer stage-1 candidates.** A cc is a stage-1 candidate if some
   sidecar exists in the same `(msgType, chan, id)` bucket at the same
   ppq with matching val — i.e. the reconciler would bind to it silently.
   If any group member is a candidate, the survivor comes from that
   subset.
2. **Tiebreak by highest loc.** Within the preferred subset (or the whole
   group if no candidates), the latest-loc cc wins.

Sidecars are not touched at this stage. A sidecar whose preferred cc has
just been dropped — or that never had one — flows through reconciliation
as a `valueRebound` / `consensusRebound` / `guessedRebound` / `ambiguous`
/ `orphaned` event, and the post-reconcile cleanup deletes orphan
sidecars. `load`'s metadata sweep (§ Metadata I/O) purges any entry
left behind. Emits `ccsDeduped` with one event per
group; running before reconciliation means dedup has no uuid attachments
to report, so the event no longer carries `keptHadUuid`.

## Mutation contract

All write paths (`add*`, `delete*`, `assign*`) must run inside `mm:modify(fn)`.
`modify` runs `fn` under a lock, rebuilds the in-memory model, projects it onto
the take as one whole-take blob (`flushTake`), then reloads (which fires
callbacks). Calling a mutator outside `modify` raises.

**One write per gesture.** `modify` is re-entrant: `reload` fires `tm:rebuild`,
which reseats absorber pitch-bends by calling `mm:modify` again. A naive flush
per `modify` would then rewrite the whole take twice for any detuned gesture.
Instead the flush is deferred — a dirty `modify` at any nesting level sets a
shared `flushPending`, and only the outermost unwind (`modifyDepth == 0`) calls
`flushTake`, *after* `reload` has settled so the reseat is already in the model.
`flushMetadata` (a whole-blob `eventMeta` ext-state round-trip) coalesces the
same way: `metaDirty`/`metaDeleted` reset only at the outermost entry, so nested
modifies accumulate into them and the flush runs once at the unwind — safe
because nothing reads project ext-state mid-modify.

**Reindex deferral.** `rebuild` used to run inline on every dirty `modify`,
including the nested reseat pass. That reindex is deferred the same way as the
flush: only `modifyDepth == 0` pays for the one reindex, after the nested
reseat's writes have landed. Callers inside a nested `modify` — the reseat pass
included — see sparse/unsorted arrays until that unwind; nothing in the pipeline
reads position-dependent state mid-modify, so this is safe for the same reason
the flush deferral is.

**The reindex gate.** Dirty is not the same as stale. `needsSort` and
`needsCompact` describe the *arrays*, not the write: an add or a `ppq` move
leaves them dense but out of order, a delete leaves a hole, and an assign
touching neither leaves them exactly as they were — so the unwind skips the
reindex outright. (`pitch` and `chan` are in the content key but not the sort
key; `endppq` is in neither.) The skip makes the verbs' own index maintenance
load-bearing where a from-scratch `rebuild` used to launder it: `mm:assign`
re-keys `collisionIdx` in place and brackets a chan move with `indexDrop` /
`indexPut`. The two mutators that write outside the verbs — `resolveCollisions`
and load's dedup — set both flags themselves. See
design/archive/incremental-rebuild.md § 6.

**Same-pitch backstop.** `tm`'s separation sites uphold the `(ppq, chan,
pitch)` invariant in steady state; `resolveCollisions` catches any write path
that missed. Verbs (`addNote`, `assignNote`) record a pending collision by
`(chan, pitch)` instead of resolving inline — mid-batch collisions can be
transient, and resolving early would nudge a note a later verb was about to
move. The outermost unwind (`modifyDepth == 0`) resolves once, after all
nested writes have landed, via `voicing.resolveGroup`, then fires
`collisionsResolved` so `tm` can re-key its `um` surgically without
re-entering `mm:modify` mid-unwind.

**Metadata-only carve-out** (parallel for notes and stamped ccs):
- `assignNote(loc, t)` where `t` touches none of `ppq, endppq, pitch, vel,
  chan, muted` writes straight to extension data and skips the lock.
- `assignCC(loc, t)` where `t` touches none of `ppq, msgType, chan, cc, pitch,
  val, muted, shape, tension` *and* the cc already carries a uuid does the
  same. The "already carries a uuid" condition matters: the **first** metadata
  stamp on a plain cc inserts a sidecar sysex, which is a structural mutation
  and so requires the lock.

A structural assignCC on a uuid'd cc also rewrites the sidecar's position and
fingerprint bytes so the next load is stage-1 clean. `mm:delete` removes the
sidecar in the same shot as the event — a note's notation cascades with
`MIDI_DeleteNote`, a cc's sidecar is deleted by its tracked `uuidIdx` — then
replays the resulting wire-index shift on every surviving record so later
writes in the same `modify` stay addressable (see § Sidecar index
maintenance).

`addCC(t)` mirrors the lazy-sidecar pattern: if `t` carries any non-structural
key it allocates a uuid + inserts a sidecar in the same shot. Plain ccs
(no metadata) skip the allocation entirely. Symmetric with `addNote`'s
unconditional uuid, but lazy — most ccs never need one.

### Live-edit note release

While the transport is playing, `flushTake`'s whole-take `MIDI_SetAllEvts`
swaps the event data but leaves REAPER's playback engine indexing the *old*
event layout. When play reaches the tick where the edit reordered events, the
stale cursor treats what sits there as already-processed and swallows it: a
held note's note-off never fires (it hangs until the loop) and a simultaneous
note-on is dropped (it never sounds). With more voices in flight, *every*
boundary note-off is swallowed and exactly one note-on with them. The blob
itself is correct — `MIDI_GetAllEvts` reads it back byte-identical; only
REAPER's internal cursor is stale.

`MIDI_Sort(take)` immediately after the write repairs it: it forces REAPER to
rebuild its playback index against the new layout, so no boundary event is
swallowed. The interaction is undocumented — the API lists `MIDI_Sort` only for
`MIDI_SetNote`/`MIDI_SetCC` batches — but verified against REAPER, and the blob
is provably unchanged by the sort. This replaced an earlier per-event
`releaseStrandedNotes` pre-release, which only covered *dropped* note-offs (and
cut held notes short); the sort fixes stranded offs and dropped ons alike, at
any play position, with no per-event write.

tm still clears anticipative FX (`I_PERFFLAGS &2`) on the bound track while
editing, restoring the prior on unbind/quit (see docs/trackerManager.md §
Anticipative-FX guard). The old frontier rationale is gone, but the guard stays
deliberately: REAPER's own MIDI editor disables anticipative FX while open, so
this keeps tracker editing consistent with the native editor.

### Sidecar regeneration cache

`flushTake` rewrites the whole take (`MIDI_SetAllEvts`) on every mutation, so it
regenerates the sidecar text stream from scratch each flush. Encoding every
notation/cc sidecar and allocating a record per event is O(all events) — the bulk
of a large take's flush cost. But an event's encoded sidecar only changes when a
field feeding its body changes (note: chan/pitch/uuid; cc: evType/chan/id/value/
uuid), which a gesture rarely touches across the whole take. So each uuid'd event
caches its sidecar record, keyed weakly on the event object: a hit reuses the
record (only `ppq`, which places but doesn't encode the sidecar, is refreshed); a
miss re-encodes. `rebuild` reuses event objects in place, so the cache survives a
modify; `load` mints fresh objects, so it self-resets, and the weak keys let rows
for deleted events fall away with them.

## Sidecar index maintenance

Notation sidecars (type 15) and cc/pb sidecars (type -1) share one
`MIDI_*TextSysexEvt` index space. Every note and metadata'd cc caches the wire
index of its own sidecar as `uuidIdx`, so a structural write addresses that
slot directly — no content scan.

That directness is only safe if `uuidIdx` tracks the wire shifts a `modify`
causes. Deleting a note runs `MIDI_DeleteNote`, which cascade-removes the
note's notation and shifts every higher text-sysex index down by one — across
*both* arrays, since they share the space. `shiftSysexDown(threshold)` replays
that decrement on every surviving `uuidIdx`; the explicit `MIDI_DeleteTextSysexEvt`
on a cc delete shifts identically.

**Why it's done this carefully.** This index existed before, was ripped out,
and had to be restored. `becdcd8` dropped the `shiftSysexDown` maintenance;
without it a delete left every later `uuidIdx` pointing one slot high, so the
next structural write in the same modify landed on a neighbour's notation,
stamping it with the wrong note's uuid. On the closing reload the clobbered
note matched no notation, minted a fresh empty-metadata uuid, and silently lost
its detune (the 19EDO repro pinned by `mm_note_cascade_sidecar_spec`). `7bc5d6d`
worked around the breakage by abandoning uuidIdx-direct writes for a content
rescan of the whole text stream once per note — correct, but O(n²), and the
dominant cost of editing a group with many instances. Restoring the shift makes
the direct write safe again, collapsing that scan back to O(1) per write. Two
specs guard the pair: `mm_note_cascade_sidecar_spec` (delete path) and
`mm_delete_then_sidecar_write_spec` (write path).

## Signals

mm fires up to seven kinds of signal per `load`. Subscribers register per
kind and receive only the payloads of that kind.

```
'takeSwapped'      data = nil                                -- only when load received a different take
'notesDeduped'     data = { events = [{ ppq, chan, pitch, droppedCount }, ...] }
'uuidsReassigned'  data = { events = [{ oldUuid, newUuid, ppq, chan, pitch }, ...] }
'ccsReconciled'    data = { events = [...] }                 -- omnibus: see below
'ccsDeduped'       data = { events = [{ ppq, chan, msgType, cc, pitch, droppedCount }, ...] }
'collisionsResolved' data = { events = [{ kind, uuid, chan, pitch, ppq }, ...] }
'reload'           data = { wholesale }                      -- every load; true iff full re-read
```

`collisionsResolved` events carry `kind = 'killed' | 'nudged'` and name the
affected voice by `uuid` — a nudge moves the voice but never re-keys it. The
signal also fires outside load, from `modify`'s outermost unwind, when the
same-pitch backstop repaired a missed collision (§ Mutation contract).

`ccsReconciled` events come in five kinds. The shared fields are `kind`,
`uuid`, `chan`, `msgType`, and (per msgType) `cc` or `pitch`. Per-kind extras:

```
{ kind = 'valueRebound',     ppq,     oldVal, newVal }   -- stage 2
{ kind = 'consensusRebound', ppq,     offset }           -- stage 3
{ kind = 'guessedRebound',   ppq }                       -- stage 4
{ kind = 'ambiguous',        candidateppqs = {...} }     -- stage 4 (no bind)
{ kind = 'orphaned',         lastppq }                   -- stage 4 (no bind)
```

`ppq` on the rebind kinds is the bound cc's ppq (where the metadata now
lives). `lastppq` on `orphaned` is the sidecar's own ppq (where the cc
*was*); orphaned/ambiguous events have no bound cc to point at. A
subscriber that wants only the data-loss subset filters on
`kind == 'orphaned' or 'ambiguous'`.

Firing rules:
- Order on a single load is `takeSwapped` → `notesDeduped` →
  `uuidsReassigned` → `ccsDeduped` → `ccsReconciled` →
  `collisionsResolved` → `reload`.
  Subscribers handling reconciliation/dedup see the events before the
  baseline rebuild. `ccsDeduped` precedes `ccsReconciled` because the
  reconciler runs over an already-deduped cc list — orphans (sidecars
  whose preferred cc was just dropped) surface as proper reconcile
  events rather than silent dedup losses.
- Reconciliation/dedup signals fire only when at least one event of that
  kind is present — no zero-event calls.
- `mm:modify` triggers a reload internally on exit, so every successful
  mutation produces a `'reload'` fire (with no `takeSwapped`).

## Conventions

- **mm holds the realisation frame** — REAPER's storage frame, with
  per-note delay already baked into the note-on ppq. See
  `docs/timing.md` for the three-frame model and where conversion
  happens (tm).
- **mm holds raw pb only.** No notion of detune or cents — the
  cents↔raw conversion and the fake-pb absorber pattern live in tm.
  See `docs/tuning.md` for the detune-as-intent / pb-as-realisation
  split.
- **Channels are 1..16 internally**, offset by +1 from REAPER's 0..15. All
  getters return 1-indexed; all setters shift back on write.
- **Pitchbend is centred on 0**, range -8192..8191. Stored on the wire as
  `(val + 8192)` split LSB/MSB into msg2/msg3.
- **`muted` is true-or-absent**, never stored as `false`. Callers pass
  `muted=false` to clear; `util.REMOVE` is not supported (REAPER-native flag,
  not metadata).
- **Locations are not stable across reloads.** They're 1-indexed snapshots of
  REAPER event order at load time. Don't cache a loc across a `modify`.
- **Accessors return shallow clones** with `idx`/`uuidIdx` stripped
  (`INTERNALS`). Mutating the returned table has no effect — write via
  `assign*`. Never interleave iterators with mutations; collect first.

## CC encoding

REAPER packs CC-family events into `(chanmsg, msg2, msg3)`. `reconstruct()`
fans this out by `msgType`:

| msgType  | msg2           | msg3           |
|----------|----------------|----------------|
| `cc`     | controller     | value          |
| `pa`     | pitch          | value          |
| `pc`/`at`| value          | 0              |
| `pb`     | (val+8192) lo7 | (val+8192) hi7 |

Shape codes follow REAPER's `MIDI_SetCCShape`: `step, linear, slow,
fast-start, fast-end, bezier` → 0..5. `tension` is only meaningful for
`bezier` and is cleared when the shape moves away from it.

## 14-bit CCs

A CC in controller codes 0..31 carries 14-bit resolution: the high 7 bits
ride the code, the low 7 bits ride `code+32` (REAPER's convention, matching
the MIDI spec's coarse/fine controller pairs). Continuum makes this
invisible above the wire — **the value's type is the whole signal**. mm
stores one record with a possibly-fractional `val`; the split/coalesce lives
entirely in the wire codec (`midiBlob`):

- **serialise** — a `cc` in 0..31 with a fractional `val` emits two wire
  events: MSB `floor(val)` on the code (carrying the authored shape/tension),
  LSB `round(frac*128)` on `code+32` (always `step`). An integer `val` stays
  one plain 7-bit event.
- **parse** — a `cc` in 0..31 with a coincident `cc+32` at the same
  `(chan, ppq)` coalesces to one record, `val = msb + lsb/128`; the MSB keeps
  shape/tension, the LSB folds in and drops.

There is no registry and nothing to arm: a value is wide because it is
fractional, not because a code was marked. Carriers (the only 14-bit
producers, all in 0..31) get this for free by writing `(8192+raw)/128`.

Pairing is positional, so a hand-authored or foreign coincident
`code`/`code+32` pair on codes 0..31 is read as one 14-bit value rather than
two independent lanes — accepted, as those codes are the MIDI-spec fine
partners and Continuum owns them.

## Text / sysex events

Continuum reads two text-event types and ignores the rest:
- Notation events (REAPER type 15) matching the `ctm_<uuid>` pattern bind
  to their note via `note.uuidIdx`.
- Sysex events (REAPER type -1) whose body starts with the Continuum magic
  (`}RDM`, `7D 52 44 4D`) are cc sidecars and feed the `sidecars` table.

Everything else passes through untouched — Continuum neither surfaces nor
mutates plain sysex/text events.

## LUT discipline

Name→code LUTs are declared canonically; the inverse (`chanMsgTypes`,
`shapeNames`) is derived in a loop so the two directions can't drift.
`chanMsgLUT` and `BASE36`/`toBase36`/`fromBase36` are hoisted to module
scope so they're shared across helpers without drift.

## Sidecar wire format

`}RDM <typeNib> <chan> <id> <val_lo7> <val_hi7> <uuid-base36>` where
`typeNib` is the chanmsg high nibble (0xA..0xE) and `id` is the controller
for cc, pitch for pa, 0 for pb/pc/at. REAPER frames with `F0`/`F7` on
serialise. Encode/decode live as private closures inside `newMidiManager`;
reconcile is a `do`-block in `mm:load`.
