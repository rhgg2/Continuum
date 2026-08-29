# voicing

**A policy module for which same-pitch collisions are duplicates and
which are distinct voices.** Two notes can land on one raw `(ppq,
chan, pitch)`; voicing says whether one dies or the two are separated.
It is a pure module with no state, and callers stage every midiManager
write themselves.

## The model

1. A MIDI channel sounds at most one note at a time at a given pitch,
   so two note-ons at the same raw `(ppq, chan, pitch)` are illegal.

1. Notes that collide on one raw onset need not be one voice. A note's
   **intent** is the step it was written on, and lives in the sidecar
   metadata. Two notes of distinct intent may collide by virtue of swing,
   delay or detune (`docs/timing.md`).

1. They must be separated: the successor moves to `prev.ppq + 1`, so
   each keeps its own onset, and with it its own pb absorber
   (`docs/tuning.md`).

1. A `fixed` external is never moved by `separateOnset`, so
   trackerManager's tail walk leaves it where it is. `fixed` is
   trackerManager's tag for a note it reintroduced but does not own
   (`docs/trackerManager.md` § Rebuild: externals).

1. A collision is a genuine duplicate when the notes carry the same
   intent, meaning equal `ppqL` and `detune`, or when one is a
   regenerable fxNote, marked `derived`, which always loses to an
   authored note.

1. Duplicates collapse to the longer note, preferring the authored
   `endppqL` to the raw `endppq`. Foreign MIDI carries no intent, so
   for it this degrades to keeping the longest simpliciter.

## Verdicts

1. voicing decides collisions for notes provided by a caller.
   `separateOnset` judges one pair; `resolveGroup` and `resolveSorted`
   walk a group already assembled.

## Ordering

1. The nudge cascade depends on the group arriving in `(ppq, ppqL)`
   order: each note gives way to its settled predecessor, and a note
   out of order gives way to the wrong one.

1. `resolveGroup` sorts the group in place before walking, so its
   caller need not arrive with one sorted.

1. `resolveSorted` is the same walk without the sort, and its contract
   names the order it requires.

## Enforcement layers

1. The invariant is midiManager's. Five sites enforce it: four on the
   path from an edit to the take, and one on the way back in.

1. **trackerManager's tail walk** separates during the rebuild, and so
   keeps trackerManager's live clones coherent
   (`docs/trackerManager.md` § Same-pitch onset separation). It is
   trackerManager's only separation site.

1. **trackerManager's flush collision scan** kills duplicates over the
   post-flush note set, inside `mm:modify`'s preflush
   (`docs/trackerManager.md` § Flush collision scan). Running before
   the commit allows this to happen within trackerManager.

1. **midiManager's write-path backstop** repairs whatever a write path
   missed, at the outermost `modify` unwind (`docs/midiManager.md`
   § Mutation contract). It should find nothing.

1. **midiBlob.buildWire** asserts the invariant and writes anyway,
   with a warning. A collision reaching the codec is a bug upstream,
   and the codec stays a pure bijection.

1. **midiManager's load-dedup** applies the verdicts to whatever
   arrives from the take. Metadata is reconstructed beforehand, so it
   sees intent, and an external collapse — an undo, or a foreign
   script collapsing two authored notes — can be separated.
