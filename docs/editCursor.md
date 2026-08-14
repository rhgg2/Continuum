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

## Decoration

`decorateCol` builds the pitch part's `width`/`stops` per column from the
temper: `width` is the active `cellWidth`, and `stops` opens with the note
name before one stop per octave char, so a temper whose period sits well
under an octave (`docs/tuning.md` § Display) still gets one cursor stop
per digit of it.

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

- **single** — "these parts, from this column." The clip records
  `parts`: the parts the span covered, in column order. It carries the
  fields those parts own, and nothing else.
- **multi** — "this rectangle of channels." Each clip col carries
  `chanDelta` from the leftmost source channel, and the cursor's
  channel becomes the leftmost destination. Out-of-range channels
  and missing destinations skip silently. A multi entry always carries
  whole cells; there is no per-part split at this granularity.

### Lanes, and what fills the gap

A note column's parts are `pitch`, `vel`, and — when the column shows
them — `sample` and `delay`. Every part but `pitch` is a **lane**: a
column of values laid over the notes, editable on its own. A span
covering `pitch` carries notes; a span that doesn't carries lane
values, to impose on the notes already at the destination.

A lane the span excluded is dropped at copy and filled at paste from
the destination's own running value — the lane's value at the last
note-on before the pasted region, carried forward through it. That is
what makes a pitch-only paste "impose a new set of notes on a
collection of velocities", and a vel-only paste its converse.

Fields with no part — detune, the note's duration — are not lanes, and
ride with the note whenever pitch does. So does a field whose part the
column isn't showing: a span can only exclude what it could address,
so with the delay part hidden a copied note keeps its delay and a
duplicated passage keeps its groove. The `'*'` sentinel (hBlock 2/3)
addresses no part in particular, and so covers them all.

### Where a part pastes

Lane values land in the destination lane anchored at the cursor's
part, each further part of the clip in the part after it. A part
writes into its own name, with one exception: `vel` and `val` are both
7-bit lane values and interchange, so a velocity span pastes into a cc
lane and a cc span into a velocity column. Everything else — a pb span
onto a cc column, a delay span onto a velocity column — skips.

The destination decides how a lane is written. On a note column the
lane is a view onto notes, so the values are assigned to the note-ons
already in the region, and a value landing on a sustain row becomes a
PA event when `polyAftertouch` is on. On a cc or pb column the events
*are* the lane, so the region's events are replaced outright and their
metadata rides through.

A clip carrying notes replaces the region's notes wholesale. Deletion
is direct rather than via `queueDeleteNotes`, whose survivor-extension
fixup is for leaving a hole where this fills one. Neither the pasted
note's tail nor its predecessor's is pre-trimmed: `endppq` is the
authored intent, and tm's universal tail pass clips the realised
note-off against whatever blocks it, then regrows it when that goes.

## Persistence

The clipboard persists across script reloads via REAPER `ExtState`
under `('rdm','clipboard')`, serialised by `util.serialise`. Reloading
the script doesn't lose the last copy.

## Reserved keys

`CLIP_RESERVED` is stripped at copy; `CLIP_ARTIFACTS` (`row`/`endRow`)
is stripped at paste; everything else round-trips. So custom
metadata on a source event survives a copy/paste cycle without the
clipboard layer needing to know what it is.

Each reserved group has its own reason: position (`ppq`/`endppq`)
rebuilds from `row` at paste; identity (`chan`/`rpb`/`lane`/`cc`) and
kind (`type`/`evType`) are the destination's to decide, not the
source's; REAPER bookkeeping (`idx`/`uuid`/`uuidIdx`/`realised`) must
not round-trip regardless. Do not allowlist event payload instead —
the list stays small and rule-based so unknown fields keep riding
through.
