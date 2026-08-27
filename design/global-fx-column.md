# Global fx — one chain, expanded into every channel

> opened: 2026-08-23 · status: in flight — plan/global-fx-column.md, phase 2
> (expansion)

**A master channel 0 carries the tracker's global fx column. The
rebuild expands each of its regions into all sixteen channels.**

## The master channel surface

1. Landed in phase 1; the model lives in `docs/trackerView.md`
   § Addressing a chain ¶¶ 8-9.

## Expansion

1. **Expansion** replaces each global region with sixteen **expanded
   producers**, one per channel, each an ordinary region carrying the
   global's span and fx list at its own channel. It runs on the single
   head snapshot of document keys `rebuildPipeline` takes for its
   passes.

1. Both consumers of that snapshot, `producerCensus` and `rebuildFx`,
   therefore see per-channel regions only.

## An edit reaches sixteen channels

1. The stored region holds the intent, so `derivationInputs` diffs the
   unexpanded form (`docs/trackerManager.md` § Dormant guard).

1. Editing a global region therefore seeds derivation dirt on all
   sixteen channels. The region-edit seed keys its triggers by the
   stored region's uuid and fans them across all sixteen.

## Derived identity is stable

1. An expanded producer's uuid is its parent's, qualified by the
   channel number.

1. That uuid persists into the window store and the park stash, and
   seat recognition matches against it (`docs/generators.md`
   § Route-by-window).

## Precedence

1. Storage order is the precedence order among chains overlapping on
   one channel and target (`docs/generators.md` § Multiplicity — pack,
   sum, layer).

1. Expansion emits each channel's own regions in storage order, then
   the producers expanded onto it. Storage carries no rule of its own
   about where a global region sits.

1. A global chain therefore comes last: its notes pack after the
   channel's, its augment curves sum on top, and its replace curves
   overwrite theirs.

1. Among globals the order is their storage order, which the master
   strip shows as their lane order.

## Realisation on the master strip

1. The caret on a region asks what its chain realises
   (`docs/trackerManager.md` § Realisation by producer), and a global
   region has no producer of its own.

1. A stored global uuid therefore resolves to the union of its sixteen
   producers: their derived notes, their claimed targets, and the cells
   they parked.

1. A ghost lands on the channel of the producer that emitted it, so the
   overlay reads a channel per note rather than one per entry.

## The verbs are unchanged

1. Every fx region verb addresses one stored region by uuid, and a
   global region is one stored region. Minting, rewriting the chain,
   moving and resizing the window, deleting, and adding or editing
   stages all work on channel 0 unchanged.

## Explode

1. **Explode** converts a global region into sixteen ordinary
   per-channel regions. It is the expansion, run once and persisted in
   place of the region on channel 0.

1. Freezing a global chain therefore means exploding it and then
   freezing one of the sixteen.

1. The global form holds one chain for all sixteen channels, so
   per-channel divergence begins with an explode.

1. An explode is all or nothing: after it there is no global region,
   and all sixteen channels carry ordinary ones.

## Open

1. Whether a global chain targeting pb or cc materialises that column
   on a channel carrying none. A channel's optional columns follow its
   data, and a global replace chain has a curve to seat with possibly
   nowhere to seat it.

1. The rebuild cost of sixteen producers where one region is stored,
   which wants measuring.

1. Whether a global region can be copied out of the master channel, and
   what pasting it onto channels 1 to 16 means.
