# Global fx column — plan

> source: the model now lives in `docs/trackerView.md`,
> `docs/trackerManager.md` and `docs/trackerRender.md`; the design doc it
> was compiled from is gone.

## Phases

1. **Phase 1 — Master channel surface** — channel 0 renders left of channel 1 as
   an always-present fx strip, and the channel-naming gestures refuse on it.
   Landed 2026-08-27 in 2 commits; the model now lives in `docs/trackerView.md`
   § Addressing a chain ¶¶ 8-9.
2. **Phase 2 — Expansion** — the head snapshot expands each global region into a
   producer on every channel in use, an edit seeds dirt on all sixteen, and the
   strip ghosts what they realise. Landed 2026-08-27 in 3 commits; the model now
   lives in `docs/trackerManager.md` § Channel & column model and § Realisation
   by producer ¶¶ 5-6.
3. **Phase 3 — Explode** — a verb that persists the expansion in place of the
   channel-0 region. Freeze keeps refusing on the master strip, so the explode
   is the route to freezing a global chain. Landed 2026-08-27 in 2 commits; the
   model now lives in `docs/trackerView.md` § Addressing a chain ¶ 10 and
   `docs/trackerManager.md` § Channel & column model.

## Landed  (newest first; prune below ~4)

- 2026-08-27 tv: explode a global region from the master strip (design § Explode)
- 2026-08-27 tm: explode a global region onto the channels it reaches (§ Explode)
- 2026-08-27 tm: a global region realises as the union of its producers (§ Realisation on the master strip)
- 2026-08-27 tm: expand a global region onto the channels in use (§ Expansion)

## Now

(empty — closed 2026-08-27, all three phases landed. One thing the programme
leaves open, recorded in `docs/oddities.md` § A global region copied off the
master strip is demoted or lost: what a copied global region means, which the
clipboard's channel delta cannot express either way.)

## Queued (current phase; one-liners)

(empty — every phase has landed.)
