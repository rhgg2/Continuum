# chrome

`newChrome(cm, ctx)` is a UI utility factory: one instance per coordinator, threaded into every page.

## Why a separate module

Chrome was extracted from `continuum.lua` to keep that file focused on wiring. The chrome object holds all ImGui style/colour helpers and the shared typeahead picker — code that every page needs but that has no logical home in any single page.

## Colour resolution

Colours are looked up by name via `cm:get('colour.<name>')`. An entry can be an RGB(A) literal, a string alias to another key, or a two-element `{alias, alpha}` override. `resolve` walks the chain until it reaches a literal, letting the alpha override from the outermost alias win. Cycles raise with the full chain in the error message.

The resolved U32 values are cached on the chrome instance and flushed on `configChanged`.

## Toolbar layout

`makeToolbar()` returns a callable that renders a row of `toolbarSegment` tables.
Each segment is wrapped in `BeginGroup`/`EndGroup` so `GetItemRectMin/Max` measures
the whole group. The last-frame width per `id` is cached in the module-level
`toolbarWidths` table; before placing each segment the function checks whether
`lastEndX + sepW + cachedW` fits in the available width. If not, the leading
`SameLine` is skipped and ImGui wraps to a new line.

`resetToolbar` (exported; called by `coordinator` on every page switch from the
outgoing page's `unbind`) empties `toolbarWidths` so the next page re-measures
cold on its first visible frame and wraps correctly from the start. Only one page
draws per frame, so a single shared table never collides across pages.

On a cold frame (any uncached visible segment), `makeToolbar` runs a hidden
pre-measure pass (`Alpha 0`, cursor restored) to populate `toolbarWidths` before
the real layout. Without it the cold row lays out flat and the `AutoResizeY` child
jumps the body down on the following frame. Per-segment screen rects are refreshed
each frame into `lastToolbarRects` and read by the help overlay via
`chrome.toolbarRects()`.

## Picker

The generic typeahead picker (`drawPicker`) is shared across pages to avoid duplicating the popup/filter/keyboard logic. Each picker is identified by a `kind` string; filter text and cursor position are stored per kind so switching pages and back restores state. The `pickerActive` flag is frame-scoped: pages check it before consuming Enter so the picker's own Enter handler wins.
