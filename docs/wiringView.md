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

## wireView shape

`fromPort`/`toPort` are 1-based and always present. `fromPortName`/`toPortName`
are nil when the port has been trimmed off the node since the edge was recorded.
`fromOffset` is a custom-dragged source tag's position relative to its consumer
node, so the tag rides node moves without a separate update. `bus` is set on an
audio edge incident on a `kind='bus'` node — membership is purely structural,
with no separate claim or membership list. `bussedEnd` names which end sits on
the bus (`'to'` for the consumer side, `'from'` for the producer; the `to` end
wins when both).

## source bodies

A `kind='source'` node renders one of two ways. A **pure origin** (no audio
input, `audio.ins=0`) is *bodiless*: it has no node rect, and each of its
out-wires draws as a tag near its consumer (`category`/`fromKind` `'source'`).
A **folder parent** — a source that sums its children (`audio.ins>=1`, minted
by `readGraph`'s folderSinks branch) — is *bodied* like any other node
(`category`/`fromKind` `'folder'`): it needs a rect for its incoming child
wires to land on. `sourceCategory` is the single discriminant, consumed by
both `nodeView.category` and `wireView.fromKind`. The folder-bar display
(`design/wiring-folders.md` § Folder display) will later project the
`'folder'` category onto bar geometry; until then it draws as a plain rect.

## wireView fromKind/fromLabel

`fromKind` and `fromLabel` mirror the from-node's kind and label onto
the wireView so the page can render source-origin edges as stubs
without needing to hold or look up the full source nodeView. `fromKind`
is `'source'` only for a bodiless origin; a folder parent reports
`'folder'` so the page draws its out-wire as a normal wire (see § source
bodies). Port names are sourced identically to nodeView's port lists; a
name is nil if the referenced port has been trimmed off the node since
the edge was recorded.
