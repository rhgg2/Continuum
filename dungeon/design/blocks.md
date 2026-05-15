# Blocks — regions with template events

A working design doc for the block feature. Future `docs/blocks.md` is
distilled from this once code lands.

A **block** is a region that owns its content. Events inside a block do
not exist as plain MIDI; they live as **template events** in the
block's metadata, and the walker emits a transformed materialisation
per template event on every rebuild. The block carries an **xform**
that shapes its emit — geometric ops (move, scale) and per-column
content ops (shift pitch, vel, val) compose into the same xform table,
keyed differently.

Phase 1 is **single-instance**: a block IS its sole instance, the
region itself. Multi-instance (paste-as-instance, duplicate-as-instance,
hard-link propagation) is deferred to a later phase. The data shape
allows multi-instance from the start; the verbs for creating additional
instances do not exist yet.

Blocks sit on top of the per-event spec-tree primitives in
[`aliases.md`](aliases.md). Read that first.

---

## Regions ARE blocks

A region without template events is the existing UI primitive — a
tinted slab × parts-set, used for selection-like persistent marking
(see `docs/regions.md`). A region WITH template events is a block.

There is **no separate region-to-block promotion step**. The data
object is the same; adding the first template event to a region turns
it into a block. Removing the last template event turns it back into a
plain region (the tinted slab persists; the block-shaped content is
gone). A region without an `xform` is identity-emit.

ec continues to drive region authoring (create / cycle / nudge /
parts paint). Persistence moves: regions live in cm's take tier under
a single key `regions`, shape `{ regions = [...], idCtr = N }`. No
`mm` pass-through, no `util.serialise` round-trip outside cm's own
persistence path. ec exposes its live store as `ec.regionData` —
trackerView seeds it on takeChanged from `cm:get('regions')` and
writes it back through `cm:set('take', 'regions', ec.regionData)` via
the `regionsHook`. ec does not own the wire.

---

## Layering invariant

Blocks compose two scales of mutation. The block layer owns
content-and-region-scoped state; the spec-tree from `aliases.md` owns
per-event variation under each materialisation.

| concern | layer |
|---|---|
| which template events belong to the block | block (`template.events`, keyed by `vuid`) |
| block's geometric + content xform | block (`block.xform`, keyed by `'*'` or `colKey`) |
| per-event override xform — variation unique to one materialised event | spec node |
| persistent identity of a materialised event | `(blockId, vuid)` — a synthetic root |

The block's xform is **never copied into spec nodes**. The walker
composes at emit time:

```
resolved = applyXform(template.events[vuid],
                      block.xform['*'],
                      block.xform[colKey(vuid)],
                      specNode.overrideXform)
```

This is the membrane between layers. The principled implementation
holds it; the lazy implementation (stamp block xform into spec nodes at
template-event creation) duplicates state and creates a consistency
problem on every block edit.

The walker described in `aliases.md` does not know blocks exist. A
**reconciliation pass** runs before the walker to synthesise the spec
nodes the block layer wants, parented at synthetic roots; the walker
then renders them. Reconciliation is additive — it creates and prunes
spec nodes — not corrective.

---

## Data shape

### Storage — cm take tier

The regions blob is a take-scope cm entry under the single key
`regions`. cm's existing persistence handles it transparently; no
extra plumbing. Reading: `cm:get('regions')`. Writing:
`cm:set('take', 'regions', value)`.

```lua
take.regions = {
  regions = {       -- array, order = ec's regionOrder
    {
      -- region surface — same fields the existing region UI uses
      id, colour,
      ppqLo, ppqHi,
      parts = { [colKey] = true, ... },

      -- template content (absent on a region with no events)
      template = {
        events = {
          [vuid] = { col=<colKey>, ppqL=<int>, pitch=60, durL=480, vel=96, ... },
          ...
        },
        eventCtr = 7,        -- next vuid allocator (base36)
      },

      -- xform, keyed by colKey or the '*' sentinel
      xform = {
        ['*']     = { ppqL={...}, durL={...}, delay={...} },
        [colKey1] = { pitch={...}, vel={...}, detune={...} },
        [colKey2] = { val={...}, chan={...} },
        ...
      },
    },
    ...
  },
  idCtr = 12,       -- next region.id allocator (monotonic integer)
}
```

A region with no `template` field (or `template.events` empty) and no
`xform` is just a tinted slab — pre-block behaviour. Add a template
event and the same record acts as a block. `blockId` throughout this
doc refers to `region.id` — there is no second namespace.

### Template events

Template events are platonic field tuples, **not** MIDI events. Each
carries:

- `vuid` — base-36 monotonic, allocated from `template.eventCtr`. Stable
  across rebuilds and save/load. The `(blockId, vuid)` pair is the
  persistent identity of a materialised event; its mm-uuid is
  ephemeral.
- `col` — the `colKey` of the column the event sits in. Used to look up
  the per-colKey xform slot; pinned at creation, never mutated by
  xform.
- `ppqL` — logical-ppq offset from the block's `ppqLo`.
- Field values — `pitch`, `durL`, `vel`, `delay`, `chan`, `val`,
  `detune` etc., as appropriate to the event type implied by `col`.

```lua
template.events['1'] = {
  col      = 'note:1:60:pitch',
  ppqL = 0,
  pitch    = 60, durL = 480, vel = 96, ...
}
template.events['2'] = {
  col      = 'cc:1:7',
  ppqL = 240,
  val      = 100,
}
```

A materialised event in the block instance carries
`(blockId, vuid)` as metadata. That triple is its persistent identity
across rebuilds.

### Xform — `'*'` sentinel + per-colKey

`block.xform[K]` is an op-list-per-field of the shape from
`aliases.md`. Two keying conventions:

- `'*'` — geometric xform applied uniformly to every template event in
  the block. The natural home for `ppqL`, `durL`, `delay` ops.
  Moving / scaling the whole block writes here.
- `colKey` — content xform applied only to template events whose
  `col == colKey`. The natural home for `pitch`, `vel`, `val`,
  `detune`, `chan` ops. Per-column tweaks land here.

The data shape does not enforce the split — `xform['*'].pitch` is
syntactically legal — but the command layer routes by convention.
Block-wide geometric verbs write `'*'`; content verbs write the
cursor's `colKey`. A selection spanning multiple colKeys fans out
across them.

Resolution composes `'*'` first, then the colKey:

```
resolveField(vuid, F) =
  applyOps(applyOps(template.events[vuid][F],
                    block.xform['*'][F]  or {}),
           block.xform[col(vuid)][F] or {})
```

Composition with `aliases.md`'s op semantics is unchanged: ops are
applied left-to-right within each list; coalescence rules carry over.

### Allowed ops — phase 1 (deterministic only)

Phase 1 supports the **literal-arg deterministic** subset of the
`aliases.md` op vocabulary: `add`, `mul`, `snap`, all with number-
literal arguments. The resolved field is a deterministic function of
the template field; the grid displays the **post-xform** value, since
the user expects what they see to match what plays.

Stochastic and modulation ops — `rand` arguments, future `sin` /
`lfo` / per-emit modulators — defer to a separate **FX layer**.
The FX layer runs at materialisation time but does not feed the grid
display, so the grid stays grid-faithful. The FX op vocabulary is
distinct from `block.xform` so the two phases do not entangle. Verb
namespace, storage slot, and resolver are all separate; details
deferred until that phase.

### Mixed event types

A block may contain events of any type — notes, ccs, pitchbend —
mixed in one block. The single-event-type restriction from earlier
drafts is lifted. The per-colKey xform keying makes this natural: a
mixed block writes pitch ops only under note colKeys and val ops only
under cc/pb colKeys; content xforms cannot cross types because they
share no slot.

---

## Resolution

### Reconciliation pass (tm-side, before the walker)

On every `'reload'` from mm, before the alias walker from `aliases.md`
runs:

1. For each region in `cm:get('regions').regions` whose `template.events` is non-empty:
   - For each template event `vuid`:
     - Compute the synthetic-root key `(blockId, vuid)`.
     - Compute resolved fields via `resolveField` above. `ppqL` comes
       from `block.ppqLo + template.events[vuid].ppqL`, then composes
       through `xform['*'].ppqL` and `xform[col].ppqL`.
     - Ensure a spec node exists tagged with `(blockId, vuid)` and
       parented at the synthetic root. If absent, create with empty
       `overrideXform`. If present, leave `overrideXform` untouched.
   - Prune spec nodes tagged with `(blockId, *)` whose `vuid` is no
     longer in `template.events`.

2. Prune blocks whose `template.events` is empty AND `xform` is empty
   (the record decays back to a plain region).

3. The alias walker then runs as `aliases.md` describes, reading the
   synthetic-root-parented spec nodes.

### Synthetic roots

Spec nodes need parents. For block-materialised events, the parent is
a synthetic root keyed `{blockId, vuid}`. It has no MIDI emission and
no fields of its own — its resolved fields are computed on demand from
`template.events[vuid]` composed through the block's xform.

The parent-resolution branch in the walker is the only intrusion the
block layer makes into the spec layer. Other branches are unchanged.

### Source mutation propagates automatically

Adding / deleting / editing a template event surfaces in the next
rebuild because reconciliation reads the current template. No
explicit sync. (Under multi-instance, this is the load-bearing
auto-sync; under single-instance it is trivially correct.)

---

## Mutation

Block mutation falls in three categories at the command surface.

### Template-edit (the common case)

The user nudges, adds, deletes, or otherwise edits a materialised
block event. Intent is to edit the shared content.

1. Find the event's `(blockId, vuid)` metadata.
2. Compute the equivalent edit on the template event:
   - For invertible xforms (composed `add` and `mul ≠ 0` with literal
     args), apply the inverse of `xform['*'] ∘ xform[col]` to the
     user's edit, then apply to `template.events[vuid][field]`.
   - For non-invertible (`snap`, or any future non-literal arg), degrade
     to per-event override — the edit lands in
     `specNode.overrideXform` for this materialisation only. Surface a
     status warning ("block edit applied to this materialisation only —
     structural transform is not invertible"). The user can sever to
     make the override permanent.

Adding an event inside the block's region: synthesise a template event
with `col` and `ppqL` from the cursor / event position, allocate a
fresh `vuid`, write to `template.events`. Reconciliation creates the
spec node.

Deleting an event inside the block's region: drop the template event
by `vuid`. Reconciliation prunes the spec node.

### Block-wide edit

A command targeting the block as a whole composes into `block.xform`:

- **Geometric** verbs (move, scale, quantize-position) compose into
  `xform['*']` under `ppqL` / `durL` / `delay`. All
  template events in the block are affected uniformly.
- **Content** verbs (shift pitch, shift vel, shift val) compose into
  `xform[K]` where `K` is the cursor's colKey, or fan out across the
  selection's colKeys. Only template events on those colKeys are
  affected.

`xform['*'].val` ("shift every value field across heterogeneous
columns by N") is **refused** at the command surface — it's
semantically nonsense across CC numbers and pitchbend.

### Per-event override

Explicit override verbs (per-event humanise via modifier, per-event
nudge via modifier) write into `specNode.overrideXform` of the touched
materialisation only. No propagation. The template is unchanged.

The command surface distinguishes the three by mode and/or modifier;
specifics deferred to phase 3.

---

## Reference counting

A block lives as long as it has *content or shape*:

- `template.events` non-empty → block is live.
- `template.events` empty but `xform` non-empty → block persists (an
  empty staged xform).
- Both empty → record decays to a plain region (the tinted slab
  persists; the block-shaped surface is gone).

Severance under single-instance: extracting the block's content to
plain MIDI events drops the template, drops the xform, and drops the
record (region included if the user chose) — equivalent to "convert to
plain MIDI."

Multi-instance reference counting (the `#instances == 0 ⇒ block GCd`
rule) lands when multi-instance arrives.

---

## Composition with single-event aliases

A materialised block event can itself be a parent for further spec
nodes outside the block — its synthetic-root resolved fields are the
parent fields, and per-event aliases compose on top normally.

The reverse — a single-event alias whose parent is a block
materialisation — is also fine; the parent uuid is the materialised
event's ephemeral uuid, and on rebuild the alias re-derives. (Same
contract as today; nothing block-specific.)

---

## Precedence and collisions

The slot key from `aliases.md` carries over: `(chan, pitch, ppq)` for
notes, `(chan, msgType, id, ppq)` for ccs. BFS order extends to
synthetic roots:

- Depth 0: plain MIDI events.
- Depth 1: block template events (resolved through their synthetic
  root) and single-event spec nodes alike.
- Depth ≥ 2: nested spec children (per-event overrides count as depth
  ≥ 2 under a synthetic root).

First arrival wins the slot; losers are suppressed-but-spec-retained.
Resurface is automatic when the blocker moves, same as today.

---

## Visual representation

(Renderer-side; final design in `docs/renderManager.md` once landed.)

The block's region tint already exists. Additions:

- **Block colour** — distinct per-block hue (already on regions as
  `colour`), tints the slab and outlines materialised events.
- **Materialisation marker** — a small glyph distinguishes block-
  materialised events from plain MIDI. Echoes the alias marker but is
  block-coloured.
- **Xform-head readout** — the active block's gutter bar gains a
  compact text glyph of the xform's trailing ops per field
  (`+5v ±3v` for "vel +5 then humanise ±3"). Drops when xform is
  empty.

The template events themselves are not rendered (they have no
position outside the block); only their materialisations are.

---

## Phasing

| phase | scope |
|---|---|
| 0 | this design doc |
| 1 | schema (single cm take-tier key `regions`, blob shape `{ regions = [...], idCtr = N }`), pure helpers in `regions.lua` (`allocVuid`, `composeOp`, `refuseStarVal`, `resolveEvent`), cm round-trip |
| 2 | reconciliation pass (tm) — synthesise / prune spec nodes parented at synthetic roots, walker parent-resolution branch for `{blockId, vuid}` |
| 3 | mutation routing — template-edit / block-wide-`'*'`-vs-`colKey` / per-event-override at the command surface; inverse path for invertible literal-arg ops; degrade-to-override for `snap` |
| 4 | creation UX — within region mode, `blockSeed` walks the events currently in the region and writes them into `template.events`; `blockClear` empties the template; deterministic block-wide / content edit verbs |
| 5 | severance: extract block content to plain MIDI; record decay to plain region |
| 6 | renderer markers, xform-head gutter readout |
| later | multi-instance: paste-as-instance, duplicate-as-instance, multi-instance hard-link semantics |
| later | FX layer: stochastic / modulation ops (`rand`, `sin`, `lfo`) in a separate verb namespace, materialisation-only, not in grid display |

---

## Test surface

Pure helpers for the block layer live in `regions.lua` and are pinned
in `tests/specs/regions_helpers_spec.lua` alongside the existing
region-storage tests. Higher-phase reconciliation / mutation tests
land under `tests/specs/blocks_*.lua`.

**Phase 1** — pure helpers and cm round-trip (✅ landed)
- `resolveEvent(template, xformStar, xformCol, evtType, rng)`
  composes `'*'` then `[col]` then applies via `aliases.applyXform`;
  either xform may be nil; cross-event-type fail-closed inherited
  from `applyXform`.
- `composeOp(region, slotKey, field, op)` delegates to
  `aliases.appendOp` — coalescence rules carry over.
- `allocVuid(region)` lazily inits `template` and returns a fresh
  base36 vuid.
- `refuseStarVal(slotKey, field)` — predicate for the command-surface
  refusal of block-wide val shifts across heterogeneous columns.
- cm round-trip: write `cm:set('take', 'regions', blob)`, reload a
  fresh cm against the same take, deep-equal.

**Phase 2** — reconciliation
- Template event present in block → spec node appears at
  `{blockId, vuid}` on next rebuild.
- Template event removed → spec node pruned.
- Block with `xform['*'].ppq={add, lpr}` materialises events one row
  later than `ppqL` implies; grid reflects post-xform position.
- Synthetic-root resolved fields compose `template.events[vuid]` plus
  full xform stack.

**Phase 3** — mutation
- Edit-through with literal-arg `add` xform: template field updates by
  inverse delta; materialisation reflects unchanged at the user's
  nudged position.
- Edit-through under `snap` xform: lands as per-event override; other
  fields unchanged.
- Block-wide geometric nudge composes into `xform['*'].ppq`; block-
  wide content nudge composes into `xform[cursorColKey].<field>`.
- `xform['*'].val` write is refused at the command surface.

**Phase 4** — creation
- `blockSeed` on a region containing N events writes N template events
  with correct `col`, `ppqL`, and content; the original events are
  removed from MIDI (now materialised via reconciliation).
- `blockClear` empties `template.events`; reconciliation prunes; the
  record decays to plain region if `xform` also empty.

**Phase 5** — severance
- Sever extracts every materialisation to plain MIDI with current
  resolved fields, drops template + xform, drops the block record.

---

## Open questions

- **Invertibility threshold for edit-through** — literal-arg `add`
  and `mul (k≠0)` invert exactly. Composed invertibles invert. `snap`
  and (later) `rand`-arg ops do not. Walk the xform op list at the
  routing site; if any op is non-invertible, refuse inverse and
  degrade to override.
- **Block colour allocation** — phase 1 uses the existing region
  `colour` field. Verify the palette is large enough once blocks
  proliferate; punt to renderer phase.
- **Block ↔ region UX semantics** — a region with only `xform` (no
  template) is a "staged" block. Should that state be reachable via
  the UI, or only ever as a transient between `blockSeed` calls?
  Defer to phase 4 with the create flow.
- **FX-layer surface** — vocabulary, storage, materialisation
  semantics, FX-vs-xform precedence. Full deferral; reopen when the
  block xform shape has settled.
