# Blocks — regional aliases over the spec substrate

A working design doc for the block feature. Future `docs/blocks.md` is
distilled from this once code lands.

A **block** is a region-level alias: events inside one region of the
take propagate to matching positions in other regions, each region
carrying its own transformation. Adding an event to any region adds
it to all; deleting from any region deletes from all; editing within
any region edits the shared content for everyone.

All instances of a block are siblings. There is no privileged "source"
or "original." Reference-counted hard-link semantics: the block's
content persists as long as ≥1 instance exists; when the last instance
is deleted the block is gone.

Blocks sit on top of the spec-tree primitives in
[`aliases.md`](aliases.md). Read that first.

---

## Layering invariant

Blocks are a higher-level abstraction over per-event aliasing. The
spec tree handles point-to-point (this event derives from that one).
The block layer handles region-to-region membership.

**Layers own disjoint state:**

| concern | layer |
|---|---|
| which events belong to which instances | block |
| structural xform — the per-instance transform that defines this region's offset/scale | block |
| per-event override xform — variation unique to one materialised event | spec node |
| persistent identity of an aliased event | spec node |

The block's structural xform is **never copied into spec nodes**. The
walker composes at emit time:

```
resolved = applyXform(template.event.fields,
                      instance.xform,
                      specNode.overrideXform)
```

This rule is the membrane between layers. The principled implementation
holds it; the lazy implementation (stamp block xform into spec nodes at
creation) duplicates state and ends with a consistency problem on every
block edit.

The walker described in `aliases.md` does not know blocks exist. A
*reconciliation pass* runs before the walker to synthesise the spec
nodes the block layer wants; the walker then renders them. Reconciliation
is additive — it creates and prunes spec nodes — not corrective.

---

## Data shape

### Take metadata

A take carries `take.blocks` and `take.blockCtr`, plumbed through the
same metadata pass-through as `note.aliases`.

```lua
take.blocks = {
  [blockId] = {
    template = {
      region    = <Region>,     -- set of cells; see below
      events    = {             -- abstract events, keyed by virtual uuid
        [vuid] = { pitch=60, dur=480, vel=96, ppqLocal=0, ... },
        ...
      },
      eventCtr  = 7,            -- next vuid allocator (base36)
    },
    instances = {
      [idx] = {
        region = <Region>,      -- where this instance materialises
        xform  = <op-list-per-field>,  -- structural transform
      },
      ...
    },
    instanceCtr = 4,
  },
}
take.blockCtr = 12
```

### Region

A region is a set of cells, not necessarily contiguous:

```lua
Region = {
  cells = {                      -- ordered list of disjoint rectangles
    { colLo, colHi, ppqLLo, ppqLHi },
    ...
  },
}
```

- **col** for notes = `(chan, pitch)` pair; for ccs = `(chan, msgType, id)`.
  A region is single-event-type — notes and ccs do not mix in one block.
- **ppqL** bounds are logical (pre-swing). Bounds are half-open
  `[lo, hi)` so adjacent rectangles can abut.
- Membership predicate: an event with `(col, ppqL)` lies in the region
  iff some rectangle contains it.

### Template events

Template events are **not** MIDI events. They hold the platonic field
values that materialise per instance. Each carries a `vuid` (virtual
uuid, base36 monotonic per block) and a `ppqLocal` — its logical-ppq
offset from the template region's origin.

```lua
template.events['1'] = {
  ppqLocal = 0,    pitch = 60, dur = 480, vel = 96, ...
}
template.events['2'] = {
  ppqLocal = 240,  pitch = 64, dur = 240, vel = 80, ...
}
```

The vuid is the persistent identity of an event *within the block*. A
materialised event in instance `k` carries
`(blockId, instanceIdx=k, vuid)` as metadata, and that triple is its
persistent identity across rebuilds (its MIDI uuid is ephemeral, as
elsewhere).

### Instance regions and origin

Each instance has its own region. The template region defines the
*shape* (extent and inner structure of the cells); each instance's
region has the same shape translated to its origin. The instance's
origin is `(instance.region.cells[1].colLo, instance.region.cells[1].ppqLLo)`
by convention — the top-left of its first rectangle.

A template event at `ppqLocal = p, col = c (relative)` materialises in
instance `k` at:

```
ppqL = instance.origin.ppqL + p
col  = instance.origin.col  + cRelative
```

Then `instance.xform` and `specNode.overrideXform` apply.

---

## Resolution

### Reconciliation pass (tm-side, before the walker)

On every `'reload'` from mm, before the alias walker described in
`aliases.md` runs:

1. For each block in `take.blocks`:
   - For each instance `k`:
     - For each template event `vuid`:
       - Compute the target position and resolved fields under
         `instance.xform`.
       - Ensure a spec node exists tagged with `(blockId, k, vuid)`.
         If absent, create it as a child of a **synthetic root** for
         this template event (see below). If present, leave its
         `overrideXform` untouched.
     - Prune spec nodes tagged with `(blockId, k, *)` whose `vuid` is
       no longer in the template.
   - Prune instances absent from this block (handled by deletion path,
     not reconciliation).

2. Then the alias walker runs as `aliases.md` describes.

### Synthetic roots

Spec nodes need parents (the spec tree is rooted in something). For
template events, the parent is a **synthetic root** — a virtual event
that exists only as a key into the spec tree. It has no MIDI
materialisation. Its resolved fields are
`template.events[vuid]` extended with `ppq = instance.origin + ppqLocal`.

In implementation: the spec tree's parent map accepts either a
materialised-event uuid (current behaviour) or a synthetic-root key
`{blockId, vuid}`. The walker, when resolving a spec node whose parent
is a synthetic root, reads fields from the template event rather than
from a MIDI event. Everything else is unchanged.

This is the only intrusion the block layer makes into the spec layer.
The walker grows one branch in its parent-resolution step; nothing else
changes.

### Source mutation propagates automatically

Because reconciliation runs every rebuild and reads the *current*
template, adding/deleting/editing a template event surfaces in all
instances on the next rebuild. The user does not invoke a "sync"
command; sync is the default.

---

## Mutation

Block mutation falls in three categories.

### Template-edit (the common case)

The user nudges, adds, deletes, or otherwise edits an event in any
instance. The intent is to edit the shared content.

For each touched materialised event:

1. Find its `(blockId, k, vuid)` metadata.
2. Compute the equivalent edit on the template event:
   - For invertible xforms (composed `add`, `mul ≠ 0`): apply the
     inverse of `instance.xform ∘ specNode.overrideXform` to the user's
     edit, then apply to `template.events[vuid]`.
   - For non-invertible (`snap`, `rand` at structural level): degrade
     to per-event override — the edit lands in `specNode.overrideXform`
     for this instance only. Surface a status warning ("block edit
     applied to this instance only — structural transform is not
     invertible"). The user may sever to make the override permanent.

3. Reconciliation on the next rebuild propagates to all instances.

Adding an event inside an instance's region: synthesise a new template
event with `ppqLocal` computed from the region origin, allocate a fresh
vuid, write it to `template.events`. Reconciliation creates spec nodes
in all instances.

Deleting an event inside an instance's region: drop the template event
by vuid. Reconciliation prunes spec nodes in all instances.

### Block-wide edit

A command operating on the block as a whole (e.g. "scale all instances
by 0.5") composes into each instance's `xform`. The template is
untouched. All instances reshape.

This is the surface where block-wide ops are distinguished from
per-event ops: a block-wide command writes into `instance.xform`, a
per-event command writes into the template (via inverse) or into
`specNode.overrideXform` (per-event override).

### Per-event override

Explicit override commands (per-event humanise, per-event nudge with a
modifier, etc.) write into `specNode.overrideXform` of the touched
instance only. No propagation. The template is unchanged.

The UX distinguishes these three at the command surface — same key
chord with different modifiers, or three separate commands. Defer
specifics to phase 3 of impl.

---

## Hard-link semantics

### Creation

`copyAsBlock` (or `duplicate` in block mode) takes the current
selection and creates a new block:

1. Allocate a fresh `blockId`.
2. Derive a `template.region` from the selection's bounding shape.
3. For each event in the selection, mint a template event with
   `ppqLocal` relative to the selection's origin. The selected events
   themselves are **deleted from MIDI** — they become template-only.
4. Create the first instance at the selection's original position
   (`xform` is identity).
5. On paste/duplicate, create additional instances at the target
   positions, each with `xform` reflecting the offset/scale from the
   source.

Step 3 is the inversion of (2) in the previous discussion: the event's
MIDI value moves *into* the template's `events` table; instances are
then reconciled in, materialising fresh MIDI under the new
`(blockId, k, vuid)` keys.

### Deletion

Deleting all events in an instance's region removes the instance from
`block.instances` (and prunes its spec nodes).

When `#block.instances == 0`, the block itself is deleted — `template`
and `instances` both gone. This is the hard-link "last reference"
collection.

### Severing an instance

`sever` on a materialised event of a block extracts its instance and
its current resolved content into plain MIDI events; the block loses
that instance. If the block has other instances, they continue. If it
was the last instance, the block is collected.

Severance is a per-instance operation, not a per-event operation
(within a block). Severing one event from an instance is a per-event
override (above) — it stops following the template but the instance
itself remains a block member.

### "Promote one instance to plain MIDI without breaking the block"

Equivalent to severing one instance.

---

## Composition with single-event aliases

A block's instance can contain events that are also single-event aliases
(per `aliases.md`'s spec tree). Mechanically: a materialised block
event under `(blockId, k, vuid)` can itself be a parent for further
spec nodes outside the block.

The reverse — a single-event alias whose parent is itself a block
materialisation — is fine; its parent uuid is the materialised event's
ephemeral uuid, and on rebuild the alias re-derives. (This is the same
contract as today; nothing block-specific.)

What's **not** allowed: nesting a block inside a block via region
overlap. If instance region of block A overlaps source-or-instance
region of block B, refuse the second block's creation. Region nesting
is reserved for a later phase if it becomes necessary.

---

## Precedence and collisions

The slot key from `aliases.md` (`(chan, pitch, ppq)` for notes,
`(chan, msgType, id, ppq)` for ccs) carries over. A block instance can
collide with a plain event, or with another instance, or with a
single-event alias.

BFS order from `aliases.md` extends: depth 0 = plain events and
synthetic roots; depth 1 = first-level spec nodes (block instances and
single-event aliases alike); depth ≥ 2 = nested. First arrival wins
the slot; losers are suppressed-but-spec-retained.

Resurface is automatic when the blocker moves, same as today.

---

## Visual representation

(Renderer-side; final design in `docs/renderManager.md` once landed.)

A block has spatial extent, so the renderer has room to draw it:

- Instance region outline — a bracket or coloured boundary around each
  instance's cells.
- Block colour — a per-block hue distinguishes instances of one block
  from instances of another.
- Instance handles — a small affordance near each instance's origin
  for grabbing the block (move, scale, delete).
- Materialised aliased events inside an instance render with the
  alias marker from `aliases.md`, tinted with the block's hue.

The template itself is not rendered (it has no spatial position).

---

## Phasing

| phase | scope |
|---|---|
| 0 | this design doc + corresponding edits to `aliases.md` (synthetic-root branch in walker) |
| 1 | data types (Region predicates, block/template/instance shapes), pure helpers, serialise round-trip |
| 2 | reconciliation pass — synthesise spec nodes for block instances, prune orphans, walker reads synthetic-root branch |
| 3 | mutation routing — distinguish template-edit / block-wide / per-event-override at the command surface; inverse-xform path for invertible ops; degrade-to-override path for non-invertible |
| 4 | creation UX — `copyAsBlock`, paste/duplicate-as-instance, block-mode toggle |
| 5 | deletion + hard-link GC; severance per-instance |
| 6 | renderer markers (region outlines, block colours, instance handles) |

---

## Test surface

Tests live under `tests/specs/blocks_*.lua` plus
`tests/specs/blocks_helpers_spec.lua` for pure helpers.

**Phase 1** — Region predicates
- Membership: point inside / outside / on boundary (half-open).
- Disjoint-rectangle composition: union, intersection-empty check.
- Round-trip through `util.serialise`.

**Phase 2** — Reconciliation
- Template event added → spec nodes appear in every instance on next
  rebuild.
- Template event removed → spec nodes pruned from every instance.
- Instance added → spec nodes for all template events appear in it.
- Block with no instances → block GCd.

**Phase 3** — Mutation
- Edit-through with invertible xform: template field updates by the
  inverse-composed delta; all instances reflect.
- Edit-through with `snap` xform: lands as per-event override on the
  touched instance only; other instances unchanged.
- Block-wide xform edit composes into `instance.xform`; template
  untouched.
- Per-event override on one instance does not propagate.

**Phase 4** — Creation
- `copyAsBlock` on N selected events produces a block with N template
  events; selected events become an instance.
- Paste creates a second instance with `xform` capturing the position
  delta.
- Multiple instances on different rows compose distinct xforms.

**Phase 5** — Deletion and severance
- Deleting all events in an instance's region removes the instance.
- Deleting the last instance GCs the block (`take.blocks[id] == nil`).
- Severance extracts an instance to plain MIDI; block continues with
  remaining instances.
- Severance of last instance equals "convert to plain MIDI."

---

## Open questions

- **Region shape primitives** — is a list of disjoint rectangles
  sufficient? Selections in the tracker today are typically rectangles
  or thin columns; multi-region selection isn't a current primitive.
  Probably yes for phase 1; revisit if real use cases need richer shapes.

- **Invertibility threshold for edit-through** — `add` and
  `mul (k≠0)` invert exactly. `mul (k=0)` is degenerate. Composed
  invertibles invert. Where exactly does the "degrade to override" path
  cut in? Likely: walk the xform op list; if any op is non-invertible
  (`snap`, `rand` argument anywhere), refuse inverse and degrade.

- **Mixed-type blocks** — can a block contain both notes and ccs? Phase
  1 says no (single event type per block). Lift the restriction if a
  use case appears.

- **Block nesting via region overlap** — explicitly forbidden in phase
  1. The cycle-detection machinery for nesting is a real cost; defer
  until we have a use case that justifies it.

- **Renaming `aliases.md`** — once blocks exist, the doc layering is
  `aliases.md` (per-event substrate) → `blocks.md` (regional layer).
  The user-facing primitive in the UI may want a different name from
  either ("group"? "clip"? "region"?). Settle in phase 4 with the UX.
