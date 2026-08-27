# Global fx column — plan

> source: `design/global-fx-column.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Master channel surface** (§ The master channel, § The master
   channel is always addressable, § What channel 0 refuses) — channel 0 renders
   left of channel 1 as an always-present fx strip, and the channel-naming
   gestures refuse on it.  ← in flight
2. **Phase 2 — Expansion** (§ Expansion, § An edit reaches sixteen channels,
   § Derived identity is stable, § Precedence) — the head snapshot expands each
   global region into sixteen per-channel producers, and an edit seeds dirt on
   all sixteen.
3. **Phase 3 — Explode** (§ Explode) — a verb that persists the expansion in
   place of the channel-0 region, and freeze routed through it.

## Landed  (newest first; prune below ~4)

- 2026-08-27 tv: master channel strip, an fx-only channel 0 left of channel 1 (§ The master channel, § The master channel is always addressable)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **Channel 0 refuses the channel-naming gestures** — mute, solo, channel
   select, freeze and parameter automation each bind a MIDI channel, which
   channel 0 does not name, so each refuses with the cursor there. Spec: every
   one of those verbs over channel 0 leaves state unchanged, and paste drops a
   region rebased onto channel 0 by the 1-to-16 range rule it already applies.
