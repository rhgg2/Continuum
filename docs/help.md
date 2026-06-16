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

## Input while open

F1 is a root-scope command, reachable on every page, so it toggles the
overlay regardless of which page-scoped bindings are live. While open the
overlay is dismiss-on-interaction: **any** key, or a mouse-down off the
callout boxes, closes it — and that gesture is *swallowed*, never reaching
the page underneath.

Swallowing spans three input surfaces that fire independently: the
coordinator suppresses command dispatch (`acceptCmds = false`), and the
tracker page skips its grid `handleMouse` and its note-entry `handleKeys`
(which read the key stream directly, bypassing dispatch) while
`help:wasOpenAtFrameStart()`. Dismissal is gated on the open-at-frame-start
flag so the F1 press that opens the sheet isn't also read as the keypress
that closes it. Toolbar and param-palette ImGui widgets behind the overlay
are *not* blocked — true modality there would need a popup window; the dim
plus the swallowed grid/keyboard is the deliberate trade.

The overlay won't open over a modal dialog (it would cover its own
buttons), and won't open on a page that declared no manifest.
