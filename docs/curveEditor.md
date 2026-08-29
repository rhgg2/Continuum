# curveEditor

**A generic editor for piecewise (t, val) curves, driven entirely by
its host.**

## The host drives the frame

1. `frame` is the editor's whole surface: the host calls it once per
   UI frame, and it draws the curve and handles the mouse in one pass.

1. Everything the editor works with arrives as its arguments — the
   events, the projections between curve space and screen, the curve
   evaluation, and the callbacks that carry insert, move, tension,
   delete and shape-cycle back to the document.

1. `dragId` is the curve's identity, supplied by the host each frame.
   A gesture that straddles frames (`drag`, `segPin`) is dropped when
   it changes. The tracker lane passes the column index.

## One transform per frame

1. A `painter` instance translates between curve space — t along the
   horizontal, val up the vertical — and the screen. It is built each
   frame from the rect and the ranges the host passes (`painter.md`).

1. Drawing and hit tests both go through it, so a click resolves
   against the same map the glyph was drawn with.

1. The map is affine and unclamped, so a bezier that overshoots its
   anchors projects above or below the rect.

1. The curve reaches the screen as a polyline sampled at about one
   point per pixel. Each sample's val is clamped to `[vMin, vMax]` as
   it is taken.

1. Drawing is clipped to the rect grown by 4px in screen space, so an
   anchor sitting on the edge draws whole.

## Double-click latches at the click position

1. A double-click changes the curve under a stationary mouse, so the
   geometric tests that chose the target no longer find it. Both
   double-click gestures therefore latch their outcome at the click
   position, and release it when the mouse moves.

1. Shape-cycle pins its segment in `segPin`, so a repeated
   double-click keeps cycling the same segment as the curve moves
   beneath it.

1. Delete records the position in `previewSuppress`, which holds the
   insert preview off. The mouse is left sitting on the curve where
   the anchor was, which is just where the preview offers itself.

## Inert drag

1. ImGui moves a window when a drag begins on its empty area, so the
   editor claims every drag that starts inside its rect. `frame`
   returns whether it consumed the mouse.

1. Only a bezier segment has a tension to drag, so a click-drag on any
   other segment is claimed by the `inert` drag kind, which fires no
   callback.

## Step risers are hit tested directly

1. The hover pass tests step risers explicitly, before the tests that
   find other segments, so a riser is a shape-cycle target like any
   other segment.

1. A step segment — or one with no shape — holds its left anchor's
   value across the segment, then jumps vertically at the trailing
   anchor.

1. At the riser's x the curve's value is still the left anchor's, so
   the proximity test that finds other segments passes over the
   vertical run.

1. The riser also stands on a snap line, where the pass looks for a
   free insert position, and the trailing anchor occupies that one.

## Snapped and free moves

1. A dragged anchor never crosses its neighbours: t is confined
   strictly between the anchors on either side before any move is
   reported.

1. Without shift, t takes integer values only, and the move is
   reported to `onMove`. With shift held it is continuous and goes to
   `onMoveFree`, kept a `FREE_EPS_T` margin clear of the neighbours so
   that "strictly between" survives in floating point.

1. Shift frees t alone. val is rounded to an integer and clamped to
   `[vMin, vMax]` in both modes.

1. A snapped drag moves t only once the mouse has travelled away from
   where the drag began, or from where t last snapped, and then only
   in that direction. The anchor holds its tick under small movements.

1. No move is reported until the mouse has moved a pixel from where it
   was pressed, so a click that does not drag leaves the anchor where
   it is.

## Tension

1. Dragging a bezier segment sets its tension. The mouse delta is
   projected onto the perpendicular of the chord between the two
   anchors, captured at the moment of the click.

1. A perpendicular displacement equal to the rect's height covers the
   whole range, and τ is clamped to `[-1, 1]`.

1. The perpendicular's orientation is taken from the sign of the
   chord's gradient, so the drag that pulls the curve toward the left
   anchor's value raises τ on a rising and a falling segment alike.
