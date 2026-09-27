# Intent and emission — plan

> source: `docs/trackerManager.md`, `docs/generators.md` — the model
> this plan realised.

## Phases

1. **Phase 1 — PA intent** (§ Parking, § The stages) — the stash seat takes pas into their note lanes
   under `parked`, PA dispatch moves ahead of every emission stage, and `parkPAs` flips a pa in place
   off its host's lane rather than off um's index, so the `parked.pa` list retires. Landed 2026-09-26,
   1 commit.
2. **Phase 2 — pb and pc columns in the CC walk** (§ Pitchbend and program change intent 1–2, 4,
   § Emission's output 1–2, 4) — the CC walk projects the pb column with `val` as intent cents and
   the pc column with authored pcs alone, `rebuildPbs` stamps `detune` as a cue rather than
   projecting the column, absorbers and synthesised pcs leave the columns, and the `priorPb` carry
   retires. Landed 2026-09-26, 4 commits.
3. **Phase 3 — Parked pbs in the pb column** (§ Parking, § Pitchbend and program change intent 1)
   — the stash seat takes pbs into the pb column under `parked`, `parkPbs` flips a pb in place off
   the column rather than off um's index, and `pbBaseFor` reads the column alone, so
   `frame.authoredPb`'s union and the per-channel `parked` table retire. Landed 2026-09-26, 2 commits.
4. **Phase 4 — Cues and the realisation map** (§ Emission's output, § Reading intent) —
   `REALISATION` becomes the cue set with `parked` and pb `detune` in it, the realisation map's
   parked share covers every kind a host parks, and each emission stage reads um's index only for
   the previous emission. Landed 2026-09-27, 6 commits.
5. **Phase 5 — Continuous seats** (§ Continuous seats) — red first: freeze-to-group thins a cc curve
   as it thins a pb one (`tm_fx_region_spec`, beside "freeze to group: the dense curve re-seats
   sparse in one flush"). One seat test replaces `isPbSeat` and the CC walk's cc tag; fx expansion
   reads its existing cc side off the raw index by window, keeping the kept-host exclusion and the
   overlapper's scope clip; one census-diff sweep, shared with `retireUncoveredSeats`, replaces
   `parkPbs`'s pb sweep and the absent-host file sweep; cc leaves `HOST_FILED`. The docs transfer
   also corrects `docs/generators.md` § pb and cc ¶2–3, which predate pb parking. Landed 2026-09-27, 4 commits.

## Landed  (newest first; prune below ~4)

- 2026-09-27 tm: freeze adopts the absorbers inside its window as curve material
- 2026-09-27 tm: one seat test recognises pb and cc seats; synthesised pcs drop ppqL (design § Continuous seats 1–3)
- 2026-09-27 tm: seats reconcile by window, and orphans go by one census diff (§ Continuous seats 4–6)
- 2026-09-27 tm: PA dispatch seeks its covering note per lane, logically (§ Reading intent 2)
- 2026-09-27 tm: base-voice union and PC synthesis read intent through the seat stamp (§ Reading intent 3, § Emission's output 3)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)



