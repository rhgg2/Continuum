# Laneless derived notes — plan

> source: `design/laneless-derived-notes.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The base voice** (§ The base voice) — `baseVoice` on the
   derived record, set by the generator; the lane-1 union becomes a
   base-voice door the absorber walk and `index.detuneAt` share.  ← in flight
2. **Phase 2 — The display lane** (§ The display lane, § The freeze claim) —
   tv allocates a column per frame over the caret's host; the ghost overlay,
   the cents readout and the freeze rect's note streams read the one
   allocation.
3. **Phase 3 — The derived tail bound** (§ The derived tail bound) — a derived
   note's end clipped by same-pitch successor and host window end, with derived
   notes joining the tail walk's pitch dimension.
4. **Phase 4 — Laneless emission** (§ The derived note record) — `lane` off the
   emitted spec, `noteLive`, `fxNotesByHost` and the mm metadata;
   `allocateRegionLanes` retires with it.
5. **Phase 5 — Keep by omission** (§ Keep by omission) — the derived existing
   set gathered per touched host window, as `buildCcExistingInWindows` does,
   retiring the fx pass's explicit keep branch for notes.

Sequencing note: the display lane lands before lanelessness so no frame draws
ghosts or mints a freeze rect without a column to put them in; laneless
emission lands before keep by omission, whose per-window gather would leave a
lane allocator unable to see the notes it must avoid.

## Landed  (newest first; prune below ~4)

(nothing yet)

## Now

(empty)

## Queued (current phase; one-liners)

1. **`baseVoice` on generator output** — the note stages in `generators.lua`
   stamp `baseVoice` on every note they emit, inherited from the stream note
   the emitted note derives from: an inbound note is base voice when it carries
   `baseVoice`, and otherwise when its lane is 1, so a chained stage reads its
   predecessor's output. A chord stamp keeps the field on the voice displaced
   from the pattern's root and drops it on the other voices. Contracts on the
   stages; `generators_spec` covers the inheritance, a higher-lane host's output
   carrying none, and the chord's drop.
2. **The fx pass carries `baseVoice`** — the field rides `rebuildFx`'s predicted
   spec, `noteLive`, the `fxNotes` copy the tail walk clips, and the
   `fxNotesByHost` shape. It sits outside mm's `noteEventFields` strip, so a
   seated derived note holds it as metadata and answers for it on the next
   pass. Spec: an expansion's seated notes carry the field, and it survives a
   reindex.
3. **The base-voice door** — `lane1Union` becomes a base-voice door: authored
   lane-1 notes from the raw index unioned with the pass's base-voice derived
   output. `rebuildPbs`' gather and its `freshLane1` flag select `noteLive`
   entries by the field, `seatScope`'s onset seeds and `index.detuneAt` read
   the one predicate — authored means lane 1, derived means `baseVoice`. Spec:
   the door and `index.detuneAt` agree at an onset an authored and a derived
   note share.
4. **The hold scope asks the generator** — `emitsLane1Notes` becomes a
   base-voice test: a stage that parks notes over a host whose inbound
   membership holds a base voice, widening `pbHoldFrom` to the host's window
   start as it does now. Spec: a higher-lane note host's retrig leaves the pb
   emit scope alone, a lane-1 one widens it.
