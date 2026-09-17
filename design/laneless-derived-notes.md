# Laneless derived notes — one shape for derived reconciliation

> opened: 2026-09-12 · status: in flight — plan/laneless-derived-notes.md,
> at phase 5 (keep by omission).

**Derived notes carry no lane, and reconcile against what their producing host last emitted: gathered by host and kept by omission.**

## The derived note record

Landed. The model stands in `docs/generators.md` § Output and
`docs/trackerManager.md` § Update manager (um), § Fx expansion and § Tail walk.

## The base voice

Landed. The model stands in `docs/tuning.md` § Intent vs realisation and
`docs/generators.md` § Output.

## The derived tail bound

Landed. The model stands in `docs/trackerManager.md` § Tail walk.

## Keep by omission

1. A derived note enters a pass when its host runs.

1. A derived note carries the uuid of the host that produced it. The update manager files it under that uuid as it files the note itself, so a host's output is a standing bucket and not a set recomputed per pass.

1. The gather sits at fx expansion, where the run verdict is made. A channel's derived existing set is the bucket of each host that ran, cloned into the pass.

1. A host that does not run contributes nothing to the pass. Its bucket stands in no existing set and its output in no predicted set, so the reconcile passes over the host entirely, and its notes survive the pass untouched. This is **keep by omission**.

1. A bucket whose uuid names no host of the pass is an orphan, its host deleted or parked away, and falls in to be swept.

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

