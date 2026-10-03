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
   gesture opening each. — landed 2026-10-03, 9 commits.
5. **Phase 5 — The Plugins pane** (§ Probing, § The Plugins pane,
   § The plugin list, § Selecting in the list, § Editing in the pane,
   § Deleting a path) — the editor page's third pane: the place tree
   and the plugin list with its cursor and selection, the detail strip,
   filing, path edits and import from the pane, Show in catalogue, and
   the probe. Relinking an unresolved entry stays open (§ Open).
   ← in flight

## Landed  (newest first; prune below ~4)

- 2026-10-03 wiring: branch an fx from a draft released on empty canvas (§ Opening the picker 4–7, 9–10)
- 2026-10-03 wiring: replace an fx node from Replace… (design § Opening the picker 8–10)
- 2026-10-03 wiring: splice an fx into a wire from Insert fx… (design § Opening the picker 1, 3, 9–10)
- 2026-10-03 wm: splice over either wire type (§ The splice)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- fxCatalogue: delete a path, and list the plugins at a place
  (§ Deleting a path, § The plugin list 1, 3–6). Deleting unfiles
  every entry, unresolved ones included, from the path and every path
  beneath it, and removes them from the standing paths; no other fact
  of an entry changes. The plugin list for a place holds the installed
  plugins at it and the unresolved entries filed at it, sorted by name
  ignoring case, an unresolved entry named by its key and marked as
  such. With filter text it holds the plugins below the place whose
  names contain the text, each carrying its paths at or beneath the
  place, written relative to it. Model only, specced against ds.
- editor: the Plugins pane, read-only (§ The Plugins pane 1–4,
  § The plugin list). A third pane after Swing and Tuning in the
  selector. Each pane supplies its palette: Swing and Tuning the
  library tree as now, the Plugins pane the place tree — the root, with
  the category list nested by path. The content is the plugin list for
  the selected place, unresolved rows dimmed, over the detail strip for
  the cursor row: key, paths, traits, audio ports or unprobed, usage
  score and developer. The filter sits in the toolbar through
  `renderToolbar`. A click sets the cursor; the selection comes next.
- editor: cursor and selection in the plugin list (§ Selecting in the
  list). The cursor row, the selection and the anchor; click,
  Ctrl-click, Shift-click and Ctrl-Shift-click; Up and Down or Ctrl-N
  and Ctrl-P, with and without Shift, live while the filter is typed
  in; Ctrl-A outside the filter. A row leaving the list leaves the
  selection, and a cursor leaving it returns to the first row. A press
  that becomes a drag is no click. The rules are a function of the list
  and the gesture, specced on their own.
- editor: file, unfile and author traits from the Plugins pane
  (§ Editing in the pane 1–8, 16–17). Dragging carries the selection
  where the grabbed row is selected, else the row alone; a drop on a
  path moves, with Ctrl copies, and a drop on the root unfiles from the
  selected place. File under… picks from the category list through the
  shared picker, with a row making a new path. Unfile acts on the
  selection, and is unavailable at the root. A row listed only through
  a deeper path keeps its paths under a move or Unfile. The detail strip
  gains an unfile control per path, and a three-way control per trait,
  a trait left to resolve showing its resolved value. Outside undo.
- editor: make, rename, move and delete paths in the place tree
  (§ Editing in the pane 9–12, 14, 18, § Deleting a path). New under
  the selected place; Rename edits the whole path; dragging a path onto
  another or onto the root is the rename retyping its parent; Delete
  runs the first item's model. Rename and Delete are unavailable at the
  root. A rename or move onto a held path, and a delete of a path with
  a plugin at or beneath it, confirm before they write.
- editor: import from the place tree (§ Editing in the pane 13, 18).
  Import shows each source with its three counts, takes or declines
  each, sets augment or replace, and runs `fxCatalogue.import`. Replace
  confirms first.
- wiring: Show in catalogue from an fx node's menu (§ The Plugins pane
  5–6). It opens the editor on the Plugins pane with the filter
  cleared, selects the first place in the category list's order that
  the plugin sits at, else the root, and puts the cursor on the plugin.
  It is a drop-in, so Escape returns to the wiring page
  (`docs/editorPage.md` § Entry and exit).
- fxCatalogue: probe one plugin on the scratch track (§ Probing 1–2,
  7–10, 12). A probe failure is a fact on the entry, written before
  instantiating and cleared once the ports are written. One plugin is
  added on the scratch track (`docs/scratch.md`), its ports read and
  written without a bump, and removed in the same call, with no undo
  point. A use clears the failure. The probe's queue is every unprobed
  plugin carrying no failure, counted as the probe starts.
- editor: run a probe from the place tree (§ Probing 3–6, 11,
  § Editing in the pane 15). Probe runs whichever place is selected,
  and becomes Stop while the probe runs. It takes one plugin per frame
  while the Plugins pane is shown, and stops on leaving the pane or
  the page. The status bar shows how many of the counted plugins are
  probed and the name of the current one. The detail strip shows any
  probe failure, with a control clearing it.
