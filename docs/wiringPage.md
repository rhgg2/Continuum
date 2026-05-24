# wiringPage

The wiring page is the coordinator citizen — render + input, talks
only to `wiringView` for graph state.

## Project-wide

`bind()` takes no take and never re-keys cm. The page is one of two
project-wide pages (arrange is the other); switching to / from
wiring leaves the tracker take and the sampler track unaffected.

## The page owns every pixel

Node-box geometry, port slot layout, drawlist calls — all here. wv
hands over `nodeViews` (label, audio/midi port counts) and the page
turns each one into a rect, port columns, and a label draw. Camera
state (when 1.3b adds it) is the only viewport-dependent thing that
lives in the view, because "what the user is looking at" is logical
state that has to survive a page-switch.

## Stage 1.3a — render only

No editing, no wiring-scope commands, no palette. The page draws
every node in the user graph (which is just `master` on a fresh
project), reserves the canvas area, and dispatches at end-of-body so
the global keychain still reaches commands. Selection, hover, drag,
palette, edge drawing, wire menu, and the error overlay arrive in
later 1.3 slices.
