# chrome

`newChrome(cm, ctx)` is a UI utility factory: one instance per coordinator, threaded into every page.

## Why a separate module

Chrome was extracted from `continuum.lua` to keep that file focused on wiring. The chrome object holds all ImGui style/colour helpers and the shared typeahead picker — code that every page needs but that has no logical home in any single page.

## Colour resolution

Colours are looked up by name via `cm:get('colour.<name>')`. An entry can be an RGB(A) literal, a string alias to another key, or a two-element `{alias, alpha}` override. `resolve` walks the chain until it reaches a literal, letting the alpha override from the outermost alias win. Cycles raise with the full chain in the error message.

The resolved U32 values are cached on the chrome instance and flushed on `configChanged`.

## Picker

The generic typeahead picker (`drawPicker`) is shared across pages to avoid duplicating the popup/filter/keyboard logic. Each picker is identified by a `kind` string; filter text and cursor position are stored per kind so switching pages and back restores state. The `pickerActive` flag is frame-scoped: pages check it before consuming Enter so the picker's own Enter handler wins.
