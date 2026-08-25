# status bar — declarative fixed-width segments

> opened: 2026-07-08 · status: in flight — see `plan/status-bar.md`
>
> Working design doc.

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

The segment spec, the layout, the edit machinery and the focus gate all
landed: see `docs/chrome.md` § Status bar layout and § Editing a status cell.
The page protocol — `statusSegments()` where `renderStatusBar(ctx)` stood —
is the `--shape: page` line in `coordinator.lua`, and the `status.<id>` help
anchors are in `docs/help.md` § What's where.

### Per-page content

| page    | display segments            | editable segments |
|---------|-----------------------------|-------------------|
| tracker | col label · bar:beat.sub    | octave · advance · rpb (from toolbar) · sample (from toolbar, `pick`) |
| arrange | row · col · trim · REPLACE  | beats-per-row (from toolbar) · advance |
| wiring  | page name                   | zoom factor (later) |
| sample  | track · slot                | — |
| editor  | pane text, one segment      | — |

All of this is on screen; arrange's two editable cells are what remains.
`followPlay` stays in the arrange toolbar — it's a mode toggle, not a datum,
and wiring's zoom factor waits until wiring has a zoom.

## Plan

See `plan/status-bar.md`.
