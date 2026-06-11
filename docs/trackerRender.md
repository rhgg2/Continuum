# trackerRender

WHY notes for the tracker page's render layer. The render layer owns all
ImGui/drawlist calls; `trackerView` holds the logical state it reads.

## Param palette — keyboard focus

The palette is a child pane (find box + a two-level fx→param tree) sharing the
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
each forced open for that frame only. `paletteExpanded` is never touched, so
clearing the box restores the prior expansion for free. While filtering the
cursor visits matched params only — the fx headings still show but aren't
navigable or togglable, and the per-fx learn button is hidden.
