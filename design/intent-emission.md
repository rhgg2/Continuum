# Intent and emission — the frame as a take's intent

> opened: 2026-09-26 · status: in flight — plan/intent-emission.md, phase 4 (cues and the realisation map);
> phase 5 (continuous seats) queued.

**The frame holds a take's intent — every authored event in its logical column, sounding or not. A
pass reconstructs that intent from mm and the stash, then emits the take from it; parking, fx
expansion, pb detune and absorbers all belong to emission.**

## The frame as intent

1. **Intent** is every authored event of a take, sounding or not, each seated in the logical frame
   in its column of `frame.channels`.

1. mm stores the intent that sounds. The **stash** — the `fxParked` ds key — stores the rest.

## Reconstruction

1. **Reconstruction** builds intent from mm and the stash. It projects each authored event in mm
   from um's index into its column (`docs/trackerManager.md` § Update manager (um), § Logical
   projection), and seats each event the stash holds in its column.

1. A wholesale read reconstructs the whole channel. Otherwise reconstruction covers only the spans
   the dirt journal names, and every other event carries (`docs/trackerManager.md` § Interval
   materialisation).

1. The dirt journal is thus the **diff** between successive intents. Each edit verb records the
   spans it changed as it stages its mm writes, and the next pass reads that record.

## Emission

Moved to `docs/trackerManager.md` § Two movements.

## Emission's output

1. Reconstruction writes an authored event's own fields, and emission writes only its cues. A
   **cue** is a field emission derives, carried on an authored event, and `REALISATION` enumerates
   the set.

1. `parked` is a cue, and so is a pb event's `detune` — the base voice's detune at its onset.

1. No cue reaches mm or the stash. Every write door sheds the cues, and a park spec is its event
   minus the cues and um's bookkeeping — `committed`, `colEvt`, `raw`, `cents` and `derived`.

1. The **realisation map** carries emission's output to the view, keyed by host: the derived notes a
   host emits, the events it parks and the channels it realises on. The view renders a host's output
   from it, and a freeze reads from it the events its host parked.

1. Where absorbers and synthesised PCs live moved to `docs/trackerManager.md` § CC walk.

## Reading intent

1. The **previous emission** is the take in the realisation frame as mm now holds it: each authored
   event that sounds, and every derived event (`docs/timing.md` § The two frames).

1. Emission reads intent from the frame alone, and um's index only for the previous emission.

1. A raw position is emission. A stage takes membership and intent fields from the columns, and an
   event's raw position by uuid from um's index.

1. The tail walk refines the sounding set the stages before it settled, so it reads that set from
   um's index.

1. Emission reconciles its output against the previous emission — an absorber already seated, a
   raw onset already in place.

## Continuous seats

1. A **continuous seat** is a pb or cc on the take with no `ppqL`, inside a window of the previous
   census (`docs/trackerManager.md` § Fx window census). One test recognises seats on both streams —
   `ppqL == nil` and `ownsRaw` over that census (`docs/generators.md` § Route-by-window).

1. A seat carries no name. `derived` holds a host uuid on a derived note, `'absorber'` on an
   absorber and `'pc'` on a synthesised pc, and a cc carries none. um's host file thus holds derived
   notes alone (`docs/trackerManager.md` § The host gate).

1. The CC walk leaves seats out of the columns. The wholesale path applies the seat test to each pb
   and cc, and the interval path matches its refills by `ppqL`, which no seat has.

1. Fx expansion reads a running host's existing cc seats off um's raw index — the seats inside its
   window in the pass's own set, per cc target. A clean overlapper's read is clipped to the emit
   scope, as its emission is, and a kept host's window is not read. The existing side of the cc
   reconcile is the union of those reads.

1. A seat the previous census covers and the pass's own set does not is an **orphan**, and the pass
   deletes every orphan, pb and cc alike. The length verbs retire seats by the same diff, taken
   between the stored census and its mapped image (`docs/trackerManager.md` § Length operations).

## Parking

Moved to `docs/trackerManager.md` § Region-replace parking, § Park identity and § Lane occupancy.

## Pitchbend and program change intent

Moved to `docs/trackerManager.md` § Span-covered fx scans, § CC walk and § PC synthesis.

## The stages

Moved to `docs/trackerManager.md` § The pipeline.

## Open

1. **Edits write intent.** tv's edit verbs write authored events into the frame directly, and the pass emits from the
   frame; reconstruction runs only on a wholesale read, undo included. This is the direction the
   model grows in, and it would retire most of interval materialisation and `colEvt` stamping. It
   costs the rule that only the pass writes `frame.channels` (`docs/trackerManager.md` § The frame
   handle), and the edit side's eager logical-to-raw translation.

1. **Raw rederivation under stale swing.** `rebuildInternals` and the CC walk rederive raw onsets
   from logical under stale swing. By this model that is emission; which stage takes it is
   unsettled.

1. **The column table's name.** `onTake` names the intent that sounds, and the columns hold all of
   it.

1. **The pattern editor's curve readback.** It reads `val + detune` off the pb column. Whether a
   readback of intent should include the cue is unsettled.
