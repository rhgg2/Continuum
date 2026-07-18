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

Segments declare their label as `heading` — the toolbar renders it through
`headingLabel` behind a disclosure triangle, so the label-to-control gap
is uniform by construction and every headed segment folds to its heading
alone. Folding to the heading rather than to a value summary is
deliberate: a summary repeats the control's own text at full width, so it
reclaims almost nothing — the fold exists to buy back row width. Folded
ids persist in the `toolbar.collapsed` config key (global tier). The
width cache needs no special case — a folded segment simply measures
narrower on its next frame and the row re-wraps.

Type-to-open must survive folding: before layout the toolbar peeks the
pending `requestPickerOpen` kind and re-expands a collapsed segment that
lists the kind in `pickers`, so the request still reaches a `drawPicker`
that can consume it.

## Vertical separator

`verticalSeparator` draws a filled 1px rect, not `DrawList_AddLine`: axis-aligned
rect edges skip ImGui's line anti-aliasing, so the rule stays crisp instead of
blurring across the pixel boundary.

## numberStepper

`numberStepper(id, value, opts)` is an InputInt (or InputDouble when `format` is set) with native step buttons suppressed, flanked by two frame-height-square -/+ buttons that hold-repeat via `ImGui.ItemFlags_ButtonRepeat`. It owns its own frame padding so it renders consistently under any ambient padding (e.g. the toolbar's wide 9 px): a fixed `BOX_PAD` inset for the box, and a `btnSz/2` inset that auto-sizes each button to exactly `btnSz` square.

The -/+ symbols are drawn as crisp axis-aligned filled rects on the window draw list, not font glyphs, so they sit dead-centre rather than riding the glyph baseline offset.

`align = 'center'` fakes text centring by computing `(boxW - textW) / 2` and using that as the left FramePadding inset, since InputText always left-aligns.

`onStep` overrides the default `±step` arithmetic, receiving `(currentValue, dir)` and returning the new value — used e.g. by the swing editor's `stepRpb` to walk a fixed ladder of valid row divisions.

## Picker

The generic typeahead picker (`drawPicker`) is shared across pages to avoid duplicating the popup/filter/keyboard logic. Each picker is identified by a `kind` string; filter text and cursor position are stored per kind so switching pages and back restores state. The `pickerActive` flag is frame-scoped: pages check it before consuming Enter so the picker's own Enter handler wins.
