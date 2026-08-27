# Global fx — one chain, expanded into every channel

> opened: 2026-08-23 · status: in flight — plan/global-fx-column.md, phase 1
> (the master channel surface)

**A master channel 0 carries the tracker's global fx column. The
rebuild expands each of its regions into all sixteen channels.**

## The master channel

1. Channel 0 is the **master channel**: it carries fx columns and
   nothing else. It has no note, cc, pb, pc or at columns. It exists in
   the view alone and reaches no wire.

1. A **global region** is an fx region stored at `chan = 0`. It carries
   a chain as any region does, and is ordinary in every other regard.

1. The master channel is a global region's only surface. The fx columns
   of channels 1 to 16 carry their own regions and show nothing of a
   global one.

1. The master channel sits left of channel 1.

1. Its banner reads `Gl`, where a MIDI channel's reads `Ch n`.

## The master channel is always addressable

1. The master channel always has at least one fx column, occupied or
   not.

1. Region creation takes its channel from the column the selection
   starts in. Channel 1 always has note columns to select in; channel 0
   has only its fx columns, so one of those must stand before any
   global region exists.

1. Hide refuses on the master channel, which would otherwise be left
   with no column to select in.

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

1. Global regions sort after channel regions in storage, which is the
   precedence order among chains overlapping on one channel and target
   (`docs/generators.md` § Multiplicity — pack, sum, layer).

1. An expanded producer keeps its parent's place in that order, after
   the regions of the channel it lands on.

1. A global chain therefore comes last: its notes pack after the
   channel's, its augment curves sum on top, and its replace curves
   overwrite theirs.

## The verbs are unchanged

1. Every fx region verb addresses one stored region by uuid, and a
   global region is one stored region. Minting, rewriting the chain,
   moving and resizing the window, deleting, and adding or editing
   stages all work on channel 0 unchanged.

## What channel 0 refuses

1. The gestures naming a MIDI channel refuse on channel 0: mute and
   solo, parameter automation, and freeze.

1. Mute and solo refuse because channel 0 reaches no wire to silence.
   Solo also mutes the channels it is not on, so a solo there would
   silence all sixteen.

1. Parameter automation binds a channel and a CC lane, and channel 0
   names neither.

1. Freeze converts a chain into the notes and curves of the channel it
   runs on, and channel 0 runs on none.

1. Paste refuses by a rule already written. It rebases each region by a
   channel delta and drops any landing outside 1 to 16
   (`docs/trackerView.md` § FX regions), and channel 0 is outside that
   range.

1. Channel select stands. It selects a channel's columns rather than
   binding anything to the wire, and clicking the master banner is the
   mouse route onto the strip.

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
