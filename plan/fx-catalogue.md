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

- 2026-10-02 fxCatalogue: file favourites under a path, dropping the flag (§ Favourites)
- 2026-10-02 fxCatalogue: nest derived categories by the seed (§ The seed nesting)
- 2026-10-02 fxCatalogue: import the chosen sources (§ Import)
- 2026-10-02 fxCatalogue: read the sources, resolved to catalogue keys (§ The sources)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- fxCatalogue: unfiled sits at the root (§ Unfiled) — `categories()`
  returns paths alone and the `UNFILED` sentinel goes;
  `docs/fxCatalogue.md` § The taxonomy takes a place as the root or a
  listed path, with an unfiled plugin at the root. Spec:
  fxCatalogue_spec's category-list cases drop the sentinel.
- fxCatalogue: the picker's list as a function of its text (§ The picker
  3–10, 14–15) — split at the last `/` into current place and stem;
  the place resolves exact, else to the one case-insensitive match,
  else lists nothing; child places are category paths under it whose
  last name begins with the stem, in category-list order, with no
  unfiled place; plugins below it (at the root every installed plugin)
  whose REAPER name contains the stem, once each, ranked in-project
  first, then usage score decayed to the catalogue's current count,
  then name ignoring case. In-project keys arrive from the caller, and
  in **new** the two busses lead the root's plugins, narrowed by the
  stem. Pure, with its own spec.
- wiringRender: the fx picker as path completion (§ The picker 1–2,
  11–14) — `renderFxPicker` draws places then plugins from the list
  function, fed through wv/wm with the installed rows, the catalogue and
  the project's fx keys; Tab or Enter on a place replaces the stem with
  `name/`, Enter on a plugin picks it, Up/Down span the whole list, and
  the cursor returns to row 1 on any text change. The **new** context
  only, from right-click and `N` as now.
- fxCatalogue: candidates by context (§ The filtering seam) — a
  predicate over a plugin's resolved traits and ports for **new**,
  **splice** (in and out of the wire's type), **branch** (an in of the
  port's type) and **replace** (its ports cover a stated set of wires:
  audio pair *k* per side, midi in, midi out); an unprobed plugin passes
  every audio test. The list offers only candidates and hides a place
  with none below it. Spec beside the list function's.
- wiringManager: splice over either wire type (§ The splice) —
  `wm:spliceable` and `wm:spliceIntoEdge` re-point a wire into the
  node's first in of its type and add a leg from the first out; audio
  needs free pair 1 both ways and keeps its gain on the input side, MIDI
  needs an unwired midi in and midi out. Splice on drop takes MIDI wires
  too; `docs/wiringPage.md` § Splice on drop follows. Spec:
  wm_splice_spec.
- wiringRender: **splice** from **Insert fx…** (§ Opening the picker 1,
  3, 9) — the wire menu gains the item; the picker opens at the wire's
  triangle in the splice context of the wire's type, and the pick adds
  the plugin on the triangle and splices it in as one undo step. Settles
  how wm composes add-then-wire under one transaction, which the next
  two reuse.
- wiringManager: **replace** from **Replace…** (§ Opening the picker 8–9)
  — the node menu gains the item, opening the picker in the replace
  context with the node's wires as the set to cover; the pick puts the
  plugin at the node's position, moves every wire onto the matching
  port, keeps an instrument's source wired to it, and removes the node,
  as one undo step. Spec on the wm replace.
- wiringRender: **branch** from a draft released on empty canvas
  (§ Opening the picker 4–7, 9) — the release opens the picker in the
  branch context of the draft port's type (MIDI for a palette row); the
  pick lands the plugin at the release point wired from that port into
  its first in of the type, as one undo step; a ghost node draws at the
  loose end over empty canvas; Escape or a click outside the picker
  leaves the graph as it was, and Escape during the draft cancels it.


