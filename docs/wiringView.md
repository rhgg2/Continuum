# wiringView

The logical view layer for the wiring page. Owns the `wiringManager`
instance; the page goes through wv for every graph query and (in
1.3b+) every mutation.

## What lives here

The view carries the user graph and the per-session pointers into it:
which node is hovered, which is selected. These are nodeIds, not
pixels — wv has no idea where on screen a node is drawn. Camera
(pan/zoom) joins this set when 1.3b adds drag.

It also projects the raw graph into render-ready descriptors
(`nodeViews`): label string and audio/midi port counts per side. That
projection is viewport-independent: the page needs port counts to
size a box but does not need to recompute "master has zero MIDI" per
frame, and the rule lives with the graph model, not with the renderer.

## What does not live here

No ImGui. No pixel geometry. No hit-testing. The page owns the
canvas — every rect, every drawlist call, every "what's under the
cursor" — and reads viewport-independent inputs from wv.

This split mirrors `arrangeView` / `arrangePage` and `trackerView` /
`trackerPage`: the page is the render + input surface; the view is
the manager-facing state.
