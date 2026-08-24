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

The right-hand pane carries three tabs — **parameters** | **fx** | **map** —
sharing one child and one focus (`chrome.paletteTabsHeader`: equal-width cells,
the active label in text ink and the inactive ones dimmed, a crisp cell
divider). The active tab is *derived unless pinned*: `tv:paletteTab(caretKey,
fxAvailable)` returns a `tabOverride` (any of the three, set by a click or the
keyboard toggles) when one holds, else **fx** whenever a chain is showable — the
caret sits on an fx host, or a session is live (`stripPlan ~= nil`) — and
**parameters** otherwise. The derivation never yields **map**, the arrange
mini-map: a click alone brings it up, and it takes no keyboard focus. So a chain
auto-raises under the caret exactly as the old docked strip did, and lapses when
the caret leaves it. A mouse click on any tab pins it **without grabbing
focus**: the grid keeps the keys until you click into the pane (a param row, a
field label) or use the keyboard. The pin lapses on the next caret move — the
`tabOverride` generalises the old parameters-only override.

Two symmetric toggles bind the two panes: **Super-R** owns **parameters**,
**Super-X** owns the **fx** palette. Super-R (`focusParams`) parks parameters
over an auto-shown chain and lands on the find box (mirroring the Tab-to-find
idiom, so the child takes real keyboard focus and the reconcile keeps it);
pressed again — from the grid, or while parameters holds focus via
`handlePaletteKeys` — it drops the override, re-revealing the auto chain and
letting focus fall to the grid. The override is anchored to the caret and clears
on the next caret move (`tv:overrideTab` and the `caretKey` check in
`tv:paletteTab`). Super-X (`editFx`) enters the fx session; while parameters is
up it clears the override first, so Super-X always lands keyboard focus in the fx
palette — from the grid via `editFx`, or while parameters holds focus via
`handlePaletteKeys`, which raises `fxFocusReq`. A mouse click on the **fx** tab
instead only pins it (`onTab` → `tv:overrideTab`) without focus — the FX chain
section covers how it then shows and mints hostless. Symmetrically, inside a live fx
session `handleFxChainKeys` binds **Super-R** to commit-then-raise-parameters and
**Super-X** to commit-and-leave.

One pane, one focus: `drawParamPalette` forces `paletteFocus = nil` whenever the
active tab isn't parameters, so the fx tab runs on `stripFocus` alone and the
two panes never both wash the grid.

## The mini-map

The **map** tab draws the arrangement in the arrange page's own terms: one
column per track, time running down the page in QN (`docs/arrangePage.md` § Grid
is hand-drawn). An instance is a filled box in its slot's colour —
`chrome.slotFill`, the pair the arrange grid paints from, so a slot's colour
means one thing across the two — under the grid's own 1px border. The current
instance (`docs/trackerPage.md` § The current instance) carries the focused
fill. Nothing else is drawn: no notes, waveforms or names.

The boxes sit on a grid at the arrange page's cadence: a cell every 4 QN ruled
off, the bar (16 QN) and phrase (64 QN) cells tinted as the grid tints their
rows, and a rule down each column boundary. A third of a column of gutter runs
down the pane's left edge, with the grid running out into it and the first
column's rule closing it off. To the right it reaches as far as the track list
and no further, so the columns past the last track stay empty, and it sits under
the boxes, as it does there.

The window is fixed in scale and never scrolls — five track columns and a
third-column gutter across the pane's width, 3 pixels per QN down it. The renderer measures the pane in those
units and takes the window from `tv:mapWindow(cols, qnSpan)` in the
arrangement's own terms: the column and QN bounds, the takes over them (the
arrange facade's enumerator, `docs/arrangePage.md` § The take enumerator), and
the marked take. The pixels stay in the renderer, as they do for the grid's viewport
(`gridPane` hands `tv:setGridSize` cells and rows).

The window centres the bound track's column and clamps it at both ends, so a
track list shorter than the pane left-aligns. Time centres on the current
instance's midpoint, pulled back up to its start where the instance is taller
than the window, and clamped at QN 0. With the tracker in no instance nothing is
marked, and the edit cursor QN stands in for the midpoint.

## FX chain — palette tab

See `docs/generators.md` § The chain for what a chain means; this section is
its surface.

**Resist the DAG.** The surface is a list because the semantics are a comb:
sibling chains give parallel, the fold gives summing, order gives series. A
node canvas — the wiring page's own idiom — invites exactly the fan-out and
geometry-as-order those semantics forbid, and audio routing earns a DAG where
note fx does not. So borrow the wiring page's *chrome*, bypass badges
included, and never its canvas. No parallel blocks inside a chain either:
sibling chains already express that.

The chain draws
*inside* the palette child (`drawFxChainBody`; the tab header and chrome styles
are already pushed) as tree rows echoing the parameters tab: two action rows
(`clear` / `freeze` / `to group` / `commit` / `cancel`, then the catalogue's
`save` / `load`), then each stage top-to-bottom — a heading (the
swap picker, current kind flagged) with `↑`/`↓` reorder, `byp` and `del` aligned to
the value column's left edge, then one row per field: label left, `fxFieldWidget` in
a fixed column flush to the right margin — with a `↓` flow marker (a crisp rule split
around the arrow) between stages and a terminal **add** row. Both catalogue
pickers list `fxPatches` through `chrome.tierPicker` under the `Project` and
`Library` headings, in full and unresolved, so a name held in both tiers draws a
row under each and a pick carries the tier its row was drawn from. The
alternative, `libPicker`, builds a *resolved* list — one row per name,
answering "what will I get if I pick this" — which is the right question for an
artifact held by reference, a take naming a swing. A patch is instantiated by
copy and nothing names it once it has landed, so resolution serves no
reference here, and the shadowing it does meant the hidden copy could not be
picked, deleted, or told apart from a name with no twin at all. `save`
(`tv:saveFxPatch`) names the host's chain into whichever tier you picked or
created in — there is no separate publish, saving under `Library` being what
putting a patch where it travels with you means. It is disabled where the tab
stands hostless or the chain is empty, and mints no host of its own — that is
`add`'s job. `load` (`tv:loadFxPatch`) is the read half: it copies that row's
chain onto the host, replacing whatever chain it held, and parks the strip cursor
on stage 1. It is disabled only on an empty catalogue — where `save` refuses to
mint, `load` mints through `tv:fxHostForEdit` just as `add` does, so a bare
selection with the fx tab chosen loads onto a fresh region. `load`'s rows also
carry the catalogue's one piece of housekeeping: a two-press `×` deleting the
copy that row is showing (`tv:deleteFxPatch`), which leaves the same name in the
other tier standing and touches neither host nor chain.
Nothing filters the offered list: no kind declares a host it requires, so every
patch offers onto every host — including one naming a kind the registry has lost,
which draws a `? kind` heading with no field rows rather than faulting.
`stripFocus` gates `handleFxChainKeys` and highlights the cursor's row up to the
value column (the tree's selection fill, replacing the old ▸ marker).

**An interval takes two rows.** The `Interval` field's stored value is a cents
demand -- a trill's alternation, a fixed slide's target -- read as a step ladder
against the step the host note was written on, or against the notation's unison
where the host is a region and has no pitch of its own: the first row counts whole
steps, the second holds the cents no count reaches. Both rows write the one value,
so nudging the step row carries the residual with it rather than quantising it
away, and nudging the cents row past half a step re-reads as the step above with a
negative residual. Ctrl steps a period on the one row and ten cents on the other.

**One axis navigates, the other edits.** `stripCursor = {stage, param}` (param 0
= header) still keys the caret, but the whole chain flattens to a single column
(`chainRows`): **Up/Down** walk header → fields → the next stage's header as one
run. **Left/Right** *edit* the current row — nudging a field value (as `−`/`=`
do), or, on a header or the add row, opening the kind picker; the picker then
cycles on Left/Right too (`drawPicker` treats them as Up/Down). **Super+Up/Down**
reorder the stage and **Super+B** toggles its bypass — both act on the current stage
from any of its rows, and a bare letter can't serve here because a header row hands
every printable character to type-to-open; **Enter** activates the row — opening the kind picker on a
header/add row, the pattern editor on a pattern field, inert on a plain value;
**Super+X** commits from any row and leaves; **Delete/Backspace** removes a
stage; typing on a header/add row opens the picker seeded with that character. No
axis does double duty — the confusion of the old horizontal strip, where
Left/Right meant *navigate* on a header but *edit* on a field, is gone.

A bypassed stage **dims but never disables**: the kind label and the field labels go
`tracker.inactive` while every widget stays live, because the A/B gesture wants the
stage still editable — and `BeginDisabled` would block the mouse while the keyboard
path (`adjustRow` → `tv:setFxField`) sailed straight past it.

The keyboard session stays **transactional**: `editFx` (or a mouse click on a
field-row label) snapshots the chain (`stripSnapshot`) on entry and takes strip
focus; edits apply live as a preview; **Super+X**/`commit` keep them and leave, Esc/
`cancel` revert to the snapshot. A **mouse** edit — a value widget, a kind pick, or
an add — applies live *without* entering the session; it never grabs strip focus.

The **fx tab stands alone**: a click pins it (`tabOverride`) and `stripPlan` draws
a bare add row even on a host with no fx, so the tab needs no pre-existing chain.
The first `add` mints the host lazily — `host or tv:fxHostForEdit()`: the caret's
note wins, else a bare selection materialises its region. Only the keyboard
`editFx` mints **eagerly** and pops the add picker at once; there Esc aborts the
whole gesture (`cancelStrip`)
and the frame-end sink prunes the empty husk.
