# Algebra

**Two stateless modules hold the ppq geometry the tracker stack derives
over: `spans.lua` for half-open interval sets, and `curves.lua` for
ppq-keyed breakpoint curves and their fold. Both are pure functions over
their arguments; `spans` depends on `util` alone, `curves` on `util` and
`spans`, and the arrow between them runs one way.**

## Spans

1. A **span** is a half-open interval `[lo, hi)`, and a **span set** is
   a list of them, disjoint and ascending. Half-open is the convention
   `util`'s window seeks already use (`docs/util.md`), so adjacent spans
   tile without double-counting.

1. `merge` coalesces a list into a span set, joining at a touch as well
   as at an overlap; `clip` and `subtract` are the two halves of cutting
   a span against a set. Every span returned is freshly built, so no
   caller's span is aliased into a result.

1. Two of the six names read a `window` field off a record, so a caller
   holding a bucket of generator chains passes the bucket itself. That
   is the only project shape either module knows.

## Curves

1. A **curve** is a list of breakpoints ascending in ppq, each carrying
   a value and, on the curved shapes, a tension. A breakpoint's shape
   governs the segment leaving it, which is REAPER's convention, and a
   curve is held both ways: its first value stands before it and its
   last after it.

1. `eval` reads the value at a ppq and `slice` cuts a curve to a span.
   `interpolate` gives one breakpoint pair's value at a ppq, and the
   shape functions sit under it; the view reaches it through
   `tm:interpolate` and `vm:sampleCurve` (`docs/trackerView.md`,
   `docs/trackerPage.md`).

1. `sumStreams` sums a held base curve with the macro curves over it,
   and `foldChains` folds the chain records covering a span into one
   curve under the replace and augment modes. The fold is the piece with
   real content, and its one call to `spans` is the only one either
   module makes; its semantics are the generator model's, in
   `docs/generators.md` § Multiplicity.

## Configuration stays with its reader

1. No name in either module reads `cm` or the take, which is what keeps
   them a library the project depends on. trackerManager keeps `pbLim`,
   `centsToRaw` and `rawToCents`, which read `cm:get('pbRange')`, and
   `ccGridStep`, which reads the take's resolution and its CC-interp
   setting.

1. So the fold takes its densify step as a parameter and returns
   unrounded values: each emission site rounds and clamps in its own
   units — raw pb, cc byte, cents.
