# menu — the lotus menu

**`/` opens a menu whose letters walk a path to every deliberate verb.
The open menu is a modal cmgr scope, so a letter typed during the walk
is a menu letter rather than a page verb.**

## A modal scope

1. `menu.lua` owns the scope named `menu`, the one production scope
   declaring `modal = true` (`docs/commandManager.md` § Scope stack).
   Opening pushes it over the active page's scope; closing pops it.

1. The menu holds the path walked so far as the nodes descended into,
   empty at the top level, and clears it at each open and close. The
   path is the menu's own state, so one scope covers a walk of any
   depth.

1. `openMenu` is declared in global and registered ungated, since `/`
   opens the menu from any page. `menuBack` is declared in the menu's
   own manifest and registered on its scope, so the gate is its own
   guard: Esc reaches it only while the menu is up, where it shadows
   the Esc bindings of the scopes below. The scope it pushed likewise
   blocks a second `openMenu`.

1. A page that suppresses its own bindings suppresses none of the
   menu's: the walk's keys hang off a modal scope, and key dispatch
   lifts page suppression while one is up (`docs/keyQueue.md`
   § Guards). So the arrows, Enter and Esc walk on the editor page,
   where the letters already did.

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

## The level

1. `menu:level()` returns the members of the node the path names: the
   node's child groups, then the entries stamped with that node
   (`docs/commandManager.md` § Menu tree). The empty path gives the top
   level, whose leaves are the one-segment paths.

1. A member carries the letter that reaches it, the title it reads
   under, and the line shown while it is highlighted — a group's
   description, a leaf's cheat-sheet label. A group also carries its
   node and a leaf its entry, so a letter descends or invokes from what
   the member holds.

1. Groups come in the order the tree declares them, and leaves by
   title. The surface unions the scopes on the stack, whose groups the
   manifest orders one by one, so a level of leaves drawn from two
   scopes takes its order here.

1. A group is a member where it or a descendant holds a reachable
   entry. On the sampler, Grid holds Swing alone, on the strength of
   the global verb that opens the swing editor, and Column is no member
   of the top level at all.

1. The level reads the surface the menu snapshotted as it opened, so
   what a walk reaches is what the page could reach when `/` was
   pressed. A closed menu holds an empty surface, and so an empty
   level.

1. The **lookahead** is the level below the highlight: the members of a
   highlighted group's node, and empty for a leaf, which has no level
   below it.

## The walk

1. A letter reaches the menu through the sink its scope declares
   (`docs/commandManager.md` § Scope stack). Key dispatch offers a bare
   letter to that sink ahead of the keychain walk, so a letter typed
   during the walk is the menu's, matched or not.

1. A group's letter descends: the node goes on the path, and the level
   becomes that node's. A leaf's letter closes the menu and then
   invokes its command, in that order, so the command is gated by the
   stack the menu was walked over.

1. `menuBack` pops one level, and closes the menu from the top. Esc
   and Super-G both reach it, the second being the bail gesture the
   pages bind, which the menu's scope shadows for the length of the
   walk.

1. The grid types nothing while the walk is up. Note entry reads the
   key stream directly rather than through cmgr, so it asks whether a
   scope captures letters, and stands off for every key while one
   does.

1. A leaf's letter closes the menu mid-frame, before note entry's pass
   over that same key stream, so that question answers no while the
   letter is still pressed. Key dispatch therefore reports the letter
   it captured as held, which that pass reads per key.

## The highlight

1. The menu holds a **highlight**, an index into the current level. Left
   and Right move it along the level, and either end joins the other.

1. Enter takes the highlight, doing what that member's letter does: a
   group descends, a leaf closes the menu and invokes. Up takes it too,
   and Down unwinds, the second pair beside Enter and Esc.

1. A descent marks the level it leaves with the index it was taken
   through, and an unwind restores that mark. Stepping back up the path
   therefore returns the highlight to the member it descended through,
   by letter and by Enter alike. Opening and closing clear the marks.

## The row

1. The level draws as a strip over the body's last row, on the
   foreground draw list, so opening the menu moves no grid row. The
   toolbar above the body holds the controls a command is chosen
   against, so the strip leaves it uncovered. The strip reaches the
   window's margins, as the toolbar and status bands do, stands on the
   status bar below it, and rules its top edge in a colour role of its
   own, defaulted to the highlight's.
   `menuRender.lua` owns the drawing, and reads the walk off the menu.

1. A member draws as its letter in a keycap beside its title, through the
   cheat-sheet's chip renderer and in its colours (`docs/help.md` § What's
   where). The letter is a key pressed, so it reads as one in both places.

1. The highlighted member wears a fill in a colour role of its own,
   covering its keycap and its title together.

1. A level wider than the row packs into as many lines as it needs, and so
   does the preview. The lines read top to bottom and the last stands on
   the row's floor, so the strip grows upward into the body.

1. The **preview** is a second line, above the level in the same strip and
   opening at the same column. A highlighted group shows its lookahead
   there, each member's letter beside its title; a highlighted leaf shows
   its description. So the level below the highlight is read before the
   highlight is taken.

1. A previewed letter's keycap is washed. The letter reads as a key in
   both lines, and the wash says it reaches nothing until the highlight is
   taken.

## A pending prefix

1. `/` is the numeric prefix's rational bar as well as the menu key
   (`docs/commandManager.md` § Prefix capture). With a prefix pending it
   does both: the buffer takes the slash, and the menu opens over it.

1. The key after it resolves which was meant. A digit continues the
   rational, and key dispatch calls the dismissal the menu's scope
   declares, which closes the walk from any depth. A letter walks.

1. The walk freezes nothing. A leaf calls `finishPrefix` immediately
   before its invoke, where the keychain walk calls it too, so `⌘U 4
   /VRS` sets rows per beat to 4. A walk abandoned leaves the buffer
   open where it stood.

1. The walk's own keys reach commands, not a sink, so each is declared
   transparent to the prefix (`docs/commandManager.md` § Prefix
   capture). Moving the highlight and unwinding a level leave the buffer
   as they found it, and the leaf Enter reaches takes it exactly as the
   leaf a letter reaches does.
