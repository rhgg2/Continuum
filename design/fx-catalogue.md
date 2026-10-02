# FX catalogue — a taxonomy Continuum owns, seeded from what REAPER records

> opened: 2026-08-24 · status: in flight — plan/fx-catalogue.md,
> phase 4 (the picker).

**Continuum holds a catalogue of the installed plugins: a nested
taxonomy over a per-format stable identity, in which a plugin may be
hard-linked in several places. It is seeded from what REAPER records,
thereafter authored in the FX tab, and the picker browses it.**

## Landed

1. The catalogue key, the catalogue and its entries, audio ports,
   traits, usage, the taxonomy, the sources, import and the seed
   nesting have landed in `docs/fxCatalogue.md`.

## The catalogue

1. An entry under an unresolved key can be relinked.

## Unfiled

1. A plugin is **unfiled** where it carries no category path.

1. A plugin sits **at** each path it is filed under. An unfiled plugin
   sits at the root.

1. The category list holds paths alone (`docs/fxCatalogue.md`
   § The taxonomy). A **place** is the root or a path in the list.

## Probing

1. A **probe** instantiates a chosen set of plugins to write their
   ports without waiting for use.

1. A plugin whose entry holds no audio ports is **unprobed**.

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

## The FX tab

1. The catalogue is edited in the **FX tab**, a pane of the editor page
   beside Swing and Tuning (`docs/editorPage.md`).

1. The palette holds the **place tree**: the root, with the category
   list nested by path beneath it.

1. The content pane holds the **plugin list** for the place selected in
   the tree, over a **detail strip** for the plugin selected in the
   list.

1. The detail strip shows the plugin's key, its category paths, its
   traits, its audio ports or that it is unprobed, its usage score and
   its developer name.

1. The tab opens from the editor page's pane selector, or from **Show
   in catalogue** in an fx node's menu (`docs/wiringPage.md`).

1. Show in catalogue selects the root and the node's plugin. Escape
   then returns to the wiring page (`docs/editorPage.md` § Entry and
   exit).

## The plugin list

1. The plugin list holds the installed plugins below the selected place
   (§ The picker), and the entries under unresolved keys filed below
   it.

1. An installed plugin is named as REAPER reports it. An unresolved
   entry is named by its key, and drawn dimmed.

1. Each row shows the plugin's paths beneath the selected place,
   written relative to it.

1. The plugins at the selected place lead the list, and the rest
   follow. Each group sorts by name ignoring case. At the root, the
   unfiled plugins thus lead.

1. A filter narrows the list to the plugins whose names contain its
   text, ignoring case.

1. Several rows may be selected at once. Filing and unfiling act on
   every selected row.

## Editing in the tab

1. Dropping the selected rows on a path in the place tree files them
   under it.

1. **File under…** files the selected rows under a path picked from the
   category list. Where its text names a path the list does not hold,
   the picker offers it as new (`docs/chrome.md` § Picker), and picking
   it makes the path and files under it.

1. Filing adds a path to a plugin and leaves its others in place.

1. **Unfile** removes the selected path from each selected row filed
   under it. A row below the path only through a path beneath it keeps
   its paths.

1. The detail strip carries a control on each of the plugin's paths
   that unfiles the plugin from it.

1. The place tree carries **new**, **rename** and **import**.

1. New makes a standing path under the selected place, its last name
   typed.

1. Rename edits the selected path whole. A path thus moves by retyping
   its parent (`docs/fxCatalogue.md` § The taxonomy).

1. Import shows each source with its counts, takes or declines each,
   and sets the mode (`docs/fxCatalogue.md` § Import).

1. Each trait in the detail strip is authored present, authored absent
   or left to resolve (`docs/fxCatalogue.md` § Traits). A trait left
   to resolve shows the value it resolves to.

1. Edits in the tab sit outside undo, with the rest of the catalogue
   (`docs/fxCatalogue.md` § The catalogue).

1. Two edits confirm before they write: a rename onto a path the list
   holds, which merges the two, and import in replace mode.

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
   relinked key can be inferred from the entry's other facts. An
   unresolved entry carrying no path has no row in the plugin list.

1. Whether the place tree can delete a path, and what becomes of the
   plugins filed under it.

1. What a probe costs over a large installation, and whether the tab
   probes the selected rows or every unprobed plugin below a place.

1. Whether the busses become catalogue entries under keys of their
   own, filed like any plugin — under `Tools` by the seed — and listed
   in the FX tab. Adding a bus is not a use, so such an entry gains no
   usage score.

1. Whether the picker offers a filter the user states — four audio ins
   and a compressor, to find a plugin to sidechain into — once it has
   landed.
