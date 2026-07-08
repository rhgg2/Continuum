# status bar — declarative fixed-width segments

> Working design doc. Approved in principle 2026-07-08; not yet started.

## Status

Proposed. No code yet.

## Problem

The status bar is a fixed-height footer child owned by the coordinator
(`coordinator.lua` § status band), which calls `page:renderStatusBar(ctx)`.
Every page implements that as an ad-hoc `ImGui.Text` printf — display
only, no interaction, no shared structure. Meanwhile values that belong
in a compact per-datum strip (rpb, sample) sit in the toolbar, which is
built for wider composite segments (pickers with headings, multi-control
groups).

The toolbar already proves the declarative-segment idiom: pages expose
`toolbarSegments()` → `{ id, render, visible? }`, and
`chrome.makeToolbar()` owns layout, separators, width caching, and help
rects. But toolbar segments carry *render closures*. The status bar goes
one step further: segments are **data** — a flat spec with callbacks,
like a JS input field — and the renderer owns all drawing.

## Design

### Page protocol

`renderStatusBar(ctx)` leaves the page shape; `statusSegments() -> table`
replaces it, mirroring `toolbarSegments()`. The coordinator renders the
footer through a shared `chrome.makeStatusBar()`. Pages declare their
segment table once at module scope; `get`/`set` closures read `cm`/`tv`
fresh each frame, exactly as toolbar render closures do today.

### Segment spec

```lua
--shape: StatusSegment = {
--  id: string, label: string?, width: px,
--  get: fn() -> value,
--  format?: string | fn(v) -> string,     -- display text; default tostring
--  visible?: fn() -> bool,
--  set?: fn(v),                           -- presence makes it editable
--  edit? = { kind = 'number', min, max, step?, format? }
--        | { kind = 'pick', items = fn() -> pickerItems }
-- }
```

No render code in a segment, ever. If a datum can't be expressed in this
spec, the spec grows a field or the datum stays in the toolbar.

### Rendering

Fixed-width cells laid left-to-right in declared order, separated by
`chrome.verticalSeparator`, inside the existing footer child (colours
`statusBar.bg` / `statusBar.text` unchanged). Each cell: dimmed label in
`headingLabel` style, then the value. Value text runs through
`chrome.fitLabel` so a long sample name truncates instead of blowing the
cell. Widths are declared, so no measure pass or width cache — that
machinery stays toolbar-only.

Cells record their rects (à la `lastToolbarRects`) and expose them as
`status.<id>` help anchors.

### Edit interaction — uniform across all editable segments

- **display-only** (`set` absent): plain text.
- **`kind = 'number'`**: renders as text. Click swaps in an `InputText`
  sized to the cell, content selected; Enter commits through `set`
  (clamped to min/max), Esc cancels. Mouse-wheel over the cell steps by
  `step` without entering edit mode. No ± buttons — they'd eat the fixed
  width; `chrome.numberStepper` remains a toolbar widget.
  - Integer fields (`octave`, `advance`, `rpb`) step ±1 and commit live
    on wheel — `tv:setRowPerBeat` already absorbs per-click changes in
    the toolbar today.
  - Fractional zoom-like fields (`beatsPerRow`, later wiring zoom) parse
    `0.25`-style input and wheel-step by **double/halve** rather than
    ±1: `step = 'x2'` in the edit spec selects this. min ¼, `%g` display.
- **`kind = 'pick'`**: click opens `chrome.drawPicker` with
  `items()` — sample keeps its typeahead popup for free.

### Focus

An active status edit must stop grid keys firing. Pages already fold
`chrome.pickerIsActive()` into `focusState`; add
`chrome.statusEditActive()` alongside it and gate the same way. Chars
typed into the InputText follow the existing picker idiom, which already
handles the two-input-streams gotcha (IsKeyPressed vs char queue).

Note the frame ordering: `dispatch(focusState)` fires at end-of-body,
*before* the coordinator draws the status bar. `statusEditActive()`
therefore reports last frame's edit state on the frame an edit begins —
same one-frame latency the picker gate already has; acceptable.

### Per-page content

| page    | display segments            | editable segments |
|---------|-----------------------------|-------------------|
| tracker | col label · bar:beat.sub    | octave · advance · rpb (from toolbar) · sample (from toolbar, `pick`) |
| arrange | row · col                   | beats-per-row (from toolbar) · advance |
| wiring  | page name                   | zoom factor (later) |
| sample  | track/slot text, one segment| — |
| editor  | pane text, one segment      | — |

`followPlay` stays in the arrange toolbar — it's a mode toggle, not a
datum.

### Help migration

Tracker F1 pins anchored at `toolbar.rowsPerBeat` / `toolbar.sample`
move to `status.rpb` / `status.sample`. `help.lua`'s anchor resolution
grows the `status.<id>` family next to `toolbar.<id>`.

## Plan

1. **`chrome.makeStatusBar()`** — cell layout, display rendering,
   number edit (click-to-edit + wheel), pick kind, rect recording,
   `statusEditActive()`. Sibling of `makeToolbar` in `chrome.lua`.
2. **Coordinator** — instantiate the shared status bar; footer child
   calls it with `page:statusSegments()`; drop `renderStatusBar` from
   the page shape annotation.
3. **Tracker page** (proving ground) — declare segments; delete
   `drawStatusBar`; remove `rowsPerBeat` and `sample` toolbar segments;
   migrate help pins.
4. **Arrange** — segments incl. beats-per-row migration (`x2` wheel);
   remove the toolbar `beatsPerRow` segment.
5. **Wiring / sample / editor** — trivial display segments.
6. **Spec** — wired-behaviour spec through the real coordinator→chrome
   path: segment renders declared value, edit commit calls `set`,
   Esc cancels, wheel steps clamp, `statusEditActive` gates focusState.
   ImGui stubbed at the surface only.

Steps 1–3 land together (the bar is unusable without a page driving
it); 4–6 can follow independently.
