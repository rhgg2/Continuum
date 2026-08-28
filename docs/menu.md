# menu — the lotus menu

**`/` opens a menu whose letters walk a path to every deliberate verb.
The open menu is a modal cmgr scope, so a letter typed during the walk
is a menu letter rather than a page verb.**

## A modal scope

1. `menu.lua` owns the scope named `menu`, the one production scope
   declaring `modal = true` (`docs/commandManager.md` § Scope stack).
   Opening pushes it over the active page's scope; closing pops it.

1. The menu holds the path walked so far, empty at the top level, and
   clears it at each open and close. The path is the menu's own state,
   so one scope covers a walk of any depth.

1. `openMenu` is declared in global and registered ungated, since `/`
   opens the menu from any page. `closeMenu` is declared in the menu's
   own manifest and registered on its scope, so the gate is its own
   guard: Esc reaches it only while the menu is up, where it shadows
   the Esc bindings of the scopes below. The scope it pushed likewise
   blocks a second `openMenu`.

1. The coordinator constructs the menu beside `help`, and closes it at
   the top of `setActive`. Travel passes through the walk, and a page
   switch pops the page's scope, so the menu comes off the stack first
   or the pop finds the wrong scope on top.

## What stays live

1. The scope's passthrough set is every reachable entry declared under
   a `Transport` or `Pages` group, plus `switchPage`, the toolbar
   switcher's own verb, which no such group declares. Continuum is
   played while it is edited, and travel to a page is not a menu
   letter.

1. The set is read off the stack at the moment the menu opens, so a
   page's own transport verbs pass through while that page is showing.

1. Everything else is blocked while the menu is open, by key and by
   name alike: the grid verbs, undo, and the F1 cheat-sheet, which
   would cover the menu it was opened over.
