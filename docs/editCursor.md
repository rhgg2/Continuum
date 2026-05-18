# editCursor

Caret, selection, and clipboard over the trackerView grid. Two
factories — `newEditCursor` and `newClipboard` — share the file because
the clipboard *is* the cursor's reach beyond a single position; both
take the same `grid`/`cm` deps and the clipboard composes the cursor
for region access.

editCursor owns no MIDI or take state. It mutates only its own caret
and selection; data writes go through `tm`/`cm`.

## The selection model

A selection is **anchor + cursor + scopes**. The anchor is the fixed
end, the cursor is the moving end, and the resolved rect (`sel`) is
recomputed from the three on every move.

**Sticky scopes are orthogonal.** Horizontal extent (`hBlockScope`:
free / col / channel / all-cols) composes with vertical extent
(`vBlockScope`: free / beat / bar / all-rows) without one collapsing
the other. The user can hold a whole-channel-wide selection and still
extend it row by row, or vice versa.

`sel == nil` iff there is no selection. A few callers (`region`,
`regionStart`, `eachSelectedCol`) degenerate to a 1×1 cursor rect when
no selection is active, so the caller doesn't have to special-case
"selection or just the cursor". `hasSelection()` is the bit when that
distinction matters.

## Part-typed regions

A grid col has heterogeneous parts (note pitch / note vel / cc val /
delay). An op like vel-paste has to land on the *vel* part across all
selected cols, even though those cols may have different stop-position
layouts.

So regions carry `part1` and `part2` (part names) rather than just
stop indices. Cross-col semantics stay stable even when stop-positions
diverge. On boundary cols, `selectionStopSpan` narrows to the named
part; on interior cols it falls through to the whole col.

**The `'*'` sentinel.** Whole-channel and whole-row scopes (HBlock=2/3)
set `part1=part2='*'`, a name no real part matches, so
`selectionStopSpan` falls through to whole-col by default. This is the
trick that lets the same code path serve part-typed and whole-col
scopes without branching.

## moveHook

Every position-changing path ends with `clampPos()` followed by
`moveHook()`. The pair is mandatory: clamp without hook leaves
listeners stale; hook without clamp can announce an off-grid position.
The view layer subscribes to drive scroll-into-view.

## Region mode

Region authoring is a modal `cmgr` overlay ec pushes, not a page-local
flag. The reason is feedback: the old page-local scope had no live
render and no mode affordance, so the entry chord either no-op'd or
dropped the user into an invisible modal. A real scope plus
`isInRegionMode()` makes the state observable to the renderer.

Entry lands on the instance under the caret (the bridge's
`instanceAt`), not gm's active pointer, so authoring starts on what you
are looking at. Nav is **border-only**: moving the region cursor just
outlines an instance; it never installs a grid selection. A live
selection mid-mode would both let a stray keystroke escape the modal
and conflate "the instance I'm authoring" with "what's selected for
editing". The selection is installed once, on commit -- the deliberate
handoff back to normal editing.

ec owns only the lifecycle and an **ephemeral** nav cursor
(`{groupId, instId}`, never persisted). The group store, projection,
conform and persistence stay entirely in the group engine. ec reaches
it through an injected bridge — never `tm`, never gm internals — so
the editing cursor keeps its single invariant (caret/selection only,
no MIDI state) even while driving group geometry. The bridge is
trackerView's grid↔logical surface; faking it in tests fakes tv, not
ec's verbs.

A pure re-anchor is invisible to the group engine's drift-driven
reprojection (the group frame is anchor-invariant), so `regionNudge`
goes through the engine's explicit move verb, not a reproject. Why
that is lives in the group engine's doc, not here.

Creation verbs (`newFromSelection` aside, which seeds in place) clear the
destination zone before gm stages its projection: gm only re-places its
own concretes, and a foreign note straddling the zone, left in place,
would force the lane allocator to spill the projection onto another lane
on rebuild -- lane identity is load-bearing under groups.

Paint sculpts the *existing* active group's stream-set — there is no
pre-commit authoring rect any more (the old mirror flow had one). A
painted column is a `resizeGroup` of the rect's streams, and an extend
must hand the newly-covered concretes in itself: the engine recomputes
from the rect, it never rescans the take for gained members. That
grid↔stream translation is trackerView's, reached through the bridge
like every other region verb.

## Clipboard: single vs multi

The mode is decided at copy by the resolved selection: one column
means **single**, multiple means **multi**. They paste differently
because they encode different intents:

- **single** — "these values, on this kind of part." Dispatch is by
  `(clip.type, dstCol.type, cursorPart)`. A note→note paste drops
  pitches; a 7bit→note paste drops velocities (via `pasteVelocities`,
  with PA emission on sustain rows when polyAftertouch is on); a
  pb→pb paste drops pitch-bend values; mismatched combos silently
  no-op.
- **multi** — "this rectangle of channels." Each clip col carries
  `chanDelta` from the leftmost source channel, and the cursor's
  channel becomes the leftmost destination. Out-of-range channels
  and missing destinations skip silently.

## Persistence

The clipboard persists across script reloads via REAPER `ExtState`
under `('rdm','clipboard')`, serialised by `util.serialise`. Reloading
the script doesn't lose the last copy.

## Reserved keys

`CLIP_RESERVED` is stripped at copy; `CLIP_ARTIFACTS` (`row`/`endRow`)
is stripped at paste; everything else round-trips. So custom
metadata on a source event survives a copy/paste cycle without the
clipboard layer needing to know what it is.
