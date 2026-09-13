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

- 2026-09-13 tm: seat absorbers against the base voice, not lane 1 (§ The base voice)
- 2026-09-13 tm: carry baseVoice across the fx pass (§ The derived note record)
- 2026-09-12 generators: stamp baseVoice on every derived note (§ The base voice)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

4. **The hold scope asks the generator** — `emitsBaseVoice` (renamed already,
   predicate unchanged) becomes a real base-voice test: a stage that parks notes over a host whose inbound
   membership holds a base voice, widening `pbHoldFrom` to the host's window
   start as it does now. Spec: a higher-lane note host's retrig leaves the pb
   emit scope alone, a lane-1 one widens it.
