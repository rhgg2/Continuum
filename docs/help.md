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
- **Body** — render code calls `help:anchor(key, x, y, w, h)` for the
  regions it wants documented (currently `body.grid`). The call no-ops
  unless the overlay is open, so it costs nothing in the common case.

Anchors are frame-scoped: `help:beginFrame()` clears them and the same
frame's render repopulates, so a region that isn't drawn this frame (an
empty grid, a hidden segment) simply has no callout.

## What's where

The binding strings are never stored — `cmgr:keyLabels(cmd)` resolves
them live against the current scope stack, so the overlay can't drift
from the actual keymap. A page's manifest carries only the *grouping*
and the human labels (`help:registerPage(name, groups)`), co-located with
the render module that owns both the layout and the bindings.

Groups are `place = 'pin'` (a callout pinned beneath a toolbar segment)
or `place = 'flow'` (packed into columns inside the body rect — the grid
cheat-sheet).

## Input while open

F1 is a root-scope command, reachable on every page, so it toggles the
overlay regardless of which page-scoped bindings are live. While open,
the coordinator forces root-only dispatch: page bindings go inert, but
transport, page-switch, and F1-to-dismiss keep working. Esc also closes,
handled inside `help:draw`. The overlay won't open over a modal dialog
(it would cover its own buttons), and won't open on a page that declared
no manifest.
