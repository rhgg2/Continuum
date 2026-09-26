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
   `frame.authoredPb`'s union and the per-channel `parked` table retire. Landed 2026-09-26, 2 commits.
4. **Phase 4 — Cues and the realisation map** (§ Emission's output, § Reading intent) —
   `REALISATION` becomes the cue set with `parked` and pb `detune` in it, the realisation map's
   parked share covers every kind a host parks, and each emission stage reads um's index only for
   the previous emission.  ← in flight

## Landed  (newest first; prune below ~4)

- 2026-09-26 tm: seat parked pbs in the pb column under the parked flag (§ Parking)
- 2026-09-26 tm: fx expansion reads the pb base off the pb column (design § Pitchbend and program change intent 1)
- 2026-09-26 tm: sweep synthesised pcs outside tracker mode (design § Pitchbend and program change intent)
- 2026-09-26 tm: parked note hosts run their chain (design § Parking)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **`REALISATION` is the cue set** (§ Emission's output 1–2) — `parked` and a pb's `detune` join
   `REALISATION`, keyed by kind so a note's `detune` stays authored, and the separate `CUES` table
   retires. `toParked`, `parkInPlace` and tm's write doors — which shed `parked` by hand at
   `trackerManager.lua` ~932, ~956, ~990 — all shed the one set, so the set moves where both modules
   reach it. Spec: a parked pb's spec and a write-door clone of a parked cell carry no cue.
1. **The realisation map's parked share covers every kind** (§ Emission's output 3) — `parkPAs`,
   `parkCCs` and `parkPbs` bucket their parks by host into `parkedByHost`, as `parkNotes` does. The
   freeze reads its drop set off its entry's parked share by `parkKey`, so its `covered()` and
   `hostDropped` re-derivation over the stash retires. The view's `fx.parked` readers take the notes
   they want. Spec: a freeze of a cc-replace and a pb-replace region restores exactly the events
   the entry names, and a pa under a dropped host goes with it.
1. **Absorber reconciliation reads the authored pb stream off the pb column** (§ Reading intent
   2) — `realPbs` and `seatScope`'s `bpSpan` read the column's sounding events, `val` as intent
   cents and raw position by uuid off um's index, and the `detune` cue is stamped by iterating the
   column rather than through `entry.colEvt`. um's index serves only the seats. Spec: an absorber
   pass over a channel with parked and sounding pbs matches a full re-derive.
1. **The frame holds each channel's fx hosts** (§ Reading intent 2) — parked and sounding, kept
   current at the column writes. `onTakeFxHosts`, `buildFxWindows`, `enumerateHosts`, and the view's
   `tm:eachParkedHost` readers (cell-kind tags, `parkedByUuid`) read it, so none walks every lane.
   This repairs the O(channel) floor 4d87774b reintroduced when `frame.parkedNotes` replaced the
   parked list, and `index.fxHosts` retires with no emission reader left. Spec: the set equals a
   lane scan across seat, park, restore, fx toggle and wholesale reload.
1. **The base-voice union and PC synthesis read note intent off the lanes** (§ Reading intent 2)
   — `baseVoiceUnion` takes base-voice membership and detune, and `rebuildPCs`/`pcSeedSpans` take
   `lane` and `sample`, from the column events, with raw positions by uuid off um's index. The tail
   walk keeps reading um's index: it refines the sounding set the stages before it settled. Spec:
   gated passes match a full re-derive for detune and sample edits under a parked host.


