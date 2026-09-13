# Laneless derived notes — one shape for derived reconciliation

> opened: 2026-09-12 · status: in flight — plan/laneless-derived-notes.md,
> at phase 2 (the display lane).

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

## Keep by omission

1. A derived note enters a pass when the dirt touches its host's window.

1. The gather is per window, as the cc gather is (`docs/trackerManager.md` § CC walk). A channel's derived existing set holds the output of the hosts the dirt reached.

1. A host the dirt leaves alone contributes nothing to the pass. Its output stands in no existing set and in no predicted set, so the reconcile passes over the host entirely, and its notes survive the pass untouched. This is **keep by omission**.

1. The channel's authored notes reach the pass by seeking to the seeded rows.

## The display lane

1. A **display lane** is the grid column a derived note draws in. trackerView allocates it.

1. Allocation runs over a host's whole window and takes the lowest column free of overlap. It is asked of a host by uuid, the fx strip's freeze buttons addressing a pinned host the caret has left.

1. The channel's authored population seeds occupancy, less the cells the host's ghosts hide. So a ghost lands clear of what the column draws, and may take the column its own parked original left.

1. One allocation serves the frame, and its readers filter it. The ghost overlay places its notes by it over the viewport's rows, and the ghost readout reserves cents columns by it (`docs/trackerView.md` § Ghost sampling).

1. A ghosted row may also carry a real cell. The allocation is a legibility question, and the draw arm settles precedence.

## The freeze claim

1. A host's freeze rect claims one note stream per display lane its output occupies, alongside the pb and cc streams its targets name.

1. trackerManager publishes the host's span with the streams its targets name. The freeze path adds a note stream per column the allocation gives the host, before the rect reaches groupManager.

1. The rect resolves when the freeze path asks for it, from the allocation standing at that moment. The rect a mint would claim and the columns drawn come from the one allocation, so the claim stands still under scroll.

## Open

1. Whether a generator may set `baseVoice` on more than one note sounding at once, and what the absorber seats if two coincide.

1. What bounds a derived note whose generator emits an open end. The same-pitch successor answers where one exists; the host window end answers otherwise, if an open end is taken to mean the window.

1. Whether a chord's voices want display lanes stable across frames. The allocator is deterministic over a fixed input, so the voices hold their columns while the host's output holds; a host whose output changes may re-column its neighbours.

1. The per-frame cost of allocation. A global region tiling a take is the dense case, and cost 28ms of a 32ms fx expansion before the reach optimisation (`design/decisions.md`, 2026-09-02). The viewport bounds the work now, and the measurement has not been taken.

1. What a memberless host emits. The base-voice test reads the inbound membership, so a region covering nothing emits no base voice. A generator stamping the field without a member to inherit it from leaves its output outside the pitchbend hold scope that its detune needs.

1. Whether authored notes carry `baseVoice` too, which would retire the lane-1 monopoly and leave the lane a display coordinate throughout.
