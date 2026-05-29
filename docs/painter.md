# painter

A drawlist binder shared by the canvas pages (wiring now; arrange and
tracker as they adopt it). It exists to dissolve three recurring pains
that UI code breeds: the `dl` threaded through every draw helper, the
`if font then Push…/Pop… end` guard repeated per call, and raw colour
ints passed around the call sites.

## One transform, draw and hit

`painter.new` is handed an affine transform — origin plus per-axis
scale. It keeps that as the single source for both the forward map
(`toScreen`, used by the draw methods) and its inverse (`fromScreen`).
A page's hit-test reads those off the same painter, so a glyph drawn at
a logical position and a click tested against it resolve through the
identical origin and scale. The classic UI bug — hit boxes that drift
from what's drawn because draw and hit each recompute the mapping — is
unrepresentable.

Per-axis affine (`screen = origin + logical * scale`) is enough for
every page; they differ only in origin and scale. tracker's existing
`printer` is the same idea at one fixed scale (the grid cell), which is
why `printer` is a later adopter rather than a separate mechanism.

## Colour by name only

Methods take colour *names* and resolve them through `chrome.colour`.
The project keeps colours in named config; resolving at the call site
and passing ints around (as wiring did) is the drift this closes.

## What converts, what doesn't

Only positions pass through the transform. Stroke widths, corner radii
and font sizes are screen-space quantities and pass through unchanged —
a 2px outline is 2px regardless of where the canvas sits.

## Fonts

A font is a per-call argument, not a scoped block: `text` draws through
`AddTextEx` (the font goes to the draw call, no stack push). `measure`
is the exception — `CalcTextSize` has no font parameter, so measuring in
a given font means pushing it around the call. Pass the same `(font,
size)` to `measure` and `text` or the measured widths drift from the
drawn glyphs.
