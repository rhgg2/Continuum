# FX catalogue — a taxonomy Continuum owns, seeded from what REAPER records

> opened: 2026-08-24 · status: in flight — plan/fx-catalogue.md,
> phase 4 (the picker).

**Continuum holds a catalogue of the installed plugins: a nested
taxonomy over a per-format stable identity, in which a plugin may be
hard-linked in several places. It is seeded from what REAPER records,
thereafter authored in place, and the picker browses it.**

## Identity

Landed in `docs/fxCatalogue.md`.

## The catalogue

1. The catalogue, its entries and their independent facts: landed in
   `docs/fxCatalogue.md` § The catalogue.

1. An entry under an unresolved key can be relinked.

## The taxonomy

Landed in `docs/fxCatalogue.md` § The taxonomy.

## Unfiled

Landed in `docs/fxCatalogue.md` § The taxonomy.

## Traits

Landed in `docs/fxCatalogue.md` § Traits.

## Probing

1. Audio ports and their write on use: landed in `docs/fxCatalogue.md`
   § Audio ports.

1. A **probe** instantiates a chosen set of plugins to write their
   ports without waiting for use.

1. A plugin whose entry holds no audio ports is **unprobed**.

## Usage

Landed in `docs/fxCatalogue.md` § Usage, and parameter frecency in
§ An instance's key.

## The sources

Landed in `docs/fxCatalogue.md` § The sources.

## Import

Landed in `docs/fxCatalogue.md` § Import.

## The seed nesting

Landed in `docs/fxCatalogue.md` § The seed nesting.

## Favourites

1. Favourites is a category path like any other. Favouriting a plugin
   files it under `Favourites`.

1. An entry's classification is thus its category paths and its
   developer name (`docs/fxCatalogue.md` § Import).

1. Import files the members of folder id 0 under `Favourites`.

## The picker

1. The picker offers the installed plugins for one pick. Its text is a
   path: the part before the last `/` is the **current place**, and the
   part after it is the **stem**.

1. The picker opens at the root, with no text.

1. The current place resolves to the place spelled the same, else to
   the one place spelled the same ignoring case. A current place
   resolving to nothing lists nothing.

1. The list holds the current place's child places whose names begin
   with the stem, then the plugins below the current place whose names
   contain it. Both match ignoring case.

1. A plugin is **below** a place where it is filed at that place or at
   a path beneath it. Every installed plugin is below the root, filed
   or not, so typing from the root reaches any of them.

1. A plugin below the current place through several paths is listed
   once.

1. A plugin's name is the name REAPER reports, which carries its format
   and developer — `VST3: Pro-Q 3 (FabFilter)`.

1. Child places are category paths, in the category list's order
   (`docs/fxCatalogue.md` § The taxonomy). An unfiled plugin is thus
   reached from the root, by its name.

1. Plugins sort with those in the project first, then by usage score,
   then by name ignoring case. A plugin is **in the project** where an
   instance of it sits in the project's wiring graph.

1. With no text, the root thus lists the top-level places and then
   every plugin, ranked.

1. Up and Down move the cursor through the whole list. The cursor
   returns to the first row when the text changes.

1. Tab or Enter on a place replaces the stem with the place's name and
   a `/`, so the place becomes the current place. Tab acts only on a
   place.

1. Enter on a plugin picks it.

1. The list depends on the text alone. Deleting back past a `/` thus
   widens the list to the parent place.

1. In **new**, the two busses lead the plugins at the root, and the
   stem narrows them by name as it does a plugin.

## The filtering seam

1. The picker opens with a **context**: the graph role the chosen
   plugin will take (`docs/wiring.md`). A plugin the context admits is
   a **candidate**, and only candidates are offered.

1. There are four contexts.

   - **new** — the plugin stands alone on the canvas. Admits every
     plugin.
   - **splice** — the plugin is inserted into a wire. Admits plugins
     carrying both an in and an out of that wire's type.
   - **branch** — the plugin is fed from a port. Admits plugins
     carrying an in of that port's type.
   - **replace** — the plugin takes another's place. Admits plugins
     whose ports cover the wires the other carries.

1. A plugin's ports **cover** a node's wires where each audio wire on
   the node's pair *k* finds a pair *k* on the same side, each MIDI
   wire in finds midi in, and each MIDI wire out finds midi out.

1. Candidacy over MIDI reads the entry's traits, and candidacy over
   audio its ports. An unprobed plugin passes every audio test.

1. A place with no candidate below it is hidden.

## Opening the picker

1. Each context opens from one gesture on the wiring canvas
   (`docs/wiringPage.md`). The picker anchors where the gesture is
   made.

1. **new** opens from a right-click on empty canvas, or from `N`. The
   pick drops the plugin at the cursor.

1. **splice** opens from **Insert fx…** in a wire's menu. The pick
   lands the plugin on the wire's triangle and splices it in
   (§ The splice).

1. **branch** opens where a forward draft is released over empty
   canvas. The pick lands the plugin at the release point, wired from
   the draft's port into the plugin's first in of that port's type.

1. A draft dragged from a source row in the palette branches over MIDI.

1. While a draft is over empty canvas, its loose end draws a ghost
   node. The release is thus seen to branch before it is made.

1. Escape or a click outside the picker cancels a branch, and the
   graph stands as it was before the draft. Escape during the draft
   cancels it without opening the picker.

1. **replace** opens from **Replace…** in an fx node's menu. The pick
   puts the plugin at the node's position, moves every wire on the
   node's ports onto it, and removes the node. An instrument's source
   stays wired to the plugin that replaces it.

1. In every context, adding the plugin and wiring it in are one undo
   step.

## The splice

1. A splice re-points a wire into a node's first in of the wire's
   type, and adds a leg from the node's first out of that type to the
   wire's old destination.

1. A wire of either type takes a splice. Over audio the node needs a
   free pair 1 both ways, and over MIDI an unwired midi in and midi
   out.

1. A spliced audio wire keeps its gain on the input side
   (`docs/wiringPage.md` § Splice on drop).

1. Dropping a dragged node onto a wire and picking from **Insert fx…**
   make the same splice. A dragged node thus splices into a MIDI wire
   as it does into an audio one.

## Open

1. Whether the stem gains a token grammar — developer, trait — once
   the picker has landed.

1. Whether `[deleted_categories]` should suppress a name at import.
   The list records the user's own hiding, which bears on the user
   categories and the derived ones differently.

1. How LV2 is handled. A category key may name an LV2 plugin by URI
   while `EnumInstalledFX` reports no LV2 at all, so classification can
   exist for plugins that cannot be offered.

1. Whether REAPER's plugin cache (`reaper-vstplugins*.ini`,
   `reaper-auplugins*.ini`) is read, and for what. It carries no
   classification, but maps a base name to a display name, a vendor and
   the instrument mark for every plugin ever scanned, including those
   no longer reported as installed.

1. How an AU whose files are deleted is treated. REAPER's AU cache
   (`reaper-auplugins*.ini`) still reports it as installed, and an
   instance of it reports an empty ident.

1. Ident forms on Windows and Linux, where a VST ident is a backslash
   path and AU does not exist.

1. What relinking an unresolved entry looks like, and whether a
   relinked key can be inferred from the entry's other facts.

1. Where the catalogue is edited from — filing a plugin, making a
   path, authoring a trait, running a probe — and whether that surface
   is a page of its own.

1. Whether a path can be deleted, and what becomes of the plugins
   filed under it.

1. What a probe costs over a large installation, and whether it runs
   over everything or only over what the user asks for.

1. Whether the picker offers a filter the user states — four audio ins
   and a compressor, to find a plugin to sidechain into — once it has
   landed.
