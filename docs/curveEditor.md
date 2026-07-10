# curveEditor

A generic editor for piecewise (t, val) curves: hover, insert, move,
tension, delete, cycle. Domain-agnostic — events, projections, curve
evaluation, and write-back are all injected by the host per frame.

## Host-driven invalidation

Transient editor state (`drag`, `segPin`, `previewSuppress`)
straddles frames. The host knows when the editor's identity changes
(track switch, take switch, page switch); the editor does not. The
host passes a `dragId` each frame, and the editor drops cross-frame
state when it changes. The editor never asks "am I the same editor I
was last frame?" — the host answers.

## Sticky segment hover

Double-click on a segment cycles its shape. The shape change moves
the curve under the mouse, so the geometric hover test no longer
finds the segment the user just clicked, and a second double-click
would land somewhere else. `segPin` holds the target until the mouse
actually moves.

## Inert drag

Click-and-drag on a non-bezier segment must still consume the
input — otherwise ImGui's empty-area-window-move takes over and
drags the host window. The `inert` drag kind pins the gesture
without firing callbacks: pure suppression.

## Coordinate mapping

Both the draw pass and the hit-test go through one `painter` built per
frame from the lane rect — so a click resolves against the exact map a
glyph was drawn with, and the two cannot drift (see `painter.md`). Don't
re-hand-roll `t↔x` / `val↔y`; project through `pt.toScreen` /
`pt.fromScreen`.

painter's affine is *unclamped*, where the old `valToY` clamped val into
the lane. So the envelope and active-segment sample loops clamp val to
`[vMin, vMax]` at the sample site: without it a bezier that overshoots
its anchors would draw past the lane (the ±4px clip only hides a hair of
it). Keep the clamp where the samples are built.

## Step riser as a hover target

A step (or shapeless) segment holds its left anchor's value then jumps
vertically at the trailing anchor; that riser carries no curve value at
its x, so the nearLine insert branch (which tests the snap line, where
the anchor already sits) never finds it. The segment-hover pass detects
the riser explicitly so it is still a shape-cycle target.

## Snap vs. free move

Two move modes, two callbacks. Snapped (`onMove`) constrains t to
integer ticks strictly between neighbours; free (`onMoveFree`,
shift-held) is continuous with a `FREE_EPS_T` margin so the
strict-between-neighbours invariant holds at the floating-point
level. They are separate so hosts can treat them differently —
typically snapped writes commit and free moves preview.
