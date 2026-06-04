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

## Double-click intent

What a node does when double-clicked — dive to the sampler page, float an
fx window, or nothing — is a static property of the node, not of the cursor.
So it is classified once during projection (`nodeView.activate`) and the page
branches on that field directly, instead of probing wv twice per click to
discover it. This keeps the decision (logical, wv's) separate from the act
(side-effecting, wm's): the page reads `activate`, then calls the matching
action.

The sampler act binds to a MediaTrack, not an fx GUID, so `samplerTrack`
resolves the node's GUID to a live track via `wm:locateFx`. The page dives to
that track rather than carrying a GUID across the page boundary. `locateFx`
itself reads an index restamped each `applyOps` (see `docs/wiringManager.md`),
so neither the classification nor the resolution sweeps the project.

## What does not live here

No ImGui. No pixel geometry. No hit-testing. The page owns the
canvas — every rect, every drawlist call, every "what's under the
cursor" — and reads viewport-independent inputs from wv.

This split mirrors `arrangeView` / `arrangePage` and `trackerView` /
`trackerPage`: the page is the render + input surface; the view is
the manager-facing state.

## wireView fromKind/fromLabel

`fromKind` and `fromLabel` mirror the from-node's kind and label onto
the wireView so the page can render source-origin edges as stubs
without needing to hold or look up the full source nodeView. Port
names are sourced identically to nodeView's port lists; a name is nil
if the referenced port has been trimmed off the node since the edge
was recorded.
