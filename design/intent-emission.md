# Intent and emission — the frame as a take's intent

> opened: 2026-09-26 · status: in flight — plan/intent-emission.md, phase 2 (pb and pc columns in the CC walk).

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

1. The **realisation map** carries emission's output to the view, keyed by host: the derived notes a
   host emits, the events it parks and the channels it realises on. The view renders a host's output
   from it, and a freeze reads from it the events its host parked.

1. Absorbers and synthesised PCs live in mm alone.

## Reading intent

1. The **previous emission** is the take in the realisation frame as mm now holds it: each authored
   event that sounds, and every derived event (`docs/timing.md` § The two frames).

1. Emission reads intent from the frame alone, and um's index only for the previous emission.

1. Emission reconciles its output against the previous emission — an absorber already seated, a
   raw onset already in place.

## Parking

1. **Parking** is emission's decision that an authored event does not sound. An event parks when a
   replace window owns it, or when its own fx chain replaces it (`docs/trackerManager.md`
   § Region-replace parking).

1. A parked event stays in its column — notes, pas, ccs and pbs alike.

1. A parked event's **spec** is the event minus its cues (`docs/trackerManager.md` § Park identity).

1. To park an event, emission sets `parked` on it in place, sheds its other cues, adds its spec to
   the stash and deletes it from mm.

1. To **restore** an event, emission clears `parked`, drops its spec from the stash and writes it
   back to mm with its realisation frame re-derived.

1. A parked event does not claim a medium. It does not bound an absorber's reach on lane 1, and the
   tail walk does not place a raw onset for it.

1. Reconstruction reseats a parked event from its spec on the next pass, flagged `parked`, so the
   seat equals the event that parked.

## Pitchbend and program change intent

1. The CC walk projects the pb and pc columns beside cc and at (`docs/trackerManager.md` § CC walk).

1. A pb event's `val` is its intent in cents, and `val + detune` is the cents it sounds.

1. Fx expansion reads a channel's pb base from its pb column, parked and sounding events alike
   (`docs/generators.md` § Offline continuous realisation).

1. A pb or pc column exists when it holds an event or `extraColumns` asks for it.

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

1. **Foreign pbs.** A pb with no cents sidecar has no intent in cents until emission back-derives it
   from raw and detune, so its event carries no `val` and the pb base leaves it out. Whether
   reconstruction can give it cents is unsettled.

1. **The pb park scan.** Parking looks for pbs to park only in windows created this pass. Whether it
   scans the pb column over every window, as it scans a cc column, is unsettled.
