# lotus menu — a typed path to every deliberate verb

> opened: 2026-08-25 · status: in flight — plan/lotus-menu.md, phase 4
> (the walk)

**Every command is declared once, in a per-scope manifest carrying its
label, its keys, and — for the deliberate verbs — a menu path. `/` opens
a menu row above the status bar where unique first letters walk those
paths, so the beginner's read and the expert's reflex are the same
keystrokes; the fluent verbs stay key-only, and F1 renders both routes
from the one declaration.**

## The manifest

1. Every command is declared once, in the manifest of the scope that
   registers it — see `docs/commandManager.md` § Manifest.

1. An entry also carries an optional **path** — see
   `docs/commandManager.md` § Menu tree.

1. An entry carries its cheat-sheet group and no rendering — see
   `docs/commandManager.md` § Manifest.

## Three consumers

1. A consumer reads its own slice of the manifest — see
   `docs/commandManager.md` § Manifest. The menu is the third, taking
   labels and paths.

1. The cheat-sheet groups entries by the group each entry declares, as
   `docs/help.md` § What's where describes; the menu groups them by path.
   The two partitions differ because they serve different acts — browsing
   a static map, and typing a path — and a command with no path appears in
   one and not the other.

## Fluent and pathed

Landed — see `docs/commandManager.md` § Menu tree.

## The surface

1. Manifests hang off `cmgr` scopes. A page's **surface** is the union of
   the manifests of the scopes on the stack, so global commands appear on
   every page — see `docs/commandManager.md` § Surface.

1. Reachability decides what the menu offers, by the predicate
   `docs/commandManager.md` § Scope stack already defines: a modal scope
   above an entry's own scope hides it unless the entry is in that
   scope's passthrough set. Region mode is spring-loaded rather than
   modal, and `/` is neither redirected nor kept alive, so opening the
   menu leaves the mode and walks the page's own surface.

1. The menu reaches no scope that is off the stack. Travelling to a page
   is a global command and works from anywhere; that page's own verbs
   become reachable once it is active.

## The tree

Landed — see `docs/commandManager.md` § Menu tree.

## The top level

Landed — see `docs/commandManager.md` § The top level.

## Walking a path

1. `/` opens the menu at the top level. The key is free: the dispatcher
   consumes `/` only while the prefix buffer is open
   (`docs/commandManager.md` § Prefix capture).

1. A letter descends. A group's letter opens that group; a leaf's letter
   closes the menu and invokes its command, in that order, so the command is
   gated by the ordinary stack. Nothing confirms a choice, because each letter
   is unique within its level.

1. Esc pops one level, and closes the menu from the top. The menu holds
   its own path and unwinds it, so one scope covers the whole walk.

1. Arrows move the highlight and Enter takes it, for a path not yet known
   by heart.

## What stays live

1. The open menu is a modal scope. Page and grid keys are blocked, so a
   letter always means a menu letter.

1. Passthrough keeps the transport and the page switchers live. Play, stop
   and travel to a page reach their commands with the menu open, because
   Continuum is played while it is edited and travel is not a menu letter.

1. The menu reads its surface off the stack as it opens, since its own
   modality would otherwise hide the commands it walks to. Closing a page
   switch's outgoing menu is the coordinator's, so the two scopes unwind in
   order — see `docs/menu.md` § A modal scope.

1. The numeric prefix survives the walk. Opening the menu neither freezes
   nor clears a pending prefix, so `⌘U 4 /VRS` sets rows-per-beat to 4.
   The leaf's invoke consumes it exactly as a chord's would.

## Where it draws

1. The menu **row** sits over the body's last row, above the status bar.
   The toolbar above holds the controls a command is chosen against, and
   the menu leaves it uncovered.

1. A **panel** drops from the highlighted group and grows upward. It
   lists that group's members with their letters, so the panel is the
   **lookahead** — the level below the highlight, shown before the
   highlight is taken.

1. The menu overlays and does not reflow. Opening it moves no grid row,
   so the cursor stays where the eye left it.

1. The panel is the cheat-sheet's box renderer with a highlight. F1 draws
   every group at once; the menu draws one and walks.

## Both routes on the cheat-sheet

1. A pathed command's path renders as a chip beside its key chips.
   Quantize shows its chord and `/GQ`; save shows `/FS` alone.

1. Paths are learned where keys already are: the cheat-sheet stays the
   one place a command's routes are read.

1. The chip is rendered from the entry's path and the group letters, so
   it cannot drift from the tree the menu walks.

## What load asserts

1. Every registered command resolves to exactly one entry — see
   `docs/commandManager.md` § Manifest.

1. Letters are unique within a level, and both checks run at load — see
   `docs/commandManager.md` § Menu tree.

## Open

- **The footer band.** The status bar has landed there (`docs/chrome.md`
  § Status bar layout), so the band's geometry is settled and the
  cheat-sheet's pins have moved once already.

- **Whether a path is editable.** The cheat-sheet rebinds keys in place
  (`docs/help.md` § Editing bindings). Whether a path may be re-cut the
  same way, and whether a re-cut persists as tokens the way binding
  overrides do, is not settled.

- **The editor's row.** The sampler declares two pathed verbs and wiring
  one, so both pages earn a row of their own. The editor declares none, and
  whether the global paths alone earn it a row is not settled.

- **A narrow window.** Twelve titles fit a comfortable width. What the
  row does when they do not — truncate, wrap, or scroll — is not
  settled.
