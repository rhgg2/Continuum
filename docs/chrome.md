# chrome

`newChrome(cm, ctx)` is a UI utility factory: one instance per coordinator, threaded into every page.

## Why a separate module

Chrome was extracted from `continuum.lua` to keep that file focused on wiring. The chrome object holds all ImGui style/colour helpers and the shared typeahead picker — code that every page needs but that has no logical home in any single page.

## Colour resolution

Colours are looked up by name via `cm:get('colour.<name>')`. An entry can be an RGB(A) literal, a string alias to another key, or a two-element `{alias, alpha}` override. `resolve` walks the chain until it reaches a literal, letting the alpha override from the outermost alias win. Cycles raise with the full chain in the error message.

The resolved U32 values are cached on the chrome instance and flushed on `configChanged`.

## Screen-space drawing

`chrome.screenPainter()` is the reach for drawlist work in screen space: an identity-transform painter over the current window's draw list, so a caller names its colours as every other painter does. Raw `GetWindowDrawList` and `DrawList_Add*` take integers where chrome takes names, and code written against them leaves the palette behind. The draw list is captured when the painter is built, so build one per draw function and call it in the window it paints.

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

## Status bar layout

`makeStatusBar()` returns a callable that renders a row of `statusSegment`
tables into the coordinator's footer child. A segment is data, not a render
closure: an id, an optional label, a declared pixel width, and a `get` read
fresh each frame. The renderer owns all the drawing, so a datum the spec
cannot express either grows the spec or stays in the toolbar.

Widths are declared, so the bar needs neither the pre-measure pass nor the
width cache the toolbar carries. Each cell is placed by explicit screen
position — `x` accumulates the declared widths and the separator gaps —
rather than by chaining `SameLine`. The rect is thus exact, and refreshed
each frame into `lastStatusRects` for `chrome.statusRects()`.

Inside a cell the label draws through `headingLabel` and the value takes the
width the label leaves, ellipsis-fitted by `fitLabel`. `headingLabel` dims
the ambient `Col_Text` rather than a fixed colour, so it reads correctly
against the toolbar's ink and the status bar's alike.

## Vertical separator

`verticalSeparator` draws a filled 1px rect, not `DrawList_AddLine`: axis-aligned
rect edges skip ImGui's line anti-aliasing, so the rule stays crisp instead of
blurring across the pixel boundary.

Its default ink is the `separator` swatch, shared with the tracker's grid
lines, arrange's table borders and wiring's list frames. Both chrome bands
pass their own colour instead: `dimText` takes the ambient `Col_Text` and
dims it, so a rule reads against the ground it is drawn on and the shared
swatch stays free to serve the grids. `headingLabel` dims the same way.

## numberStepper

`numberStepper(id, value, opts)` is an InputInt (or InputDouble when `format` is set) with native step buttons suppressed, flanked by two frame-height-square -/+ buttons that hold-repeat via `ImGui.ItemFlags_ButtonRepeat`. It owns its own frame padding so it renders consistently under any ambient padding (e.g. the toolbar's wide 9 px): a fixed `BOX_PAD` inset for the box, and a `btnSz/2` inset that auto-sizes each button to exactly `btnSz` square.

The -/+ symbols are drawn as crisp axis-aligned filled rects on the window draw list, not font glyphs, so they sit dead-centre rather than riding the glyph baseline offset.

`align = 'center'` fakes text centring by computing `(boxW - textW) / 2` and using that as the left FramePadding inset, since InputText always left-aligns.

`onStep` overrides the default `±step` arithmetic, receiving `(currentValue, dir)` and returning the new value — used e.g. by the swing editor's `stepRpb` to walk a fixed ladder of valid row divisions.

## Opening a field with a selection

1. `selectTo(n)` returns the `(flags, callback)` pair for one
   `InputText`, opening it with its first `n` characters selected. The
   callback is EEL, written and attached once; `n` travels through
   `Function_SetValue`, set immediately before the call that consumes
   it, so one function instance serves every caller.

1. The selection has to come from a callback, since ImGui selects the
   whole buffer when a field takes focus from `SetKeyboardFocusHere`.
   That select-all lands on activation, near the top of the widget's
   own frame, and the callback runs later in the same call.

1. The caller arms it and disarms on `IsItemActive`. A field is active
   exactly when the callback runs, so the two cannot come apart; leaving
   it armed would rewrite the selection every frame and pin the caret.

1. Only a field focused as its modal opens comes up with a selection.
   Overriding the caret on a click would fight the click, since someone
   clicking at the end of a name means to type there.

## Picker

The generic typeahead picker (`drawPicker`) is shared across pages to avoid duplicating the popup/filter/keyboard logic. Each picker is identified by a `kind` string; filter text and cursor position are stored per kind so switching pages and back restores state. The `pickerActive` flag is frame-scoped: pages check it before consuming Enter so the picker's own Enter handler wins.

`libPicker` takes a spec table (`{ key, current, excludeOthers, off }`) and builds the item list for a library-shaped cm key (`swings`, `tempers`, `fxPatches`) in three groups, in order: Off (nil key, suppressed by `off = false` — a catalogue written *into*, like the fx tab's `save`, has nothing to turn off); project entries (`cm.project[key]`, plain label, with a trailing ` •` badge when `lib.modified` reports the entry has diverged from its library source); and other entries present in the merged view but not yet localized to project (`+` prefix). `excludeOthers` filters names out of the third group only — used to hide `id` from the swing picker, which is already covered by Off. Each row also carries where it was drawn from and how that group announces itself: `tier` is `project` on a group-2 row and `global` on a group-3 one, with `groupLabel` `Project` and `Library` to match, and neither on Off, which is no tier. A group-3 row names the library tier even where only the factory catalogue carries the name: factory is a seed source, not somewhere a name resolves from, so such a row is a seeded one whose library copy has been deleted, and calling it `global` leaves its `×` a quiet no-op where `factory` would raise in `lib.delete`.

`tierPicker` builds the list for a catalogue held by *copy* rather than by reference — `fxPatches` — and is the other half of the same distinction. A take names a swing, so `libPicker` answers "what will I get if I pick this name" and resolves the tiers down to one row per name. Nothing names a patch once it has landed, so there is nothing for resolution to serve: `tierPicker` lists both tiers in full, from `lib.names`, and a name held twice draws a row under each heading. There is no Off row (a catalogue of copies has nothing to turn off) and no `+` prefix (the heading already says which tier), only the ` •` badge on a project row whose library twin differs — the one fact two identically-labelled rows do not tell you.

The popup is sized off the button it hangs from: `SetNextWindowSizeConstraints` floors its width at the button's and sets no ceiling, so it reads as that control's own drawer and still grows for a name too long to sit in it. Inside, horizontal item spacing is zero. ImGui otherwise extends a `Selectable`'s rect half a spacing past the content edge on each side, which stands every row wider than the filter field above and the rule under it; with the spacing gone all three share one span. Half a spacing then comes off the popup's horizontal `WindowPadding`, so the list still runs out to where that bleed used to carry it. The vertical bleed stays, and costs a pixel at the foot: ImGui measures content from a row's *text*, so the last highlight runs past where the window thinks its content ends and the bottom margin comes up short. A zero-height `Dummy` on that highlight's foot squares it with the sides. The rule is then lifted a pixel (`DIVIDER_LIFT`) out of ImGui's default gap, which hangs it nearer the first row than the field it divides from, and the row list is given the pixel back so only the rule moves — the give-back sitting with the rows rather than with the rule, since ImGui faults at `EndPopup` on a cursor moved past the content with no item submitted after it, and the Escape and Enter paths draw no rows at all.

A picker's rows are drawn in group blocks, each opening with its heading. Where the caller passes `groups` — an ordered `{ key, label }` list, as `chrome.tierGroups` is for the two tiers — those are the blocks; otherwise they are inferred from the items, one per distinct `group` in item order, taking the heading from the first item carrying a `groupLabel`. Declaring them buys one thing the inference cannot give: a group with no items still draws, which is how a tier standing empty still shows and can still be created into. A heading divides as well as it names, so only an unlabelled block takes a rule above it. Blocks scope their rows' ImGui ids by group key — two tiers holding one name draw two rows under one label, and ImGui faults on two visible items sharing an id, the same reason the editor's library tree pushes an id per tier.

`onCreate` adds a `+ new: <filter>` row at the head of *each* block when the typed filter is non-empty, and calls `onCreate(filter, groupKey)` — so a typed name lands in the group you pointed at rather than a default nothing states. Two rules make that safe. The create row leads its block rather than trailing it, because the cursor parks on row 1 whenever the filter changes: were it to trail, three letters and Enter would land on the first name they partly matched and overwrite it. And an exact-match filter suppresses only *its own* block's create row — the block holding the name offers the overwrite, the block lacking it still offers to create, which is what lets a name already in one tier be minted in the other. Callers that omit `onCreate` never see the row.

`onDelete` puts a trailing `×` on every item row with a non-nil key — so `libPicker`'s `Off` row and every create row stay plain — and it is two-press: the first click arms the row — its `×` turns red and a `?` appears after it — and only a second click on that same row calls `onDelete(key, tier)`, with the tier the item was stamped with, so the delete acts on the copy the row is showing and the same name in the other tier stands. Arming another row, changing the filter, or reopening the popup disarms; the armed key is per-kind state alongside the filter and cursor. Callers that omit `onDelete` draw no buttons at all. The two presses are deliberate where `onCreate`'s overwrite has no confirm: an overwrite is an explicit pick from a visible list, whereas the `×` sits a few pixels from the row you click to pick.

The `×` is two diagonals on the draw list over an `InvisibleButton`, not a font glyph — as in help's remove tag, that sizes it in pixels (`DEL_GLYPH`) and leaves no button frame behind it, and it takes its ink from `colour.chrome.picker.remove`, or `.armed` once the first click has landed. The armed `?` after it is ordinary row-font text, so the two need not match in size; its slot is reserved in the hit box whether armed or not, so arming never shifts the `×`. Placing the box flush right takes a correction: `SameLine` measures its offset from the *window* edge, not the content edge, so the offset has to carry the row's own left inset: `rowLeft - windowX + rowW - boxW`, with `rowLeft`/`rowW` read from the cursor and `GetContentRegionAvail` at the top of the row list. Hanging it off the Selectable's own rect instead is tempting — that is still the last item when the button is submitted — and was once fatal: a Selectable's rect ran half an `ItemSpacing` past the content edge, so a box at its right edge sat outside the content rect, grew the auto-sized popup by that much, and moved the edge it had been measured from, walking the `×` rightward a couple of pixels a frame forever. Zeroing the popup's horizontal spacing closes that trap, but the row is still what the offset should read. The row's `Selectable` needs `SelectableFlags_AllowOverlap` for any of it to be clickable: a full-width Selectable submitted first otherwise swallows every click aimed at the button drawn over it.
