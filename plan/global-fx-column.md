# Global fx column — plan

> source: `design/global-fx-column.md` — synthesis compiled from there;
> don't design here.

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
3. **Phase 3 — Explode** (§ Explode) — a verb that persists the expansion in
   place of the channel-0 region. Freeze keeps refusing on the master strip, so
   the explode is the route to freezing a global chain.  ← in flight

## Landed  (newest first; prune below ~4)

- 2026-08-27 tm: explode a global region onto the channels it reaches (§ Explode)
- 2026-08-27 tm: a global region realises as the union of its producers (§ Realisation on the master strip)
- 2026-08-27 tm: expand a global region onto the channels in use (§ Expansion)
- 2026-08-27 tm: expand a global region into a producer on every channel (§ Expansion, § An edit reaches sixteen channels)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)
- **tv: the explode gesture on the master strip.** `tv:explodeRegion` under
  `util.atomic('Explode FX region')`, a command bound in `pageBindings` that
  addresses `tv:fxHostAtCursor()`, and a button on the fx strip beside freeze's;
  both refuse off channel 0. `docs/trackerView.md` § Addressing a chain states
  the freeze route: explode, then freeze one of the sixteen. Spec in
  `tv_master_channel_spec`.
