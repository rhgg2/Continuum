# help — the F1 keybinding cheat-sheet

F1 overlays the active page with labelled callouts showing every bound
command, each placed over the UI element it concerns. It exists so the
keymap is discoverable in-place rather than memorised or hunted for in
source.

## Why a registry, not a static map

The pages draw heterogeneously: toolbar segments are real ImGui widgets,
but the tracker grid and the wiring canvas are custom drawlist geometry
with no addressable "elements". The only thing that reliably knows where
a region landed is the render pass that just drew it. So positions are
*reported at draw time*, not predeclared:

- **Toolbar** — `chrome.makeToolbar` already measures each segment's rect
  to lay them out. It stashes those rects; `help` reads them by id
  (`toolbar.<id>`). Zero per-page work, and no `chrome → help` edge:
  help pulls from chrome, never the reverse.
- **Status bar** — `chrome.makeStatusBar` records each cell's rect as it
  places it, and help reads those by id too (`status.<id>`), the same
  pull as the toolbar's.
- **Body** — render code calls `help:anchor(key, x, y, w, h)` for the
  regions it wants documented (currently `body`, which each page anchors
  over its own grid, canvas or browser). The call no-ops unless the
  overlay is open, so it costs nothing in the common case.

Anchors are frame-scoped: `help:beginFrame()` clears them and the same
frame's render repopulates, so a region that isn't drawn this frame (an
empty grid, a hidden segment) simply has no callout.

## What's where

The binding strings are never stored — `cmgr:keyLabels(cmd)` resolves
them live against the current scope stack, so the overlay can't drift
from the actual keymap. Membership is the manifest's too: every entry
declares the group it reads in (`docs/commandManager.md` § Manifest), so
the sheet holds no command list and a label is declared once.

A page registers *placement* alone (`help:registerPage(name, placements)`),
co-located with the render module that owns the layout. A placement names
a group and says where its box draws; the box's title is the group's name
and its rows are the group's entries in declared order, a generated family
collapsed to one row (§ A generated family). `help` buckets
the reachable surface (`docs/commandManager.md` § Surface) by group name,
so a group with no reachable entry draws no box — which is how one page's
placements ignore another page's commands, and how a modal scope thins
the sheet.

Each bound shortcut renders in its own keycap chip (`cmgr:keyLabelList`
feeds them, one chord per chip); a command with several bindings shows
several chips, `/`-separated. The chip frames the glyph so a lone-key
binding like `,` `.` or `` ` `` still reads as a key rather than a stray
mark; the square min is per symbol glyph (a narrow glyph in a chord reads as a
key too), while a run of word characters (Tab, F12) keeps its natural width.
Non-printable keys render as their macOS keycap glyphs (Return, Esc, Delete, …)
where the UI font has them — Tab/PgUp/PgDn and all of Windows/Linux stay words. Overlay colours are config roles (`colour.help.*`): a blue panel, with
description text and chip fills on the base ramp so the dark shortcut glyphs
and the `/` separator read against light keycaps.

Groups are `place = 'pin'` (a callout pinned beneath a toolbar segment)
or `place = 'flow'` (the grid cheat-sheet, filling the body rect row-major
— left to right, wrapping down a row at the rect's right edge).

Pins would collide where a callout is wider than its toolbar segment's
spacing. Rather than cascade them downward (crude — it displaces a box far
to dodge a small overlap), `placePins` slides them left/right into the
non-overlapping arrangement that *minimises total displacement* from each
box's wanted x. That's isotonic regression: subtracting each box's
cumulative width turns "no overlap, left-to-right" into "the reduced
positions must be non-decreasing", which pool-adjacent-violators solves
optimally in one pass. A single rigid shift then nudges the whole run
on-screen if an end pokes past the window edge.

## A generated family

The entries of a generated family (`docs/commandManager.md` § Manifest)
collapse to one row. The row reads the family's label, and its first and
last member's chords with a dash between — `⌘0 – ⌘9` for the tracker's ten
advance-by-digit commands, `0 – ⇧Z` for arrange's sixty-two place-slot
commands. A group holding a family therefore fits a box like any other.

The row's only edit is its mask. Clicking either chip captures one chord,
whose modifiers re-mask every member over its own base token, so a family
moves off `Ctrl` in a single gesture. There is no ✕ or `+`: a member holds
one chord, and the family is bound or it is not.

A mask is taken whole or not at all. Where any chord it would claim is
already spoken for, the sheet names that chord and its holder and rebinds
nothing; any key or click clears the prompt.

## Input while open

F1 is a root-scope command, reachable on every page, so it opens the
overlay regardless of which page-scoped bindings are live. While open the
overlay is dismiss-on-interaction: **any** key, or a mouse-down off the
callout boxes, closes it — and that gesture is *swallowed*, never reaching
the page underneath.

The keyboard is swallowed by ownership: the sheet owns the key queue for
every frame it was open at the start of (`docs/keyQueue.md § Ownership`),
so a press reaches no other reader, and dismissal claims the one it closes
on. The press that opened the sheet arrived on a frame no owner held, and
so cannot also close it. F1 closes the sheet as any other key does, the
dispatcher having no claim on it while the sheet owns the queue.

The mouse is swallowed per page: the tracker's grid, arrange's grid and the
wiring canvas skip their mouse passes while `help:wasOpenAtFrameStart()`.
Toolbar and param-palette ImGui widgets behind the overlay are *not*
blocked — true modality there would need a popup window; the dim plus the
swallowed grid and keyboard is the deliberate trade.

The overlay won't open over a modal dialog (it would cover its own
buttons), and won't open on a page that declared no manifest.

## Editing bindings

Clicking a binding in the open overlay turns it into an editor. The first
click *focuses* a command's row — only one at a time, to keep visual noise
down — revealing a ✕ tag over each keycap's top-right corner and a `+` tag
just past the row. From there: ✕ removes that binding, `+` captures a new
chord to append, and
clicking a keycap body re-captures it (replace). Clicking another row's
keycap just moves the focus, so rebinding several commands costs one click
each rather than a focus/exit dance.

Capture claims the next press and turns it, with the modifier mask that
press carries, into a `cmgr` keyspec. A key the command manager has no
binding token for is no chord: that press goes back to the queue, and
capture stays armed. Esc cancels
capture (leaving the row focused); Esc again leaves edit mode. While a row
is focused or capturing, the dismiss-on-key path is suspended — otherwise
the very keys being captured would close the sheet.

Edits go straight through `cmgr:rebind`, which writes the live keymap and
persists the change as hand-editable tokens; `bindingSite(cmd)` picks the
scope to write (the reachable scope that binds it, else its gate scope).

A captured chord that would clobber a reachable command (`commandAtKey`
finds the *victim*) raises a centred modal instead of binding silently:
"«chord» is «victim» / Reassign to «cmd»?" with Cancel and Reassign (Esc
cancels, Enter reassigns). Reassign strips the chord from the victim, gives
it to the command being edited, then drops the victim straight into a
*recovery capture* — "«victim» lost «chord» — press a new chord" — so the
displaced command can immediately reclaim a key (Esc leaves it unbound).
The recovery chord runs back through the same commit path, so if it in turn
clobbers a third command the warn prompt simply re-opens; the flow recurses
until a capture lands free or is cancelled. While a conflict prompt is up it
is modal: off-button clicks are swallowed, never dismissing the sheet.

Edit state persists across frames while the sheet stays open, but resets
whenever the overlay closes or the page changes, so reopening always starts
in plain view mode.
