# FX catalogue — plan

> source: `design/fx-catalogue.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Keys and entries** (§ Identity, § The catalogue, § Usage 4)
   — the per-format catalogue key with REAPER's VST base-name spelling,
   the installed set re-read and indexed by key, and parameter frecency
   rekeyed onto the catalogue key. — landed 2026-09-30, 2 commits.
2. **Phase 2 — Facts on an entry** (§ The catalogue, § Traits, § Probing
   1–2, § Usage 1–3) — the catalogue as a global ds key with unresolved
   entries standing, landing with its first writers: audio ports written
   on instantiation, the use-counted bump, and traits resolved authored
   over parsed JSFX over the format mark. The probe waits on the surface
   the catalogue is edited from (§ Open). — landed 2026-10-01, 2 commits.
3. **Phase 3 — Taxonomy and import** (§ The taxonomy, § Unfiled, § The
   sources, § Import, § The seed nesting) — category paths with the list
   and rename, parsers for the install tree and the two ini files, import
   with its per-source coverage in augment or replace mode, and the
   shipped seed nesting. The model only: import and rename are reached
   through the bridge, and their surface waits with the probe's.
   — landed 2026-10-02, 4 commits.
4. **Phase 4 — The picker** (§ Unfiled, § Favourites, § The picker,
   § The filtering seam, § Opening the picker, § The splice) — favourites as a
   path, the wiring picker as path completion with in-project and usage
   ordering, the candidate predicate over the four contexts, and the
   gesture opening each. ← in flight

## Landed  (newest first; prune below ~4)

- 2026-10-03 wiring: replace an fx node from Replace… (design § Opening the picker 8–10)
- 2026-10-03 wiring: splice an fx into a wire from Insert fx… (design § Opening the picker 1, 3, 9–10)
- 2026-10-03 wm: splice over either wire type (§ The splice)
- 2026-10-03 fxCatalogue: filter picker rows by need and hide empty places (§ The filtering seam)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- wiringRender: **branch** from a draft released on empty canvas
  (§ Opening the picker 4–7, 9) — the release opens the picker in the
  branch context of the draft port's type (MIDI for a palette row); the
  pick lands the plugin at the release point wired from that port into
  its first in of the type, as one undo step; a ghost node draws at the
  loose end over empty canvas; Escape or a click outside the picker
  leaves the graph as it was, and Escape during the draft cancels it.


