# editorPage / editorRender

The library workbench is its own page — the swing and temper editors
moved off the tracker's floating window onto a full page coord drives.
It is split in two, like every other page:

- **editorPage** is the controller coord drives. It constructs the two
  panes (`swingEditor`, `temperEditor`) and the renderer, publishes the
  `editor` facade, and delegates every render hook to the renderer. It
  is a coordinator, not a layer: it holds the panes directly and hands
  only them to the renderer.
- **editorRender** draws everything — the toolbar pane-selector, the
  body split (content pane + library tree palette), the status bar —
  and owns the pane-selection state. It is handed the two panes and
  never reaches cm/ds; what was discipline is structural, since cm/ds
  aren't in its scope.

The composite-editing model (how a swing is authored, single-path
writes, the snapshot, library tiers and seeding) lives in
`docs/swingEditor.md`. This file is the page around it.

## No take binding — it reads the take you came from

`bind`/`unbind` are no-ops; the page owns no take and re-keys no cm
tier. Yet the editors need take context — the take's current swing,
the cursor channel — to seed their default selection and fill the
Active folder. They borrow it: the panes read `ds` directly and the
last-bound take's grid through the `tracker` facade (`cursorAnchor`,
`timeSig`). So the workbench always edits the take you were last on in
the tracker, without binding to it or disturbing it. Switching to the
editor and back never moves the tracker take.

Pane state persists across visits because the page never tears it
down. `pane` is renderer module-local; leaving and returning lands you
on the same pane, same selection.

## Entry and exit

Three doors open it, all via commands that hold coord:

- `editSwing` (the tracker's swing `edit` button) — switch to the page
  on the Swing pane;
- `editTuning` (the tracker's temper `edit` button / menu) — switch on
  the Temper pane;
- the `E` page button in the coordinator chrome — switch with whatever
  pane was last shown.

`editSwing`/`editTuning` reach the `editor` facade's `edit(lib, name)`
fast path first — it sets the pane and selection — then call
`setActive('editor')`. Same shape as samplePage's diveToSampler: select
the target, then switch.

`closeEditor` returns to `coord:previousPage()` (falling back to
tracker) — the page that was active when the editor opened, so the
workbench feels like a modal layer over wherever you were.

The `Close (Esc)` toolbar button — and the page-level Esc that mirrors
it — exist **only on a tracker drop-in**. Arriving via `editSwing` /
`editTuning` sets a `droppedIn` flag (cleared on `unbind`); entering
standalone through F10 or the `E` page button leaves it clear, so the
editor reads as a first-class page with no dangling "close to where?"
affordance. The flag also gates the status-bar `· Esc returns` hint.

## The toolbar

Three zones, left to right: the **Swing / Temper** pane selector, the
**active pane's own tools**, and — on a drop-in — **Close (Esc)**. The
pane tools come from an optional `pane:renderToolbar()` hook: the swing
pane surfaces Rows/qn · Wild · Phase φ there, so they sit in the
chrome band at the pane buttons' height instead of floating above the
body at their own padding. A pane without the hook (temper, today)
contributes nothing between the selector and Close.

## Esc is guarded

Page-level Esc closes the page, but only on a tracker drop-in
(`droppedIn`) and only when nothing nearer wants it: not while a pane
sub-modal (the New-swing popup) is open, and not while an ImGui item is
active — so Esc still cancels an InputText edit or a slider drag before
it ever closes the page. The check sits in `renderBody`, before the
panes draw.

## focusState: page bindings off, root globals live

`focusState` always reports `pageSuppressed = true`: this page has no
tracker-style page command scope to keep alive, so page bindings stay
off while the root globals (quit, page-switch) stay live.
`suppressKbd` rises when a modal host, a picker, or a pane sub-modal is
open; `acceptCmds` is the gap where neither that nor an active ImGui
item is eating the keyboard. Dispatch runs *before* the panes draw so
`focusState` reads modal-active while it is still set — the same
ordering the tracker path uses, for the same reason.

## The library tree palette

The body splits into a variable-width content pane (the active editor)
and a fixed-width library tree on the right, mirroring arrange and
sampler. Each pane hands the renderer a `libraryTreeSpec` descriptor
every frame (`p:libraryDescriptor()`); the renderer draws it and routes
the row/button callbacks back into the pane. The renderer holds no
library state — it is a pure view over the descriptor.

Three folders, each a collapsible node:

- **Active** — the in-force entries for the current take: its take-wide
  swing plus every channel that carries an override, each row labelled
  by its column (`take`, `ch3`, …). Active is a *navigation lens*, not
  a tier: selecting a row resolves to the real tier (project or global)
  the named swing lives in, so the action bar acts on that tier, not on
  "active".
- **Project** — the swings/tempers this project carries (see
  `docs/swingEditor.md` § Library tiers for why picking one localises
  it here).
- **Global** — the personal library, lazily seeded from the built-in
  catalogue on first read.

The action bar (`add` / `dup global` / `dup project` / `reset` / `del`)
is scoped by the selected row's folder: promote shows only for a project
selection, demote only for a global one, and delete greys for a
synthetic floor entry or one a take still references (deleting it would
orphan the reference). `reset` reverts the selected entry's unsaved
edits to the snapshot; it appears only for panes that expose `onReset`
(swing), greyed until the composite actually differs.

## What's deferred

Shipped: the page skeleton and pane split, the swing editor, the
three-tier library tree with lazy global seeding and copy-on-assign
localisation, the Active/Project/Global navigation, and the
entry/exit/Esc plumbing.

Still ahead: the temper content pane (cents / period / per-step-name
authoring; temper `+New` lights up there), the Option-B nameless-step
display in `tuning.lua`, and Scala `.scl` import. If swing and temper
CRUD prove to genuinely overlap once temper authoring lands, the
library shell is the natural thing to extract.
