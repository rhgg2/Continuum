# Laneless derived notes — one shape for derived reconciliation

> opened: 2026-09-12 · status: in flight — plan/laneless-derived-notes.md,
> at phase 4 (laneless emission).

**Derived notes carry no lane, so they reconcile as derived ccs do: gathered per touched window and kept by omission.**

## The derived note record

1. A derived note carries no lane. The uuid of the host that produced it names its origin.

1. Generator output is laneless at the point of emission. The lane on the `notes` shape belongs to its inbound half, the authored members a monophonic stage reads (`docs/generators.md` § Input streams).

1. The fx spec, `noteLive` and `fxNotesByHost` carry the record forward unchanged.

1. Derived output takes no allocation. A derived note stands outside the note columns, so simultaneous hits contend for nothing but midiManager's seat — (chan, pitch, ppq) — which the onset settlement separates. Two of a generator's own notes overlapping at one pitch remains a constraint on kinds (`docs/generators.md` § Output).

1. Emission order carries the determinism allocation used to carry, and is the last term of `index.order` (`docs/trackerManager.md` § Update manager (um)). Hosts run in a fixed order and each host's output holds the generator's own, so a pass over unchanged input emits the same set in the same order. Every sort and the settlement itself read that order from the one place: without it two hits a generator emits alike tie, neither is the other's same-pitch successor, and the seat they share goes unseparated.

1. A derived note takes a lane exactly when it stops being one. Freeze promotes it to authored and gives it a column in the same breath, by the rule and the occupancy `tv:displayLanes` placed its ghost with, so it is authored into the column it was read in (`docs/trackerManager.md` § Tail walk).

1. A lane is metadata to midiManager, which names only the (chan, pitch) voice group. A derived note's metadata carries none.

1. The existence reconcile names a derived record by its logical seat and its voice fields, and matches predictions against existing records as a multiset. Two records alike in every keyed field are two seats, and each prediction takes the next unmatched one. The realisation frame stays out of the key — the onset settlement nudges a raw onset off its projection, and a record keyed on the raw would be swept on the pass after the one that wrote it.

## The base voice

Landed. The model stands in `docs/tuning.md` § Intent vs realisation and
`docs/generators.md` § Output.

## The derived tail bound

Landed. The model stands in `docs/trackerManager.md` § Tail walk.

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

