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

