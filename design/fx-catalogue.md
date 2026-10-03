# FX catalogue — a taxonomy Continuum owns, seeded from what REAPER records

> opened: 2026-08-24 · status: in flight — plan/fx-catalogue.md,
> phase 5 (the Plugins pane).

**Continuum holds a catalogue of the installed plugins: a nested
taxonomy over a per-format stable identity, in which a plugin may be
hard-linked in several places. It is seeded from what REAPER records,
thereafter authored in the Plugins pane, and the picker browses it.**

## Landed

1. The catalogue key, the catalogue and its entries, audio ports,
   traits, usage, the taxonomy, the sources, import and the seed
   nesting have landed in `docs/fxCatalogue.md`.

1. Unfiled, favourites, the picker's list and its candidates have
   landed in `docs/fxCatalogue.md`; the contexts, the gestures opening
   each and the splice in `docs/wiringPage.md`.

## The catalogue

1. An entry under an unresolved key can be relinked.

## Probing

1. A **probe** instantiates every installed plugin that is unprobed
   (`docs/fxCatalogue.md` § Candidates), to write its audio ports
   without waiting for use. It is run from Probe in the place tree
   (§ Editing in the pane).

1. A probe writes audio ports alone. It is not a use, so it leaves
   every usage score as it stands.

1. A probe takes one plugin per frame, and runs only while the Plugins
   pane is shown. Leaving the pane or the editor page stops it.

1. Stopping a probe loses nothing, since a later probe takes up the
   plugins still unprobed.

1. A probe counts the plugins it will take as it starts: every
   unprobed plugin carrying no probe failure.

1. While a probe runs, the editor page's status bar shows how many of
   those plugins it has probed and the name of the one it is probing.
   The place tree's Probe becomes Stop.

1. Each instance is added on the scratch track (`docs/scratch.md`),
   read, and removed within one frame. The project is thus left as it
   stood, and no undo point is made.

1. Before instantiating a plugin, the probe writes a **probe failure**
   to its entry, and it clears the failure once the plugin's ports are
   written.

1. The global file is written on every write (`docs/pextStore.md`). A
   plugin that fails to instantiate, crashes REAPER, or hangs until
   REAPER is killed thus keeps its probe failure.

1. A probe skips a plugin carrying a probe failure. A use clears the
   failure, since it writes the plugin's ports.

1. The detail strip carries a control that clears a plugin's probe
   failure, so the next probe takes the plugin again.

1. A plugin carrying a probe failure holds no ports. It is thus
   unprobed, and passes every audio test.

## The Plugins pane

1. The catalogue is edited in the **Plugins pane**, the third pane of
   the editor page after Swing and Tuning (`docs/editorPage.md`).

1. Each pane supplies the palette beside its content. Swing and Tuning
   supply the library tree (`docs/editorPage.md` § The library tree
   palette). The Plugins pane supplies the **place tree**: the root,
   with the category list nested by path beneath it.

1. The pane's content is the **plugin list** for the place selected in
   the tree, over a **detail strip** for the list's cursor row
   (§ Selecting in the list).

1. The detail strip shows the plugin's key, its category paths, its
   traits, its audio ports or that it is unprobed, any probe failure, its
   usage score and its developer name.

1. The pane opens from the editor page's pane selector, or from **Show
   in catalogue** in an fx node's menu (`docs/wiringPage.md`).

1. Show in catalogue clears the filter and selects a place the node's
   plugin sits at: the first of its paths in the category list's
   order, or the root where it is unfiled. It puts the cursor on the
   plugin. Escape then returns to the wiring page (`docs/editorPage.md`
   § Entry and exit).

## The plugin list

1. The plugin list holds the installed plugins at the selected place,
   and the entries under unresolved keys filed at it. At the root, it
   thus holds the unfiled plugins.

1. The list holds plugins alone. Child places are reached in the place
   tree.

1. An installed plugin is named as REAPER reports it. An unresolved
   entry is named by its key, and drawn dimmed.

1. The list sorts by name ignoring case.

1. A filter lists the plugins below the selected place
   (`docs/fxCatalogue.md` § The picker's list) whose names contain its
   text, ignoring case. From the root, it thus
   searches every plugin.

1. While the filter holds text, each row shows the plugin's paths at
   or beneath the selected place, written relative to it.

1. The filter sits in the toolbar, among the pane's own tools
   (`docs/editorPage.md` § The toolbar).

## Selecting in the list

1. The plugin list carries a **cursor row** and a **selection**, a set
   of its rows. The detail strip shows the cursor row, and filing and
   unfiling act on the selection.

1. A click puts the cursor on a row and selects that row alone.

1. Ctrl-click puts the cursor on a row and adds the row to the
   selection, or removes it where it is already selected.

1. The **anchor** is the row of the last click or Ctrl-click.

1. A press that becomes a drag is no click, so it changes the selection
   only as dragging does (§ Editing in the pane).

1. Shift-click selects the rows from the anchor to the clicked row, in
   place of the selection. Ctrl-Shift-click adds those rows to the
   selection.

1. Up and Down, or Ctrl-N and Ctrl-P, move the cursor and select its
   row alone, as a click does. With Shift, they select from the anchor
   to the cursor, as Shift-click does.

1. The keys move the cursor while the filter is being typed in, as they
   do in the picker.

1. Ctrl-A outside the filter selects every listed row. A filter and
   Ctrl-A thus select every plugin below the place whose name matches.

1. A row leaving the list leaves the selection, so filing and unfiling
   act only on listed rows. A cursor row leaving the list returns the
   cursor to the first row.

1. The place tree is driven by the mouse, and selects one place at a
   time.

## Editing in the pane

1. Dragging a selected row carries the selection. Dragging any other
   row selects it alone, and carries it.

1. Dropping the carried rows on a path in the place tree **moves**
   them there: each is unfiled from the selected place, and filed
   under the path. A row the filter lists only through a path beneath
   the place keeps its paths, so a move files it alone.

1. With Ctrl held at the drop, the rows are **copied**: each is filed
   under the path, and keeps its paths.

1. Dropping the carried rows on the root unfiles them from the selected
   place. A copy onto the root, and any drop on the root while the root
   is selected, changes nothing.

1. **File under…** files the selected rows under a path picked from the
   category list. Where its text names a path the list does not hold,
   the picker offers it as new (`docs/chrome.md` § Picker), and picking
   it makes the path and files under it.

1. Filing adds a path to a plugin and leaves its others in place.

1. **Unfile** removes the selected place from each selected row filed
   under it. A row the filter lists only through a path beneath the
   place keeps its paths. At the root, which is no path, Unfile is
   unavailable.

1. The detail strip carries a control on each of the plugin's paths
   that unfiles the plugin from it.

1. The place tree carries **new**, **rename**, **delete**, **import**
   and **probe**.

1. New makes a standing path under the selected place, its last name
   typed. At the root, it makes a top-level path.

1. Rename edits the selected path whole. A path thus moves by retyping
   its parent (`docs/fxCatalogue.md` § The taxonomy). At the root,
   Rename is unavailable.

1. Dragging a path in the place tree onto another moves it beneath
   that path, and onto the root moves it to the top level. A move is
   the rename that retypes the parent.

1. Import shows each source with its counts, takes or declines each,
   and sets the mode (`docs/fxCatalogue.md` § Import).

1. Delete deletes the selected path (§ Deleting a path). At the root,
   Delete is unavailable.

1. Probe runs a probe (§ Probing), whichever place is selected.

1. Each trait in the detail strip is authored present, authored absent
   or left to resolve (`docs/fxCatalogue.md` § Traits). A trait left
   to resolve shows the value it resolves to.

1. Edits in the pane sit outside undo, with the rest of the catalogue
   (`docs/fxCatalogue.md` § The catalogue).

1. Three edits confirm before they write:

   - a rename or move onto a path the list holds, which merges the
     two;
   - a delete of a path where a plugin is filed at or beneath it;
   - import in replace mode.

## Deleting a path

1. Deleting a path unfiles every plugin from it and from every path
   beneath it. It removes no plugin, and no other fact of an entry.

1. The path and the paths beneath it leave every entry, unresolved
   ones included, and the standing paths. A plugin filed nowhere else
   is thus left unfiled, at the root.

1. A path folds into its parent, its plugins still filed, by a rename
   onto the parent, which merges the two (`docs/fxCatalogue.md`
   § The taxonomy).

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

1. Whether the busses become catalogue entries under keys of their
   own, filed like any plugin — under `Tools` by the seed — and listed
   in the Plugins pane. Adding a bus is not a use, so such an entry gains no
   usage score.

1. Whether the picker offers a filter the user states — four audio ins
   and a compressor, to find a plugin to sidechain into — once it has
   landed.
