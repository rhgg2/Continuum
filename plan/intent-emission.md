# Intent and emission — plan

> source: `design/intent-emission.md` — synthesis compiled from there;
> don't design here.

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
   `frame.authoredPb`'s union and the per-channel `parked` table retire.  ← in flight
4. **Phase 4 — Cues and the realisation map** (§ Emission's output, § Reading intent) —
   `REALISATION` becomes the cue set with `parked` and pb `detune` in it, the realisation map's
   parked share covers every kind a host parks, and each emission stage reads um's index only for
   the previous emission.

## Landed  (newest first; prune below ~4)

- 2026-09-26 tm: sweep synthesised pcs outside tracker mode (design § Pitchbend and program change intent)
- 2026-09-26 tm: parked note hosts run their chain (design § Parking)
- 2026-09-26 tm: the CC walk projects the pb column as intent (design § Pitchbend and program change intent)
- 2026-09-26 tm: the pc column holds authored pcs alone (design § Pitchbend and program change intent)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **tm: fx expansion reads the pb base off the pb column** — `pbBaseFor` and `classifyHosts`'
   `baseIsDirty` read a channel's sounding pbs from its pb column, `val` as cents and logical ppq,
   rather than from um's index, so `isAuthoredPb` and the raw-span conversion of the pb cover
   retire. The parked list stays the base's other half until the next item. docs:
   `docs/trackerManager.md` § Span-covered fx scans, `docs/generators.md` § Offline continuous
   realisation. Spec: a host's pb base reads an authored pb's `val` at its logical onset under
   swing; a foreign pb enters the base on the pass that derives its cents; an edit to a column pb
   inside a host's window dirties its base.

1. **tm: seat parked pbs in the pb column under the parked flag** — pb joins `parkHomes`, so the
   stash seat takes parked pbs into the pb column flagged `parked`. `parkPbs` scans the pb column
   over every window on a dirty channel, as `parkCCs` does, parks a candidate in place, and restores
   by flipping its seat through `seatedOf`, writing raw and the cents sidecar back to mm. The
   created/removed window diff survives only to sweep a removed window's seats. `installParked`, the
   per-channel `parked` table and its carry at the pass head, and `frame.authoredPb`'s memoised
   union retire: `tm:authoredPb` answers the column's own events, nil where the channel has no pb
   column. `rebuildPbs`' detune stamp skips parked pbs, and `pbBaseFor` reads the column alone.
   docs: `docs/trackerManager.md` § The frame handle, § Lane occupancy, § Region-replace parking,
   § Span-covered fx scans; `docs/generators.md` § Route-by-window. Spec: a parked pb sits in its
   column flagged `parked`, carries no `detune` and is absent from mm; a pb typed into a standing
   window parks; a restore flips the seat in place and mm regains the pb with raw and cents; a clean
   pass carries the column's table; a parked pb keeps its column; fx expansion's base covers a
   parked pb.

