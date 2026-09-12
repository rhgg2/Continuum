# Laneless derived notes — one shape for derived reconciliation

> opened: 2026-09-12 · status: in flight — plan/laneless-derived-notes.md,
> at phase 1 (the base voice).

**Derived notes carry no lane, so they reconcile as derived ccs do: gathered per touched window and kept by omission.**

## The derived note record

1. A derived note carries no lane. The uuid of the host that produced it names its origin.

1. Generator output is laneless at the point of emission. The lane on the `notes` shape belongs to its inbound half, the authored members a monophonic stage reads (`docs/generators.md` § Input streams).

1. The fx spec, `noteLive` and `fxNotesByHost` carry the record forward unchanged.

1. A lane is metadata to midiManager, which names only the (chan, pitch) voice group. A derived note's metadata carries none.

## The base voice

1. A channel's **base voice** is the voice whose detune the channel realises through pitchbend. There is one at a time, and the absorber pass seats against its onsets (`docs/tuning.md` § Absorber reconciliation).

1. An authored note in lane 1 is the base voice, which is the monopoly `docs/tuning.md` § Invariants states as I3.

1. A derived note carries `baseVoice`, set by the generator emitting it. The field is inherited: a note is base voice when the stream note it derives from is, so a stage over a higher-lane host emits none, and a chained stage reads its predecessor's output.

1. A chord stamp keeps the field on the voice displaced from the pattern's root alone, so the root's microtonality sounds.

1. The base-voice door answers over both — the raw index's authored lane-1 notes, and the pass's base-voice derived output. The detune query and the onset walk read the one door, so they agree at a coincident onset.

1. A host emits base-voice notes when its generator sets the field on its output. The pitchbend hold scope reads that, and widens to the host's window start.

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

1. Allocation runs per frame, over the host the caret addresses, and takes the lowest column free of overlap. The channel's authored population seeds occupancy, so a ghost lands clear of the notes already sounding there.

1. One allocation serves the frame. The ghost overlay places its notes by it, and the ghost readout reserves cents columns by it (`docs/trackerView.md` § Ghost sampling).

1. A ghosted row may also carry a real cell. The allocation is a legibility question, and the draw arm settles precedence.

## The freeze claim

1. A host's freeze rect claims one note stream per display lane its output occupies, alongside the pb and cc streams its targets name.

1. The rect resolves when the freeze path asks for it, from the allocation standing at that moment. The rect a mint would claim and the columns drawn come from the one allocation.

## Open

1. What the allocation's unit is. A freeze claim is durable and a viewport moves under scroll, so an allocation restricted to visible rows would give a host different claims at different scroll positions. The likely settlement is the host's whole window as the unit, with the ghost allocation that one filtered to the rows on screen.

1. Whether a generator may set `baseVoice` on more than one note sounding at once, and what the absorber seats if two coincide.

1. What bounds a derived note whose generator emits an open end. The same-pitch successor answers where one exists; the host window end answers otherwise, if an open end is taken to mean the window.

1. Whether a chord's voices want display lanes stable across frames. The allocator is deterministic over a fixed input, so the voices hold their columns while the host's output holds; a host whose output changes may re-column its neighbours.

1. The per-frame cost of allocation. A global region tiling a take is the dense case, and cost 28ms of a 32ms fx expansion before the reach optimisation (`design/decisions.md`, 2026-09-02). The viewport bounds the work now, and the measurement has not been taken.

1. Whether authored notes carry `baseVoice` too, which would retire the lane-1 monopoly and leave the lane a display coordinate throughout.
