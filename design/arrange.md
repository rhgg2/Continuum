# Arrange page

A zoomed-out timeline view, modelled on Jeskola Buzz's arrange. Columns
are REAPER tracks; rectangles are takes (one per REAPER media item)
laid out along time. Each track carries a palette of up to 62 named
**slots**; pressing a base36 key in a column drops a new instance of
that slot at the cursor. For MIDI slots, instances are pooled — edit
one, all change. MIDI takes are a single hotkey from the tracker view.

## Vocabulary

- **take** — a rectangle on the grid. One REAPER media item (its
  active take). MIDI or audio.
- **slot** — a per-track palette entry. Indexed 0..61, keyed by base36
  (`0-9`, `a-z`, `A-Z`). Points at a pooled-MIDI source (for MIDI
  slots) or a source file (for audio slots).
- **palette** — the per-track collection of slots, shown as a list to
  the right of the grid for the focused track.
- **orphan** — a take whose underlying source isn't in any slot of the
  track. Rendered, editable, but the palette doesn't know about it.

The arrange page never coins new terms for things the tracker stack
already names (cursor, selection, snap, etc.).

## Layering

```
coordinator
  ├─ trackerPage
  ├─ samplePage
  └─ arrangePage          -- toolbar, status, key/mouse, page scope
       └─ arrangeView     -- viewport (visible track range, qn range,
            │                zoom), cursor, selection, palette UI,
            │                drag preview
            └─ arrangeManager   -- project-wide; reads REAPER items
                                  directly; owns slot dictionary via cm
```

`arrangeManager` has no `midiManager` / `trackerManager` dependency.
Diving into a MIDI take routes through the coordinator: set
`currentTake`, switch page. The tracker stack stays untouched.

`sequenceManager` is folded into `arrangeManager` and deleted —
`takesUsing` and `reswingAll` are degenerate cases of the project-wide
take walk that arrangeManager already performs. The swing-editor
caller is migrated.

## Time

QN throughout, matching the rest of the project. Snap defaults to a
bar; configurable to beats, 1/8, 1/16 via the page toolbar. The
arrange grid is fixed in QN space; tempo/sig changes shift wall time
but the rectangles don't move.

## cm schema

One new track-tier key:

```
arrangeSlots = { [slotIdx 0..61] = { kind = "midi"|"audio",
                                     id   = <string> } }
```

For MIDI, `id` is the REAPER pool GUID (the source's pooled
identity, queried per take). For audio, `id` is the absolute source
path. Slot index is stable across sessions; gaps are allowed and
skipped on render.

**Names are not stored.** A slot's name is derived per-frame as the
`GetTakeName` of any item with the slot's `id` (first-found wins).
Rename writes `SetTakeName` across every matching item. If the user
renames in REAPER and instances diverge, we read whichever happens to
be first — accepted drift.

## Take shape (derived each frame)

```
take = { item, take, trackIdx,
         startQN, lengthQN,
         kind = "midi"|"audio",
         slotIdx | nil,         -- nil = orphan
         name }
```

Discovery walks `CountTrackMediaItems`/`GetTrackMediaItem` per track,
groups by `id`, and joins against the cm slot dictionary to resolve
`slotIdx`.

## arrangeManager public API

```
-- discovery
am:projectTracks()                -> {idx, name, slotCount, takeCount}[]
am:tracksTakes(trackIdx)          -> take[]
am:trackSlots(trackIdx)           -> {idx, kind, id, name, defaultLengthQN}[]
am:slotForTake(take)              -> slotIdx | nil
am:keyForSlot(slotIdx)            -> "0".."Z"

-- slot mgmt
am:newMidiSlot(trackIdx)          -> slotIdx     -- creates empty pooled source
am:newAudioSlot(trackIdx, path)   -> slotIdx
am:deleteSlot(trackIdx, slotIdx, opts)           -- opts.removeInstances?
am:renameSlot(trackIdx, slotIdx, name)

-- placement
am:dropInstance(trackIdx, slotIdx, qnPos, lengthQN?) -> take
am:duplicateTake(take, qnPos)     -> take

-- per-take edits (mirror tracker nudge / grow / shrink)
am:takeAt(trackIdx, boxLoQN, boxHiQN) -> take | nil
am:freeSpan(take)                 -> loQN, hiQN  -- non-overlap window
am:moveTake(take, deltaQN)
am:resizeTake(take, newLengthQN)
am:deleteTake(take)

-- folded from sequenceManager
am:takesUsing(swingName)
am:reswingAll(swingName)
```

## Commands (arrange page scope)

- `←/→/↑/↓` — move cursor by snap unit / track.
- `Shift+arrows` — extend rectangular selection.
- `Home/End`, `PgUp/PgDn` — project edges, screenfuls.
- Base36 key — drop instance of slot N at cursor in focused column.
- `n` — new MIDI slot in focused track.
- `N` — rename slot under palette focus.
- `Tab` (or `Enter`) — dive into tracker for MIDI take under cursor.
- `Delete` — remove take(s) under cursor / selection.
- Nudge / resize / trim commands — names and bindings cloned from the
  tracker editing vocabulary, retargeted at takes.
- `Ctrl+X / C / V` — cut / copy / paste takes; paste lands at cursor.

The 62 base36 entries are registered via a generated loop, not 62
table entries.

## Right-side palette

For the focused track: vertical list of slots `0..61` with key,
derived name, kind icon (MIDI / audio), and instance count. Hovering a
slot highlights its instances on the grid. Buttons: **+** (new MIDI
slot), **+♪** (new audio slot, opens file picker), **rename**
(opens `InputText` popup for the focused slot), **delete** (with
confirm if instances exist).

## Mouse

Click a take → cursor jumps, take becomes focus. Drag → move. Drag an
edge → resize. Modifier+drag → duplicate (pooled clone for MIDI). The
grid responds to snap.

## Build phases

Each phase ships green and committable.

1. `arrangeManager` + specs. Pure model: discovery, slot dictionary
   read/write, take-from-item construction. Subsume `sequenceManager`;
   migrate swing-editor caller.
2. `arrangePage` skeleton. Coordinator registers third page; chrome
   adds the third switcher button. Read-only render of tracks × time
   with cursor navigation.
3. Right-side palette UI: list, new-slot, rename.
4. Placement: base36 scope, `dropInstance` at cursor.
5. Take edits: move/resize/delete with tracker-mirrored vocab. Trim-
   start has no tracker note command to clone — deferred to the
   mouse-drag slice (7), where edge-dragging makes it natural.
6. Tracker dive hotkey.
7. Mouse drag: move / resize / modifier-duplicate.

## Open

**Audio and "new instance".** REAPER does not pool audio: a new audio
instance is just another item referencing the same file; edits don't
propagate. Two options:

- *Uniform.* Base36 placement works for both kinds; audio creates
  non-pooled siblings; the doc states the asymmetry plainly.
- *MIDI-only.* Base36 is MIDI-only; audio takes arrive via the sample
  page and exist as orphans on the grid (no slot).

Default assumption is *uniform* unless overridden.
