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

The exception is a colour with no name to give it: the arrange grid's 62
slot fills are a golden-ratio hue *rotation*, a function rather than a
palette, so freezing them into config would be a lie. `painter.hue(idx,
sat, val, alpha)` computes one and returns it as an opaque `{u32}` token.
A draw method's colour argument therefore takes a name *or* such a token;
a bare int raises. That keeps the one legitimate escape — a genuinely
computed colour — from widening into "any int goes", which is the very
discipline the name rule exists to hold.

## What converts, what doesn't

Only positions pass through the transform. Stroke widths, corner radii
and font sizes are screen-space quantities and pass through unchanged —
a 2px outline is 2px regardless of where the canvas sits.

## Pixel snapping

The canvas origin lands on whole pixels: `ox`/`oy` round at construction, so an
integer logical coordinate — a column edge, a row boundary — draws on a pixel
boundary rather than smeared across two. `sx`/`sy` are left alone; a page may
scale by a fractional zoom (wiring does).

`snap = true` extends that to *every* converted position, rounding `toScreen`
output. The arrange grid sets it so a take edge at a fractional row — a
Shift-placed take that doesn't sit on a row boundary — still lands crisp.
`fromScreen` is never snapped: the hit-test wants the true sub-pixel logical
position under the cursor, not the rounded cell the draw pass chose.

## Clip and paths

`pushClip`/`popClip` take a rect whose corners convert like any other;
`intersect` defaults true (nest inside the current clip), pass false to
replace it. The path builder (`pathClear`, `pathLineTo`, `pathArcTo`,
`pathStroke`) draws open polylines with arc corners — the loop/tail
bracket. Points are logical and convert; an arc's radius is a screen-px
length like a corner radius, and its angles pass through unchanged, so an
arc is faithful only under uniform scale (`sx == sy`). Both bracket draws
sit in a screen-space gutter (identity painter), where that holds.

## Fonts

A font is a per-call argument, not a scoped block: `text` draws through
`AddTextEx` (the font goes to the draw call, no stack push). `measure`
is the exception — `CalcTextSize` has no font parameter, so measuring in
a given font means pushing it around the call. Pass the same `(font,
size)` to `measure` and `text` or the measured widths drift from the
drawn glyphs.
