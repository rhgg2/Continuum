# regions

A region is a named patch of the tracker grid: one contiguous slab
along the time axis, intersected with a sparse set of column-parts.
It is a UI primitive — selection's persistent cousin — and the
substrate the future blocks layer will repeat.

The `.map` for `editCursor.lua` and `regions.lua` carry the API,
shape, and signal surface. This file is the WHY.

## Two axes, asymmetric

A region has the same two-axis structure as a selection, but the axes
live differently in the data:

- **time** — `ppqLo`/`ppqHi`, a single half-open `[lo, hi)` slab.
  Contiguous by construction; you cannot punch a hole in a region's
  time range.
- **parts** — `{ [colKey] = true, ... }`, a *sparse set* over the
  column-parts of the take. Any column-part may be in or out
  independently; there is no implicit rectangle.

Selection is rectangular on both axes. A region is rectangular on
time and free-form on parts. The asymmetry is the point: it lets a
single region name "the snare lane and the bass pitch column,
between bar 5 and bar 9" without dragging in the eight intervening
columns the way a selection would.

## Logical ppq, not realised

Both `ppqLo` and `ppqHi` are stored in *logical* ppq — the authoring
frame, pre-swing. See `docs/timing.md` for the two-frames model.

The reason is durability under swing edits. A region named today at
"rows 16..32" must mean the same rows tomorrow even if the user
adjusts swing. Storing realised ppq would tie a region's identity to
the swing curve it was painted under; storing logical ppq makes it
swing-invariant.

The `logPerRow` callback on editCursor exists for the same reason:
mouse paint and the time-axis verbs convert row deltas to logical-ppq
deltas at the moment of mutation, not at storage time.

## Identity by `colKey`, not column index

A region's parts set is keyed by `regions.colKey(col, partName)`,
producing strings like `"note:1:60:pitch"` or `"cc:3:74"`. Column
indices are not stable across rebuild (lanes can renumber on import,
new lanes can appear), but the underlying `(type, chan, lane, part)`
tuple is. Keying by colKey lets a region survive a rebuild that
shuffles `grid.cols` ordering without rewriting its membership.

Lane identity itself *is* stable in this codebase — notes may move
on import but lanes do not shuffle on rebuild — so no fresh uid
layer is needed beneath colKey.

## Why on `editCursor`, not a peer manager

The original P3 sketch placed region state in a separate
`regionManager`, peer to `trackerManager`. That was rejected in
favour of putting regions on `editCursor`:

- Regions are selection-adjacent UI artefacts. ec already owns the
  selection vocabulary, the clipboard, and the row/column model.
- Like clipboard, regions are *persisted UI state* — not MIDI data,
  but data the user expects to outlive a session. ec already handles
  one such artefact; adding another fits the layer.
- Carving regions into a fresh manager would have split the
  selection ↔ region helpers (`selectionAsRegionShape`,
  `setSelectionFromRegionShape`) across a layer boundary they
  belong inside.

ec's invariant was rewritten to reflect this: *ec owns caret,
selection, clipboard, and regions; no MIDI event state — MIDI
mutations go via tm/cm.* Don't propose a regionManager again.

## Persistence

Regions persist on the take, alongside the MIDI data, via
`P_EXT:ctm_regions`. The blob is just `util.serialise` over the
region list. The wire path is:

```
ec  ⇄  tm:saveRegions / tm:loadRegions  ⇄  mm  ⇄  P_EXT
```

ec exposes `regionsBlob()` and `loadRegions(blob)` as the in-memory
↔ blob seam. `loadRegions` is deliberately silent — it fires no
`regionsHook` — to avoid the load → save → load loop that an earlier
draft suffered. The wiring lives in `trackerView`: every region
mutation funnels through `regionsHook`, which calls
`tm:saveRegions(ec:regionsBlob())`.

P_EXT writes participate in REAPER's undo via the take-info channel,
which is why every region verb is wrapped in `util.atomic` — one
verb, one undo entry.

## Modal entry: cmgr overlay scope

Region mode is the `'region'` scope sitting atop `tracker` on
`commandManager`'s stack. ec builds the scope at construction
(`modal=true`, `passthrough = REGION_PASSTHROUGH`, region verbs
registered); the page binds the entry chord on tracker and the
in-mode chords on the region scope. `ec:enterRegionMode()` pushes;
`regionBail` / `regionCommit` pop.

The stack walk does the gating. cmgr's keychain walks top-down; on
hitting the modal region scope, only `passthrough` names reach
tracker / global below. Cursor movement, selection navigation, and
`swapBlockEnds` pass through; everything else (`paste`,
`inputCharBackspace`, every typing verb) hits the wall and is
swallowed. The same logic gates `invoke` for non-key call paths.
No wrap-all sweep, no `regionMode` flag — presence on the stack is
the gate.

Region verbs have their own names — `regionDrop`,
`regionNudgeBack`, `regionNudgeForward`, `regionGrow`,
`regionShrink`, `regionSnapHi`, `regionPrev`, `regionNext`. They do
not share names with tracker's time-axis verbs; commands are a flat
namespace and a name has one meaning. What's shared is the **key**:
the region scope's keymap copies the corresponding key entries from
tracker's keymap by reference, so Delete drops, `[`/`]` nudge,
`Shift+[`/`Shift+]` shrink/grow, `1` snaps to cursor, and
`Shift+,`/`Shift+.` page through regions. If tracker's keymap is
re-bound the region map tracks it without further wiring.

## Mouse paint

Shift-drag adds painted cells to the active region (auto-`n`ing a
zero-row seed region at the painted row if none is active);
alt-drag removes them. Each painted cell is one atomic undo entry,
debounced by a `(row, colKey)` key so a held drag across one cell
fires once. The paint block sits at the top of `handleMouse` and
`return`s before the ordinary click/drag handling, so region paint
never coexists with selection extension in the same frame.

## Rendering

A dedicated pass in `drawTracker` runs between the row-background
layer and the tails+cells layer, so per-cell text reads over the
tint. The colour comes from cm: each palette slot has a paired
`colour.region.N.tint` (alpha 0.22 wash) and `colour.region.N.outline`
(full alpha border) — the renderer resolves both via `chrome.colour`
keyed on the region's `colour` slot. Every region paints its tint;
the active region adds the outline and a thin coloured bar in the
gutter at its row span so the user can spot it without scanning the
whole grid.

Per-column resolution maps `regions.colKey(col, part)` against
`r.parts`. Note columns iterate the three part names
(pitch / vel / delay) and scan `col.partAt` for the matching stop
range; other column types are whole-column. Visibility gates on
`col.x` exactly as the cell loop does, so off-screen columns cost
nothing.

## What's deferred

- Multi-tract commit. `regionCommit` currently snaps the selection
  to the region's parts bounding box. A region whose parts span
  disjoint tracts (e.g. only columns 2 and 7) collapses to a
  bounding rectangle on commit. The selection model has no
  vocabulary for disjoint columns; if a use case appears the
  selection shape grows first, then commit follows.
- Letter-chord entry. `gr` to enter region mode would be a more
  natural binding than Ctrl+R, but it requires letter-chord support
  in commandManager that doesn't exist today.
- Interactive gutter handles. The active region's gutter bar marks
  the ppq span visually but does not yet capture mouse drags;
  shift-drag / alt-drag on the grid body covers paint today.

## Future hook for blocks

When the blocks layer lands, a block's template carries a region
shape directly: the `(ppqLo, ppqHi, parts)` triple is exactly the
unit of repetition blocks need. Regions exist as their own concept
first so the shape settles before alias/template plumbing layers on
top. See `project_blocks_design` in conversation memory.
