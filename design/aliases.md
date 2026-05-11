# Aliases — pooled events with transformations

A working design doc for the alias/pooled-event feature. Future
`docs/aliases.md` is distilled from this once code lands.

An **alias** is a copy of an existing event that follows its source under
a stored transformation. When the source mutates, the alias is
re-derived. Aliases form trees: aliases of aliases obey the same rule.
The result is a lightweight algorithmic-composition substrate inside a
single Continuum take.

---

## Identity & persistence

### Spec tree on the root

The whole descendant tree of an aliased event lives as metadata on the
**root** — the topmost ancestor with no parent. Nothing canonical lives
on the materialised children.

```lua
note.aliases  = {                                  -- ordered, creation-time
  { id='1', xform={ ppq={{'add',120}}, pitch={{'add',7}} },
    children = {
      { id='1.1', xform={ ppq={{'add',240}} }, children={} },
    },
  },
  { id='2', xform={ ppqL={{'add',480}} }, children={} },
  -- humanise: per-emit random vel offset; no other transform
  { id='3', xform={ vel={{'add',{'rand',-3,5}}} }, children={} },
}
note.aliasCtr = 4                                  -- next id allocator
```

- `id` — base-36 monotonic, allocated per-root from `aliasCtr`. Stable
  across rebuilds and save/load. Spec-paths are root-relative, so global
  uniqueness isn't needed.
- `xform` — `{ <field> = { <op-entry>, ... }, ... }`. Each field maps
  to an ordered list of op entries; each entry is
  `{<opcode>, <arg>, ...}`. Args may be literals or sub-expression
  tables (e.g. `{'rand', lo, hi}`). Empty / absent field lists are
  identity. Composition across the spec tree is **per-field
  concatenation**: child's op list for field `f` is appended to
  parent's, and the whole list is applied left-to-right.
- `children` — ordered list of nested specs, same shape recursively.

`aliases` and `aliasCtr` ride the existing metadata pass-through:
mm declares structural fields (`noteEventFields`, `ccEventFields`) and
serialises everything else to take extension data via `saveMetadatum`.
No whitelist edits are required for either notes or ccs.

### Materialised events

Every emitted alias is a real MIDI event with two fields of metadata:

```lua
parentUuid = '<root_uuid>'   -- which root's tree owns me
specPath   = '1.1.2'         -- dotted id path from root to my spec node
```

Both are written fresh each rebuild. The materialised event's own UUID
is **ephemeral** — regenerated on every rebuild (sidecar/notation
events come and go with it). The persistent identity of an aliased
event is `(parentUuid, specPath)`, not its MIDI UUID.

Ephemerality is enforced by tm, not mm. mm continues to mint permanent
UUIDs for every event it sees; the rebuild sweep (see **Resolution**)
deletes all events carrying `parentUuid` metadata before re-emitting,
so each materialisation cycle produces a new MIDI event with a new
UUID. The contract for callers: never key persistent state on a
materialised event's UUID — use `(parentUuid, specPath)`.

Per-child user metadata (anything the user wants a specific child to
"carry") goes in the spec node, not on the materialised event — because
the event is ephemeral.

---

## Op vocabulary

A node's `xform` is per-field. Each field's value is an ordered list
of **op entries** applied left-to-right to the field's running value
(starting from the parent's resolved value).

```lua
xform = {
  ppq = { {'add', 4}, {'mul', 0.5}, {'add', {'rand', -3, 4}} },
  vel = { {'add', {'rand', -3, 5}} },
}
```

### Op entries

An op entry is `{<opcode>, <arg1>, <arg2>, ...}`. An argument is
either a number literal or a value-producing sub-expression table.

**Phase 1 opcodes:**

| opcode | arity | role | semantics |
|---|---|---|---|
| `add` | 1 | applied | running += arg |
| `mul` | 1 | applied | running *= arg |
| `rand` | 2 | value-producing | returns `uniform(arg1, arg2)`; only valid as an argument to `add`/`mul` |

Reserved (not implemented Phase 1): `snap`, `mod`, `clamp`, `sin`, …

`rand` draws fresh per emit. The xform spec is deterministic data; the
*resolved value* of a field is stochastic at materialisation time iff
its op list contains a `rand` argument anywhere.

### Allowed fields, per event type

- **note** — `ppq`, `ppqL`, `dur`, `durL`, `pitch`, `detune`, `vel`,
  `chan`, `delay`
- **cc** — `ppq`, `ppqL`, `val`, `chan`, `delay`

A transform carried across rebuilds may contain field entries
meaningless to the current event type; they fail closed (field
skipped, no mutation). Validity table lives in `aliases.lua`.

### Composition

Across the spec tree, composition is **per-field concatenation**: for
each field, the child's op list is appended to the parent's, and the
combined list is applied left-to-right to the field's starting value
(typically the root's actual field value).

Siblings are independent (each sees the parent's op list, not each
other's). A node with no entry for field `f` is identity on `f`.

### Coalescence

When an edit appends an op to a field's list, if the trailing op has
the same opcode AND both ops have all-literal args, merge:

- `{'add', a}` + `{'add', b}` → `{'add', a + b}`
- `{'mul', a}` + `{'mul', b}` → `{'mul', a * b}`

Otherwise append. A literal-arg `add` followed by a `rand`-arg `add`
does *not* coalesce (the second has a non-literal arg). Different
opcodes never coalesce.

This is the only coalescence rule. It is local (trailing op only) and
contained (literal args only). "Scale by `k` around anchor `a`" is
two ops: `{'mul', k}` then `{'add', a*(1-k)}`; subsequent nudges
coalesce into the trailing `add`.

---

## Resolution

### Rebuild walk (tm-side)

On every `'reload'` from mm, tm:

1. Sweeps events; treats every event with `parentUuid` metadata as a
   **stale materialisation** and queues it for deletion.
2. Builds a `uuid → root_event` index from non-materialised events.
3. For each root, BFS its spec tree. At each node:
   - Resolve fields = `applyXform(parent_resolved_fields, spec.xform, evtType)`.
   - Check the **claims** map (see **Precedence**). If claimed, skip
     emission of this node. Continue walking children with the
     would-be-resolved fields as their parent state — children resolve
     independently of whether intermediate ancestors materialised.
   - If unclaimed, queue an emit with `parentUuid` + `specPath`, and
     claim the slot.
4. Flush queued deletes and adds in a single `mm:modify`.

Roots and depth-0 plain events are placed first, so real-beats-alias is
a corollary of BFS order, not a separate rule.

### Touched-set optimisation

Full rebuild on every reload churns sidecars/notation events
unnecessarily — most reloads only touch one root's subtree. The
optimisation:

- mm tracks a **touched set** during `modify`: every `add*` / `assign*`
  / `delete*` call records the affected uuid (or "structural" sentinel
  for grid-level changes that affect everyone).
- `'reload'` fires with `data = { touched = {<uuid>=true, ...} }` (or
  `{ touched = 'all' }` for take swaps and bulk operations).
- tm rebuild only re-emits subtrees whose root is in `touched`. Other
  roots' materialisations stay in MIDI untouched.

Edge: if a materialised alias is touched (user nudged a child),
`route()` (see **Mutation**) writes the change to the root's spec, then
the root counts as touched and its subtree re-emits. The materialised
event being directly touched is never the rebuild trigger — the spec
update is.

This optimisation is Phase 2.5. v1 ships without it; the touched
mechanism is added once we have realistic alias trees to profile against.

### Avoiding rebuild loops

tm's rebuild plants new materialisations via `mm:modify`, which fires
its own `'reload'`. To avoid an infinite loop, the rebuild-driven
modify carries a flag: `mm:modify(fn, { silent = true })` skips the
trailing reload. tm sets this when its writes are derived from spec
state and add no new user intent.

---

## Mutation

Every editing command is tagged with one of four roles. Routing through
`aliasRouter.route(evt, opkind, value)` is uniform; the role decides
what `route` does.

### Relative — composes into transform

If `evt.parentUuid` is set, walk to the spec node and append (with
coalescence — see §Op vocabulary/Coalescence) to the relevant field's
op list. Otherwise mutate the event directly.

| command | field | op appended |
|---|---|---|
| `nudgeBack/Forward` (`adjustPosition`) | `ppq`  | `{'add', δ}` |
| `growNote`/`shrinkNote` (`adjustDuration`) | `dur` | `{'add', δ}` |
| `nudgeCoarse/Fine Up/Down`, pitch | `pitch` | `{'add', δ}` |
| `nudgeCoarse/Fine Up/Down`, vel | `vel` | `{'add', δ}` |
| `nudgeCoarse/Fine Up/Down`, val | `val` | `{'add', δ}` |
| `nudgeCoarse/Fine Up/Down`, delay | `delay` | `{'add', δ}` |
| `insertRow`, `deleteRow` | `ppqL` | `{'add', δ}` per affected event |
| (new) `shift` | `<f>` (cursor) | `{'add', δ}` |
| (new) `scale` | `<f>` (cursor) | `{'mul', k}` then `{'add', a*(1-k)}` for anchor `a` |
| (new) `humanise` | `<f>` (cursor) | `{'add', {'rand', lo, hi}}` |

`insertRow`/`deleteRow` append `{'add', δ}` to `ppqL` (logical, not
realised — the existing `shiftPlan` re-derives `ppq` from `ppqL`
through swing) on aliased children even when their parent lies
outside the shifted region. The alias drifts from its parent —
accepted.

### Absolute — severs

If `evt.parentUuid` is set, sever first (pluck-and-promote, see
**Severance**), then apply the op to the now-root. Otherwise mutate
directly.

| command | why |
|---|---|
| `quantize`, `quantizeKeepRealised` | snaps logical ppq to grid; the snap is a property of realised position, not a delta worth carrying as the parent moves |

### Re-relativised — absolute target, relative composition

Some commands present as absolute to the user but compose cleanly when
expressed as a delta against the resolved value. On an aliased event,
compute `δ = target - resolved.<field>` and append the relative op;
otherwise mutate directly.

| command | field | δ source |
|---|---|---|
| typed pitch input (qwerty row), repitching | `pitch` | typed − resolved.pitch |
| `noteOff` | `dur`   | newDur − resolved.dur |

### Refused on aliased — whole command no-ops with a UI warning

| command | why |
|---|---|
| `interpolate` | writes computed absolute values across a span; if any selected event is aliased, the whole command is refused (a partial interpolation that silently skipped the aliased events would produce a misleading curve) and a status warning is surfaced |

### Structural — alters the spec tree

| command | behaviour |
|---|---|
| `delete`, `deleteSel`, `cut` (on aliased event) | remove spec node; sever-and-promote its children to new roots |
| `copy`, `paste`, `duplicateDown/Up` (in alias mode) | add a new spec node under the source's root |
| `sever` (new, `Ctrl+.`) | pluck-and-promote without other modification |

### Recompute — neither composes nor severs

| command | why |
|---|---|
| `reswing*` | recomputes intent from logical via swing curve; spec transforms operate on logical and intent symmetrically and stay valid |

---

## Precedence and collisions

**Rule.** Place events in BFS order from roots, depth 0 first, ties by
spec-creation order. First arrival owns the slot.

The slot key is the realisation key:
- Notes: `(chan, pitch, ppq)`.
- CCs: `(chan, msgType, id, ppq)`.

A would-be alias whose slot is taken is **suppressed** for this
rebuild cycle: not emitted to MIDI, but its spec is untouched. Its
descendants resolve from the would-be-resolved fields (as if the alias
had emitted) and may themselves emit, suppress, etc.

When the blocker moves or the alias's transform changes such that the
slot is free, the next rebuild emits the previously-suppressed alias —
**resurface**. The mechanism is the same BFS walk; no special case.

**Real-beats-alias** falls out: a real (non-aliased) event is a depth-0
node in its own (possibly trivial) tree, placed before any depth-≥-1
descendant of any tree.

---

## Severance

### Sever-and-promote

To sever a spec node `S` from its parent:

1. Locate `S` by `(parentUuid, specPath)` in the root's spec tree.
2. Pluck the subtree rooted at `S` from its parent's `children` list.
3. Promote the live materialised MIDI event in place into the new root:
   - Its currently-resolved fields are already what we want — the walker
     just emitted them.
   - Strip `parentUuid` and `specPath` from its metadata.
   - Stamp the plucked subtree's `children` as the new root's `aliases`,
     and set `aliasCtr` past the highest id in that subtree.
   - The mm-uuid the walker minted for it stops being ephemeral by
     convention (the rebuild sweep only deletes events that still carry
     `parentUuid`); it becomes the new root's permanent identity. No
     fresh allocation needed.
4. The subtree under `S` follows by construction: each descendant's
   `xform` was relative to `S`'s resolved state, which is now `S`'s
   baked-in field state, so the resolution math is unchanged. The next
   rebuild deletes the descendants' stale materialisations (still
   carrying the old root's `parentUuid`) and re-emits them under the
   new root.

`xform` on `S` is forgotten in the promotion — a root has no transform
because it has no parent.

### Cascade-delete vs sever-and-promote

`delete` on an aliased event removes its spec node. Its children's
default behaviour is **sever-and-promote** — they become new roots with
their currently-resolved fields baked in. UI offers cascade-delete as
an explicit alternative.

`delete` on a root: same rule — children of the root become new roots.

---

## Creation UX

- `` ` `` toggles **alias mode** (`vm.aliasMode`). Renderer shows a
  small indicator when on (Phase 7).
- `copy`/`cut` always capture `aliasSrc = { uuid, specPath, ppqL }` per
  event (uuid is `parentUuid` if the source is itself aliased, else its
  own uuid). The mode is sampled at **paste/duplicate time**: in alias
  mode each event becomes a new spec node; out of alias mode the writer
  strips `aliasSrc` and writes plain events. This means a single clip
  can paste either way — toggle the mode between pastes without
  re-copying. In alias mode each event becomes a new spec node:
  - source plain (`specPath` nil): node lands at top of `root.aliases`.
  - source aliased (`specPath` set): node lands as a **child** of that
    spec node (so the new node's resolved fields compose onto its
    source's resolved fields). Always child, never sibling.
- Phase 4 seeds only `ppqL` from row delta (`{'add', newPpqL - srcPpqL}`).
  `pitch`/`chan` deltas defer to Phase 6's `shift`; alias-paste leaves
  those fields inherited.
- `duplicate` is `copy + paste` with a one-shot cache (`vm.dupeClip`):
  the first duplicate of a run collects and pastes; subsequent
  immediate duplicates re-paste the cached clip so successive offsets
  anchor to the original source's `ppqL`. Any non-duplicate command
  clears the cache.
- Out of alias mode, these commands behave as today.
- `Ctrl+.` is `sever`.

The same routing path serves `paste`, `duplicate*`, `shift`, `scale`,
and the family of relative nudges — the only differences are which op
is composed and whether a new spec node is being created or an existing
one is being updated.

---

## Cycle prevention

Cycles cannot arise: every alias is a *new event*, and its `parentUuid`
is set at creation to point at an event that already exists. Editing a
materialised event can sever or update its transform, but never
re-parent. So the spec tree is a tree by construction.

---

## Visual representation

(Renderer-side; final design in `docs/renderManager.md` once landed.)

- Materialised aliases get a visual marker — a `cm`-defined role
  colour, probably a tint or border distinguishing them from plain
  events. Final choice deferred to Phase 7.
- Suppressed aliases (collision losers) are not rendered; v1 does not
  ghost them. Possible v1.1 enhancement.
- Alias-mode indicator in the toolbar.

---

## Phasing

| phase | scope |
|---|---|
| 0 | this design doc |
| 1 | schema, spec_id allocation, `aliases.lua` pure helpers, serialise round-trip |
| 2 | tm rebuild walker (full rebuild every reload, no touched-set yet) |
| 2.5 | touched-set optimisation: mm tracks mutations, `'reload'` carries `data.touched`, tm rebuild reads it |
| 3 | edit routing (`route()`), relative-command dispatch with append+coalesce into per-field op lists |
| 4 | alias mode, creation hooks on copy/paste/duplicate |
| 5 | severance command + structural-command handling |
| 6 | new commands: `scale`, `shift`, `humanise` (rand-arg helper) |
| 7 | renderer markers and alias-mode indicator |

Each phase has a regression-test surface; see `Test surface` below.

---

## Test surface

Tests live under `tests/specs/aliases_*.lua` plus pure-helper specs in
`tests/specs/aliases_helpers_spec.lua`.

**Phase 1** — pure helpers
- `applyXform` correctness for each allowed field, each opcode
  (`add`, `mul`), each event type. Empty op list is identity.
- Left-to-right ordering: `{{'mul',k},{'add',δ}}` resolves
  `f ↦ k*f + δ`; reversed list resolves `f ↦ k*(f + δ)`.
- `rand` is value-producing only (used as arg to `add`/`mul`); the
  resolver is the call site, not the arg-evaluator. Test with an
  injectable RNG seeded for determinism: a `{'rand', -3, 5}` arg
  yields a value in `[-3, 5]`; sampling distribution is uniform
  within tolerance over N draws.
- Cross-type fail-closed: a `pitch` field on a cc xform is skipped
  with no error.
- Cross-node composition (per-field concatenation): parent
  ppq=`{{'add',a1},{'mul',k1}}` then child
  ppq=`{{'mul',k2},{'add',a2}}` resolves to
  `k2*(k1*(x+a1)) + a2`.
- `appendOp` coalesces literal-arg `add`+`add` (sum), literal-arg
  `mul`+`mul` (product); refuses to coalesce across different
  opcodes; refuses to coalesce when either op has a non-literal arg
  (e.g. a `{'rand',...}` argument).
- `find` / `pluckSubtree` on deep trees with non-trivial spec_paths.
- `util.serialise` round-trip on nested spec trees with the
  per-field op-list shape.

**Phase 2** — rebuild walker
- Single-level alias materialises with correct resolved fields.
- Three-level alias resolves transitively.
- Collision suppresses leaf, spec persists.
- Move blocker → alias resurfaces in next rebuild.
- Collision on intermediate node suppresses just that node;
  descendants still resolve from would-be state.

**Phase 3** — edit routing
- Relative edit on aliased child: the field's op list grows (or its
  trailing op coalesces); parent unchanged.
- Relative edit on plain event: behaves identically to today.
- Two same-direction nudges land as a single coalesced trailing
  `{'add', δ}` in the field's op list.
- A nudge after a `{'add', {'rand', ...}}` appends a fresh
  `{'add', δ}` rather than mutating the rand entry.

**Phase 4** — creation
- Alias-paste at row+4 of a plain source produces a top-level spec
  under `root.aliases` with `add.ppqL` matching 4 rows.
- Duplicate down on an already-aliased event creates a **child** of
  the source spec node (not a sibling, not nested under the
  duplicated event's existing tree).
- Successive immediate duplicates re-paste the cached clip; from a
  plain source they produce top-level siblings with progressive `ppqL`
  offsets relative to the source's original ppqL.
- Any non-duplicate command between duplicates clears the cache, so
  the next duplicate re-collects from the current selection.

**Phase 5** — severance
- Sever preserves resolved field state at the moment of severance.
- Sever preserves the descendant subtree (children stay aliased to the
  newly-promoted root).
- Delete on root cascades children to new roots with cached fields.
- Absolute edit on aliased child severs and writes through.

**Phase 6** — new commands
- `scale 0.5` on a 4-event aliased group produces correctly-spaced
  resolved positions (anchor → trailing `{'add', a*(1-k)}` after the
  `{'mul', k}`).
- `shift` appends `{'add', δ}` into the cursor field's op list.
- `humanise ±5` on vel appends `{'add', {'rand', -5, 5}}`. Successive
  invocations append fresh entries (no coalescence — non-literal args).

---

## Open questions

- **Ghost rendering** of suppressed aliases (v1.1?).
- **`scale` in val cursor on a note** — does it mean `velscale`? Small
  UX call, settle in Phase 6.
- **Profiling** — when does the touched-set optimisation become
  necessary? Answer once realistic alias-tree sizes exist.
