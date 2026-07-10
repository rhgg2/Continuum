# trackerRender

WHY notes for the tracker page's render layer. The render layer owns all
ImGui/drawlist calls; `trackerView` holds the logical state it reads.

## Param palette — keyboard focus

The palette is a child pane (find box + an fx→param tree, params optionally
grouped into sections) sharing the
body region with the tracker grid. The grid is *not* an ImGui child window: it
reads keys through the command dispatcher, gated by `focusState().acceptCmds`,
which is false whenever an ImGui item is active.

Focus is a tri-state in `paletteFocus` (`'find' | 'tree' | nil`):

- **find** — the find `InputText` is the keyboard target. Typing filters;
  Left/Right edit the text (only while it holds text).
- **tree** — the param tree owns the arrows; no ImGui item is active.
- **nil** — the grid owns the keys.

`paletteFocus` feeds `acceptCmds` (and `handleKeys`), so grid bindings stay
quiet while the palette has focus. Because `drawParamPalette` runs *before*
`dispatch`/`handleKeys` in `renderBody`, the palette consumes its keys first
and the grid sees an already-suppressed frame — no double handling.

Up/Down always move the tree cursor: a single-line `InputText` ignores them,
so they can be claimed via `IsKeyPressed` even while the find box is active
(the same trick `chrome.drawPicker` relies on), clamped at the ends and
scrolling the row into view. Left/Right drive the tree only when not editing
find-box text. Enter on a param automates it, then clears the find box and
drops to the grid; Esc clears and drops without automating — both via the sink.
The drop is deferred to the sink one frame later so the same Enter/Esc keystroke
isn't seen by the grid dispatcher (which would otherwise toggle to arrange).
Super-L arms/cancels learn on the cursor's fx, on the heading or one of its
params.

### The focus sink

An `InputText`, once active, stays active until ImGui moves focus elsewhere.
To leave the find box without a click (Tab→tree, Esc→grid) we park focus on a
1px invisible button — `SetKeyboardFocusHere` before it deactivates the input.
The grid then works purely through the dispatcher; it never needs ImGui window
focus, only the absence of an active item plus `paletteFocus = nil`. The sink
sits near the top of the pane so scrolling never culls it out of submission.

### Filtering

A non-empty find box prunes the tree to fx subtrees holding a matching param,
each forced open for that frame only. The needle matches against fx name,
section name, and param name. `paletteExpanded` is never touched, so clearing
the box restores the prior expansion for free. While filtering the cursor
visits matched params only — the fx headings still show but aren't navigable or
togglable, and the per-fx learn button is hidden.

### Parameter sections

VST3/CLAP plugins can tag each param with a unit/module name
(`TrackFX_GetParamSectionName`, empty when unsupported). `buildPlan` partitions
an fx's params into those sections as non-navigable heading rows. The grouping
is a *stable partition* of the already-frecency-ordered list, so a hot param
still floats within its own section; sections themselves order by their first
param index so they don't reshuffle as frecency moves. An fx reporting no
sections renders flat; unsectioned params under a mixed fx collect in a trailing
“(ungrouped)” group. All param labels share one indent column just past the
fx-name / section-heading column, so flat and grouped fx line up.

Frecency is keyed by param *index*, not name (`paramAutomation`), so
identically-named params — ReaEQ's eight “Freq” — score independently. The
transient touch-learn hoist was already index-keyed; this aligns the persisted
scores with it.

## Palette tabs

The right-hand pane carries two tabs — **parameters** | **fx** — sharing one
child and one focus (`chrome.paletteTabsHeader`: equal-width cells, the active
label in text ink and the inactive one dimmed, a crisp cell divider). The active
tab is *derived*, not stored:
`tv:paletteTab(caretKey, fxAvailable)` returns **fx** whenever a chain is
showable — the caret sits on an fx host, or a session is live (`stripPlan ~=
nil`) — and **parameters** otherwise. So a chain auto-raises under the caret
exactly as the old docked strip did, and lapses when the caret leaves it.

Two symmetric toggles bind the two panes: **Super-R** owns **parameters**,
**Super-X** owns the **fx** palette. Super-R (`focusParams`) parks parameters
over an auto-shown chain and lands on the find box (mirroring the Tab-to-find
idiom, so the child takes real keyboard focus and the reconcile keeps it);
pressed again — from the grid, or while parameters holds focus via
`handlePaletteKeys` — it drops the override, re-revealing the auto chain and
letting focus fall to the grid. The override is anchored to the caret and clears
on the next caret move (`tv:overrideParams` and the `caretKey` check in
`tv:paletteTab`). Super-X (`editFx`) enters the fx session; while parameters is
up it clears the override first, so Super-X always lands keyboard focus in the fx
palette — from the grid via `editFx`, or while parameters holds focus via
`handlePaletteKeys`, which raises `fxFocusReq`. Symmetrically, inside a live fx
session `handleFxChainKeys` binds **Super-R** to commit-then-raise-parameters and
**Super-X** to commit-and-leave.

One pane, one focus: `drawParamPalette` forces `paletteFocus = nil` whenever the
active tab isn't parameters, so the fx tab runs on `stripFocus` alone and the
two panes never both wash the grid.

## FX chain — palette tab

See design/note-macros-v2.md § The chain surface for the model. The chain draws
*inside* the palette child (`drawFxChainBody`; the tab header and chrome styles
are already pushed) as tree rows echoing the parameters tab: an action row
(`clear` / `commit` / `cancel`), then each stage top-to-bottom — a heading (the
swap picker, current kind flagged) with `↑`/`↓` reorder and `del` aligned to the
value column's left edge, then one row per field: label left, `fxFieldWidget` in a
fixed column flush to the right margin — with a `↓` flow marker (a crisp rule split
around the arrow) between stages and a terminal **add** row.
`stripFocus` gates `handleFxChainKeys` and highlights the cursor's row up to the
value column (the tree's selection fill, replacing the old ▸ marker).

**One axis navigates, the other edits.** `stripCursor = {stage, param}` (param 0
= header) still keys the caret, but the whole chain flattens to a single column
(`chainRows`): **Up/Down** walk header → fields → the next stage's header as one
run. **Left/Right** *edit* the current row — nudging a field value (as `−`/`=`
do), or, on a header or the add row, opening the kind picker; the picker then
cycles on Left/Right too (`drawPicker` treats them as Up/Down). **Super+Up/Down**
reorder the stage; **Enter** activates the row — opening the kind picker on a
header/add row, the pattern editor on a pattern field, inert on a plain value;
**Super+X** commits from any row and leaves; **Delete/Backspace** removes a
stage; typing on a header/add row opens the picker seeded with that character. No
axis does double duty — the confusion of the old horizontal strip, where
Left/Right meant *navigate* on a header but *edit* on a field, is gone.

The keyboard session stays **transactional**: `editFx` (or a mouse click on a
field-row label) snapshots the chain (`stripSnapshot`) on entry and takes strip
focus; edits apply live as a preview; **Super+X**/`commit` keep them and leave, Esc/
`cancel` revert to the snapshot. A mouse edit of a value widget, by contrast,
applies live without entering the session — it never grabs strip focus.
Opening `editFx` on an **empty** chain — a note
host with no fx, or a selection that mints a fresh region — pins the host and
pops the add picker at once; Esc there aborts the whole gesture (`cancelStrip`)
and the frame-end sink prunes the empty husk.
