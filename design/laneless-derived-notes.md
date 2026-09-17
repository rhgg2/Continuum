# Laneless derived notes — one shape for derived reconciliation

> opened: 2026-09-12 · status: in flight — plan/laneless-derived-notes.md,
> at phase 3 (the derived tail bound).

**Derived notes carry no lane, so they reconcile as derived ccs do: gathered per touched window and kept by omission.**

## The derived note record

1. A derived note carries no lane. The uuid of the host that produced it names its origin.

1. Generator output is laneless at the point of emission. The lane on the `notes` shape belongs to its inbound half, the authored members a monophonic stage reads (`docs/generators.md` § Input streams).

1. The fx spec, `noteLive` and `fxNotesByHost` carry the record forward unchanged.

1. A lane is metadata to midiManager, which names only the (chan, pitch) voice group. A derived note's metadata carries none.

## The base voice

Landed. The model stands in `docs/tuning.md` § Intent vs realisation and
`docs/generators.md` § Output.

## The derived tail bound

1. A derived note ends at the end its generator gave it, clipped by two bounds.

1. The same-pitch successor is the nearest note of that pitch on the channel, authored or derived. It is the take's own constraint: midiManager resolves voices by (chan, pitch), and two same-pitch notes overlapping on a channel make one voice with two onsets.

1. The host window end is the second. A derived note sounds within the window that produced it.

1. Both terms come from the note, its host and the channel's pitch probe, so the bound is exact from local reads. A derived note takes part in the tail walk's pitch dimension.

1. Freeze promotes a derived note with that bound as its authored ceiling. A promoted note is authored, and the lane bound governs it from then on, so the ceiling it carries over is the one it sounded to.

## Keep by omission

1. A derived note enters a pass when the dirt touches its host's window.

1. The gather is per window, as the cc gather is (`docs/trackerManager.md` § CC walk). A channel's derived existing set holds the output of the hosts the dirt reached.

1. A host the dirt leaves alone contributes nothing to the pass. Its output stands in no existing set and in no predicted set, so the reconcile passes over the host entirely, and its notes survive the pass untouched. This is **keep by omission**.

1. The channel's authored notes reach the pass by seeking to the seeded rows.

## The display lane

Landed. The model stands in `docs/trackerView.md` § Ghost sampling.

## The freeze claim

Landed. The model stands in `docs/trackerView.md` § Ghost sampling.

## Open

1. Whether a generator may set `baseVoice` on more than one note sounding at once, and what the absorber seats if two coincide.


1. Whether a chord's voices want display lanes stable across frames. The allocator is deterministic over a fixed input, so the voices hold their columns while the host's output holds; a host whose output changes may re-column its neighbours.

1. The per-frame cost of allocation. A global region tiling a take is the dense case, and cost 28ms of a 32ms fx expansion before the reach optimisation (`design/decisions.md`, 2026-09-02). The viewport bounds the work now, and the measurement has not been taken.

1. What a memberless host emits. The base-voice test reads the inbound membership, so a region covering nothing emits no base voice. A generator stamping the field without a member to inherit it from leaves its output outside the pitchbend hold scope that its detune needs.

1. Whether authored notes carry `baseVoice` too, which would retire the lane-1 monopoly and leave the lane a display coordinate throughout.

1. What tells two identical hits from one host apart once the lane is gone. A pattern kind stamps whatever its body holds, so a doubled voice emits a pair alike in every field the existence reconcile keys, and the lane the region allocator hands each is all that separates them today. A note host's hits share its lane and collapse to one seat already, which is right — a lane holds one seat — but a laneless pair has no such seat to collapse onto.
