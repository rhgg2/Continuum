# lotus menu — a typed path to every deliberate verb

> opened: 2026-08-25 · status: in flight — plan/lotus-menu.md, phase 6
> (both routes)

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

Landed — see `docs/menu.md` §§ The walk and The highlight.

## What stays live

Landed — see `docs/menu.md` §§ A modal scope, What stays live and A
pending prefix.

## Where it draws

Landed — see `docs/menu.md` § The row.

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
