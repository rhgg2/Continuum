# Laneless derived notes — plan

> closed: 2026-09-18 · the model it landed stands in `docs/trackerManager.md`,
> `docs/generators.md`, `docs/tuning.md` and `docs/trackerView.md`.

## Phases

1. **Phase 1 — The base voice** (§ The base voice) — `baseVoice` on the
   derived record, set by the generator; the lane-1 union becomes a
   base-voice door the absorber walk and `index.detuneAt` share. — landed
   2026-09-13, four commits.
2. **Phase 2 — The display lane** (§ The display lane, § The freeze claim) —
   tv allocates a column per frame over the caret's host; the ghost overlay,
   the cents readout and the freeze rect's note streams read the one
   allocation. — landed 2026-09-16, two commits.
3. **Phase 3 — The derived tail bound** (§ The derived tail bound) — a derived
   note's end clipped by same-pitch successor and host window end, with derived
   notes joining the tail walk's pitch dimension. — landed 2026-09-17, one
   commit.
4. **Phase 4 — Laneless emission** (§ The derived note record) — `lane` off the
   emitted spec, `fxOut.notes`, `fxNotesByHost` and the mm metadata;
   `allocateRegionLanes` retires with it, emission order carrying the
   determinism it carried. — landed 2026-09-17, two commits.
5. **Phase 5 — Keep by omission** (§ Keep by omission) — the derived existing
   set gathered in the fx stage, per running host's window, retiring the fx
   pass's explicit keep branch for notes. The existing-side half landed early on
   2026-09-16, at bucket rather than window grain: `fxIn.notes` arrives bucketed
   by producing host and a kept host's bucket is withheld, so the reconcile
   already passes over a kept host. — landed 2026-09-18, two commits.

Sequencing note: the display lane lands before lanelessness so no frame draws
ghosts or mints a freeze rect without a column to put them in; laneless
emission lands before keep by omission, whose per-window gather would leave a
lane allocator unable to see the notes it must avoid.

## Landed  (newest first; prune below ~4)

- 2026-09-18 tm: take derived anchors from um's index, not the gate (§ Keep by omission)
- 2026-09-17 tm: gather the derived existing set from um's per-host file (§ Keep by omission)
- 2026-09-17 tm: emit derived notes without a lane (§ The derived note record)
- 2026-09-17 tm: key the fx reconcile on the logical seat, match by multiset (§ The derived note record)

## Now

(empty — every phase is landed; the plan is ready to close.)

## Queued (current phase; one-liners)

(empty — no phase outstanding.)

