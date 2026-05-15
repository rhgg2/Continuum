# Dungeon

Frozen archive of three layered features that grew into one another and
collectively became too tangled to evolve. Removed from the live tree
in a single scorched-earth commit so we can rebuild blocks from a clean
model. Kept here as reference: there's working machinery worth
pillaging — `opIsDisplayable`, `parseColKey/colKey`, base36 vuid,
the xform op-list data shape — but the *integration* shape is what
killed it.

## What's in here

- **`src/aliases.lua`** — the aliased-event system. Per-field xform
  ops (`add k`, `mul k`, `snap`, `rand`, ...) composed into a tree of
  spec nodes hung off mm root events. `applyXform`, `appendOp`,
  `pluckNode`, `localRoots`, `validFields` (`NOTE_FIELDS` /
  `CC_FIELDS`), `opIsDisplayable`, `makeRng`. Originally shipped as a
  user-facing feature ("alias notes" — typed children of a parent
  note that mirror it under a per-field transform).
- **`src/regions.lua`** — pure helpers for the *region* primitive
  (tinted authoring zones over the tracker grid: `(ppqLo, ppqHi,
  parts={[colKey]=true})`). Also accreted the **blocks** helpers
  (`allocVuid`, `composeOp`, `refuseStarVal`, `resolveEvent`,
  `resolveSyntheticRoot`) when blocks tried to live as "regions with a
  template."
- **`design/aliases.md`** — the aliased-event model.
- **`design/blocks.md`** — the (now defunct) blocks-as-extended-regions
  design. Phase 1 landed (storage, helpers); phase 2 landed
  (reconciliation pass in tm); phase 3 (mutation routing) was where
  the design unravelled.
- **`maps/`** — generated outlines for the two source files.
- **`tests/`** — 13 alias spec files, 1 regions-helpers spec, 1
  ec-regions spec, 1 blocks-reconciliation spec.

## How it accreted

1. **Aliases** shipped first as a content-only feature: a parent
   event plus N child specs, each carrying an op-list per field;
   the walker composes parent fields through child xforms to yield
   materialised events. Owns the xform op shape, the field whitelist
   per evType, the cross-type fail-closed contract, and an RNG hook
   for non-deterministic ops.
2. **Regions** shipped next as a separate authoring primitive — a
   sparse rectangle (`ppqLo/ppqHi/parts`) over the tracker grid,
   used as a tinting/selection zone. Lived in `editCursor`, persisted
   per-take via cm. Independent of aliases.
3. **Blocks** were attempted as "a region whose template events get
   duplicated." The decision to fold blocks INTO regions
   (region.template, region.xform, synthetic root keyed by
   (blockId, vuid)) put four jobs on one object: tinted zone,
   xform stack, content template, and instance anchor. Each job
   needed a different shape. That's where it stopped being clean.

## Smells that justified the rip

- **Region was the wrong shape for a block.** A block's natural
  shape is "the events it contains," not a rectangle. The
  `ppqLo/ppqHi/parts` mask never quite fit: extend it past the
  events and it implies parts that don't exist; crop it and it
  cropped the block.
- **Two-jobs-one-object.** `region.xform` did double duty as
  "transform applied to whatever's in this zone" (region behaviour)
  and "transform applied to the block's template events at emit"
  (block behaviour). They want different lifetimes, different
  composition rules, different UX.
- **Live-mirror authoring at the take view.** Editing a block-mate
  cell from the take view forced the write path to detect "is this
  cell inside a block?", invert the composed display xform back to a
  template field, allocate vuids on authoring, and disambiguate
  per-instance overrides — at every keystroke. The complexity was
  bookkeeping for "the take view edits two different things and has
  to know which."
- **Display vs emit split** appeared because composing
  non-invertible ops (`snap`, `rand`, `lfo`) into the displayed event
  meant the user couldn't edit through them. We tried to filter ops
  by displayability so the displayed and emit forms could diverge,
  with edits landing on the displayed form. Workable but doubled the
  resolution path and never felt like the right home for the
  complexity.
- **Per-event override** as opaque-event-or-field-add-stack — never
  fully resolved. Opaque overrides are simple but lose sync when the
  canonical changes; field-level adds reintroduce a sliver of the op
  machinery for a per-instance use case. Modifier-author and
  modifier-delete each spawn their own asymmetries.
- **Aliases was simultaneously load-bearing and obscuring the path.**
  Its xform machinery was the natural reach for blocks (literal-arg
  add/mul, op composition, displayable predicate, evType field
  whitelisting), but reusing it tied blocks to the aliased-event
  tree's contracts. Independently, aliases-the-user-feature wasn't
  earning its weight — typed alias children with per-field xforms is
  a niche capability that explains a lot of the surface area in tm,
  clipboard, and trackerView. Pulling all three out together was
  cleaner than untangling.

## What's worth pillaging

- `opIsDisplayable(op)` predicate and the literal-arg add/mul
  invertibility framing — useful if any future feature wants
  edit-through over composed ops.
- `parseColKey` / `colKey` (the colKey string scheme) — clean way to
  identify a tracker column-part by string for sparse storage.
- `util.toBase36` + the `eventCtr`-based vuid allocation pattern —
  stable IDs that survive save/load and rebuild without an
  uuid-generator.
- The xform op-list data shape (`{ field = { {opcode, ...args}, ... } }`)
  and the `appendOp` coalescence rule — clean composition primitive.
- Cross-type fail-closed via `validFields(evType)` — defensive
  pattern for "don't apply pitch ops to a CC."

## What's NOT worth pillaging

- The aliased-event tree as a user feature.
- The region zone (sparse rectangle over the grid) as a primitive —
  selection already does this job, and we never built compelling UX
  on top.
- Any of the blocks-as-regions code: every line of `region.template`,
  `region.xform`, synth-root resolution, three-tuple synth-uuid
  routing.
- The phase-2 `materialiseAliases` synth-root pass in trackerManager
  — built around the wrong storage shape.
