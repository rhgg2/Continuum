# Global fx column — plan

> source: `design/global-fx-column.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Master channel surface** — channel 0 renders left of channel 1 as
   an always-present fx strip, and the channel-naming gestures refuse on it.
   Landed 2026-08-27 in 2 commits; the model now lives in `docs/trackerView.md`
   § Addressing a chain ¶¶ 8-9.
2. **Phase 2 — Expansion** (§ Expansion, § An edit reaches sixteen channels,
   § Derived identity is stable, § Precedence, § Realisation on the master
   strip) — the head snapshot expands each global region into a producer on
   every channel in use, an edit seeds dirt on all sixteen, and the strip
   ghosts what they realise.  ← in flight
3. **Phase 3 — Explode** (§ Explode) — a verb that persists the expansion in
   place of the channel-0 region, and freeze routed through it.

## Landed  (newest first; prune below ~4)

- 2026-08-27 tm: expand a global region onto the channels in use (§ Expansion)
- 2026-08-27 tm: expand a global region into a producer on every channel (§ Expansion, § An edit reaches sixteen channels)
- 2026-08-27 tv: channel 0 refuses mute, solo, automation and freeze (§ What channel 0 refuses)
- 2026-08-27 tv: master channel strip, an fx-only channel 0 left of channel 1 (§ The master channel, § The master channel is always addressable)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The master strip's realisation** — `tm:fxRealisation` answers a stored
   global uuid with the union of its producers' entries — derived notes,
   claimed targets, parked cells — and `tv:ghostOverlay` takes each ghost's
   channel from the note that carries it rather than from the entry. Spec: with
   the caret on a global badge, the overlay ghosts in the columns of every
   channel the chain reaches, and the rows follow each channel's own swing.
