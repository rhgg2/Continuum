# Intent and emission — the frame as a take's intent

> opened: 2026-09-26 · status: in flight — plan/intent-emission.md, phase 5 (continuous seats).

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

Moved to `docs/trackerManager.md` § Two movements, § CC walk and § Realisation by host.

## Reading intent

Moved to `docs/trackerManager.md` § Two movements.

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

1. A seat the previous census covers and the pass's own set does not is an **orphan**, and fx
   expansion deletes every orphan, pb and cc alike. The length verbs retire seats by the same diff,
   taken between the stored census and its mapped image (`docs/trackerManager.md` § Length
   operations).

1. A pb orphan's delete seeds the pb stream, since the absorbers its value held into reseat against
   the stream that now prevails there. A cc orphan seeds nothing, since no value is computed against
   a cc seat.

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

1. **PAs ahead of a delayed note-on.** A PA belongs to the note whose logical span covers it
   (`docs/trackerManager.md` § PA binding), yet it realises at its own seat, with no delay. A delay
   reaches 9999 millibeats, so a host's PAs on the rows before its delayed note-on reach the take
   before its voice exists. The lead candidate is the prevailing value — the last such PA realises
   at the note-on, and those before it do not sound. A PA seated off `fromLogical(ppqL)` meets the
   rebuild rule (`docs/timing.md` § Rebuild rule), which reads the divergence as stale swing.
