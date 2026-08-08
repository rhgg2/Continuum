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

`libPicker` takes a spec table (`{ key, current, excludeOthers, off }`) and builds the item list for a library-shaped cm key (`swings`, `tempers`, `fxPatches`) in three groups, in order: Off (nil key, suppressed by `off = false` — a catalogue written *into*, like the fx tab's `save`, has nothing to turn off); project entries (`cm.project[key]`, plain label, with a trailing ` •` badge when `lib.modified` reports the entry has diverged from its library/factory source); and other entries present in the merged view but not yet localized to project (`+` prefix). `excludeOthers` filters names out of the third group only — used to hide `id` from the swing picker, which is already covered by Off. Each row also carries where it was drawn from: `tier` is `project` on a group-2 row and `global` (or `factory`, for a name only the factory floor carries) on a group-3 one. `publishable` is set on a project row whose name the library tier lacks or holds a divergent copy of — that is, on exactly those rows where a publish would change the library.

`onCreate` on a pickerSpec adds a synthetic '+ new: <filter>' row when the typed filter is non-empty and matches no item label exactly; Enter on that row calls `onCreate(filter)` instead of `onPick`. An exact-match filter suppresses the row, so Enter falls through to the normal overwrite-via-`onPick` path. Callers that omit `onCreate` never see the row.

`onDelete` puts a trailing `×` on every row with a non-nil key — so `libPicker`'s `Off` row and the synthetic create row stay plain — and it is two-press: the first click arms the row — its `×` turns red and a `?` appears after it — and only a second click on that same row calls `onDelete(key, tier)`, with the tier the item was stamped with, so the delete acts on the copy the row is showing. Arming anything else, changing the filter, or reopening the popup disarms; the armed slot is per-kind state alongside the filter and cursor, and carries an action as well as a key, because two glyphs now share it. Callers that omit `onDelete` draw no buttons at all. The two presses are deliberate where `onCreate`'s overwrite has no confirm: an overwrite is an explicit pick from a visible list, whereas the `×` sits a few pixels from the row you click to pick.

`onPublish` puts a `↑` on those rows alone that the item list marked `publishable`, and it is two-press on the same slot: arming the `↑` disarms the `×` beside it, and a second click on that `×` then only re-arms it. It is drawn one button width left of the `×`, which keeps the flush-right slot; a picker offering publish without delete gives the `↑` that slot instead. The guard is the picker's own rather than a confirm modal because the gesture happens inside a live ImGui popup, where a modal opening over it is untested — and because publishing over a divergent library copy destroys content no undo point covers, a config write minting none.

Why hide the `↑` where a publish would change nothing? Because such a publish leaves no other mark: no `•` badge appears or goes, so the `↑` vanishing is the whole of the gesture's feedback. What the reader has to go on is the prefix — `wobble` is the project's copy, `+ wobble` the library's — and the prefix rides every row whether or not a filter is active, where the group separator does not. One gap follows and is accepted rather than built for: a project row with a *pristine* library twin looks exactly like one with no twin at all, so nothing distinguishes a `×` that leaves a copy behind from one that takes the name away. Closing it would cost a second badge in `libPicker`'s vocabulary, which the swing and temper pickers share and neither needs; the outcome is the least destructive one, and the row reappearing as `+ wobble` says so a moment later.

Both glyphs are strokes on the draw list over an `InvisibleButton`, not font glyphs — the `×` two diagonals, the `↑` a stem and two head strokes. As in help's remove tag, that sizes them in pixels (`DEL_GLYPH`) and leaves no button frame behind them; at rest they take their ink from `colour.chrome.picker.remove` and `.publish`, and armed, both from `.armed`. The colour keys name the state rather than the gesture, the armed ink being shared. The armed `?` after the glyph is ordinary row-font text, so the two need not match in size; its slot is reserved in the hit box whether armed or not, so arming never shifts the glyph. Placing the box flush right takes two corrections. `SameLine` measures its offset from the *window* edge, not the content edge, so the offset has to carry the row's own left inset: `rowLeft - windowX + rowW - boxW`, with `rowLeft`/`rowW` read from the cursor and `GetContentRegionAvail` at the top of the row list. And the box must *not* be hung off the Selectable's own rect, tempting as that is (it is still the last item when the button is submitted): a Selectable's bb is deliberately extended half an `ItemSpacing` past the content edge, so an item placed at its right edge sits outside the content rect, grows an auto-sized popup by that much, and moves the edge it was measured from — the `×` walks off to the right, a couple of pixels per frame, forever. The row's `Selectable` needs `SelectableFlags_AllowOverlap` for any of it to be clickable: a full-width Selectable submitted first otherwise swallows every click aimed at the button drawn over it.
