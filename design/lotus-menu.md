# lotus menu — a typed path to every deliberate verb

> opened: 2026-08-25 · status: in flight — plan/lotus-menu.md, phase 3
> (the tree)

**Every command is declared once, in a per-scope manifest carrying its
label, its keys, and — for the deliberate verbs — a menu path. `/` opens
a menu row above the status bar where unique first letters walk those
paths, so the beginner's read and the expert's reflex are the same
keystrokes; the fluent verbs stay key-only, and F1 renders both routes
from the one declaration.**

## The manifest

1. Every command is declared once, in the manifest of the scope that
   registers it — see `docs/commandManager.md` § Manifest.

1. An entry also carries an optional **path** — the menu segments that
   reach it, the last of which is its title in the menu. Keys and path are
   independent, and either may be absent. A command with keys alone is
   reached by its chord, one with a path alone through the menu, one with
   both either way.

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

1. A command pressed repeatedly is **fluent**: cursor motion, nudge,
   push, extending a selection, clearing a cell. A fluent entry carries
   keys and no path.

1. A command chosen deliberately is **pathed**: quantize, retune, take
   properties, save. A pathed entry carries a path, and keys only where
   the command is common enough to earn one.

1. A **generated family** — `drop0`–`dropZ`, `advBy0`–`advBy9` — is
   fluent by construction. Its members are a parameterised keyboard
   alphabet, reached by the key that names the index.

1. A mode that only reinterprets a fluent stream is fluent itself. Arrange's
   replace and advance modes are armed within a placement gesture, and what
   they modify is the drop family.

1. Nothing derives the classification, which says how a command is used
   rather than what it does. It is therefore declared.

## The surface

1. Manifests hang off `cmgr` scopes. A page's **surface** is the union of
   the manifests of the scopes on the stack, so global commands appear on
   every page — see `docs/commandManager.md` § Surface.

1. Reachability decides what the menu offers, by the predicate
   `docs/commandManager.md` § Scope stack already defines: a modal scope
   above an entry's own scope hides it unless the entry is in that
   scope's passthrough set. Pushing region mode therefore changes the
   menu.

1. The menu reaches no scope that is off the stack. Travelling to a page
   is a global command and works from anywhere; that page's own verbs
   become reachable once it is active.

## The tree

1. The menu **tree** follows from the paths: grouping the paths of the
   live surface yields it. A **level** is one step along a path, and the
   entries sharing a prefix at that step are its members.

1. The groups are declared in their own table. Each **group** carries its
   title, its **letter**, and a one-line description, shown while the
   group is highlighted.

1. A letter identifies its member uniquely within its level. It defaults
   to the first letter of the title, and is declared where two titles
   collide — Take borrows `K` so Tuning may keep `T`.

1. A level holds groups and leaves alike, and one namespace of letters
   covers both. A leaf's title is its path's last segment, so a command
   reads as one word in the menu where the cheat-sheet gives it a phrase.

## The top level

1. The top level is thirteen groups and one leaf:

   ```
   File  Edit  View  Play  Column  Row  Grid  Tuning  taKe  Mirror  fX  Sample  Jump  Help
   ```

1. Each group holds one remit:

   | group | remit |
   |---|---|
   | File | REAPER project actions, the profiler, and leaving Continuum |
   | Edit | the block and the clipboard |
   | View | panels, the arrange map, rows per beat |
   | Play | playing, following, and the loop |
   | Column | adding and removing columns |
   | Row | inserting and deleting rows |
   | Grid | quantize, scale and swing |
   | Tuning | tuning and retune |
   | taKe | take lifecycle and variants |
   | Mirror | mirror groups and freezing |
   | fX | note FX, the wiring graph and the param palette |
   | Sample | the sampler's slots and its file browser |
   | Jump | travel to a page |

1. Help is a leaf rather than a group, so `/H` opens the cheat-sheet.

1. Sample's members are the sampler page's own, so the group opens there and
   nowhere else. A group appears where its members are reachable, as § The
   surface has it, so the top level varies by page.

1. Grid and Tuning mirror the model's own two axes — `docs/timing.md` and
   `docs/tuning.md` — for the verbs that edit the take. Rows per beat is
   View's, since it changes how the take is shown. Where the menu's cut
   fights the model's, the verb is misnamed or misplaced.

1. File's bodies are REAPER actions run through `Main_OnCommand`, and
   REAPER owns their undo. Quit closes Continuum, not REAPER. Only
   File's paths leave Continuum; every other path reaches a Continuum
   command.

1. A group descends where it is crowded. View's rows-per-beat verbs sit
   one level down, so doubling the grid is `/VR=`.

## Walking a path

1. `/` opens the menu at the top level. The key is free: the dispatcher
   consumes `/` only while the prefix buffer is open
   (`docs/commandManager.md` § Prefix capture).

1. A letter descends. A group's letter opens that group; a leaf's letter
   invokes its command and closes the menu. Nothing confirms a choice,
   because each letter is unique within its level.

1. Esc pops one level, and closes the menu from the top. The menu holds
   its own path and unwinds it, so one scope covers the whole walk.

1. Arrows move the highlight and Enter takes it, for a path not yet known
   by heart.

## What stays live

1. The open menu is a modal scope. Page and grid keys are blocked, so a
   letter always means a menu letter.

1. Passthrough keeps the transport live. Play, stop and panic reach their
   commands with the menu open, because Continuum is played while it is
   edited.

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

1. Letters are unique within a level, over its groups and leaves alike. A
   collision raises, naming both members. The check pairs global's leaves
   with one scope's at a time, since two page scopes never stack together.

1. Both checks run at load, against the declaration rather than a walk,
   so a malformed menu never opens.

## Open

- **The classification.** Around 200 commands split fluent from pathed,
  and only a judgement per command settles it. The split is worth making
  visible in a spec, so that changing it later is deliberate.

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
