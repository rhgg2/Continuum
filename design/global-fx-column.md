# Global fx — one chain, expanded into every channel

> opened: 2026-08-23 · status: in flight — plan/global-fx-column.md, phase 3
> (explode)

**A master channel 0 carries the tracker's global fx column. The
rebuild expands each of its regions into all sixteen channels.**

## The master channel surface

1. Landed in phase 1; the model lives in `docs/trackerView.md`
   § Addressing a chain ¶¶ 8-9.

## Expansion, precedence and derived identity

1. Landed in phase 2; the model lives in `docs/trackerManager.md`
   § Channel & column model.

## Realisation on the master strip

1. Landed in phase 2; the model lives in `docs/trackerManager.md`
   § Realisation by producer ¶¶ 5-6.

## The verbs are unchanged

1. Every fx region verb addresses one stored region by uuid, and a
   global region is one stored region. Minting, rewriting the chain,
   moving and resizing the window, deleting, and adding or editing
   stages all work on channel 0 unchanged.

## Explode

1. **Explode** converts a global region into an ordinary region on
   every channel it reaches. It is the expansion, run once and
   persisted in place of the region on channel 0.

1. Freezing a global chain therefore means exploding it and then
   freezing one of the sixteen.

1. The global form holds one chain for all sixteen channels, so
   per-channel divergence begins with an explode.

1. An explode is all or nothing: after it there is no global region,
   and every channel the chain reached carries an ordinary one.

## Open

1. Whether a global chain targeting pb or cc materialises that column
   on a channel in use by its notes alone. A channel's optional columns
   follow its data, and a global replace chain has a curve to seat with
   possibly nowhere to seat it.

1. The rebuild cost of a producer per channel in use where one region
   is stored, which wants measuring.

1. Whether a global region can be copied out of the master channel, and
   what pasting it onto channels 1 to 16 means.
