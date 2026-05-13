# aliases

An **alias** is a materialised event that follows a source event under a
stored transformation. Aliases form trees: aliases of aliases compose by
per-field op-list concatenation. The substrate spans `aliases.lua`
(pure helpers), `trackerManager.lua` (walker, routing, severance), and
`trackerView.lua` / `editCursor.lua` (visual index, copy/paste). The
behavioural design is recorded in `design/aliases.md`; this file owns
the steady-state model and the cross-cut concerns the source can't
state in a one-line annotation.

## Persistence

Two fields, both on the **root** (the topmost event in an alias tree):

```lua
root.children = { SpecNode, ... }           -- ordered, position is identity
SpecNode     = { xform, children, [fit] }   -- fit is optional
```

A **materialised child** carries one field: `parentUuid`, pointing at
its root. The child's own MIDI uuid is **ephemeral** — minted fresh by
mm each rebuild, dropped on the next sweep. No persistent identity
lives on the materialised event.

The spec tree is therefore the sole address space across rebuilds. Within
a spec tree, position in the parent's `children` list is identity. There
is no `id` field, no path string, no per-root counter — `#children + 1`
is the next slot.

## Side tables

The pure-position scheme works in storage but is useless in memory: a
materialised event holds nothing that points back at its spec node, and
walking the tree to find one is wasteful per-edit. tm holds two side
tables, both private:

```lua
specOf[uuid]      = SpecNode
nodeMeta[SpecNode] = { parent = SpecNode|nil, uuid = evtUuid|nil }
```

`specOf` is the materialised-event-to-spec lookup. `nodeMeta` extends
the relation upward: `parent = nil` at top-level (the conceptual parent
is the root event, addressed by `root.uuid`); `uuid = nil` when the
spec node failed to materialise this cycle (a collision loser — see
**Suppression** in `design/aliases.md`), so the parent chain stays
walkable even across suppressed intermediaries.

Both maps are cleared at the head of every `tm:rebuild` and repopulated
by the alias walker as it emits. They never persist; save/load erases
them harmlessly because the next rebuild rebuilds them from
`parentUuid` + `root.children`. Cold state and hot state converge at the
first rebuild after load.

## Routing — relative edits

A relative edit on an aliased child resolves the child's spec node via
`specOf[evt.uuid]` and appends the op into the spec node's xform. The
materialised event is **not** touched directly; the next rebuild
re-derives it from the new spec.

Multi-field routing is one call: coupled fields (e.g. `pitch` + `detune`
under a temper, or `ppqL` + `durL` under `scale`) compose in a single
mm snapshot so the half-applied state is never observable. The op-map
form (`{ [field] = op-or-list }`) carries the coupling.

Routing returns false when `specOf` lookup fails — either the event
isn't aliased, or its first rebuild hasn't yet run. The caller falls
through to direct mutation; this is how plain (non-aliased) events stay
on the same surface.

## Severance — pluck by identity

To sever an aliased child is to lift its spec subtree off its parent
and make it a new top-level root. Three things happen, in order:

1. The spec node is plucked from its parent's `children` by table
   identity, not by index. Identity-pluck is the spec-tree counterpart
   to string-path-pluck: it survives positional addressing where
   dotted-base36 paths never could.
2. The plucked subtree's `children` become the new root's `children`.
3. The materialised event drops `parentUuid` and adopts the lifted
   `children` list. **The mm-uuid it already carries becomes its
   permanent identity** — minted ephemeral by the walker, it stops
   being ephemeral by convention because the rebuild sweep only deletes
   events that still carry `parentUuid`. No fresh allocation is needed.

Severance is batched. The walker resolves every target to a spec-node
reference up front, groups by `parentUuid`, then sorts each group
deepest-first via `nodeMeta` and processes. Sorting deepest-first keeps
the per-root snapshot mutations monotonic; identity-pluck dissolves the
ordering hazard (plucking sibling-2 of `[A,B,C,D]` would, under index
addressing, shift C and D — under identity it doesn't matter).

The descendants under a severed node are correct by construction: each
descendant's xform was relative to the severed node's resolved state,
which is now the new root's baked-in field state. The resolution math
is unchanged. The next rebuild deletes the descendants' stale
materialisations (still carrying the old root's `parentUuid`) and
re-emits them under the new root.

## Cascade-delete — promote then drop

`tm:deleteAliased` is the structural delete primitive. Its job is to
promote the direct children of a deleted spec subtree to new roots
before the subtree disappears, so descendant work isn't lost.

Two modes, distinguished by the input event's shape:

- **Aliased child** (`parentUuid` set, `specOf` populated). Each
  direct child of `evt`'s spec node is severed-in-place. Then `evt`'s
  spec node is plucked from its parent. `evt` itself disappears via
  the rebuild sweep — it still carries `parentUuid` and now has no
  surviving spec node to re-emit, so the sweep deletes it.
- **Root with non-empty aliases**. Each top-level child is
  severed-in-place. The root event is then deleted outright.

A **suppressed** branch — a spec child whose `nodeMeta.uuid` is nil
because it lost the slot to a collision — is dropped silently. Its
descendants drop with it; there is no materialised event to promote.

Plain events fall through with `false`, so the caller can dispatch to
`tm:deleteEvent`. The split between structural delete and content
delete lives at the call site, not inside the primitive.

## Copy / paste — the only place a path is needed

Inside a rebuild, addressing is by table identity. Across the
copy → (possibly reload) → paste boundary, identity doesn't survive:
load rebuilds the spec tree into fresh tables. The clipboard therefore
captures a **path** — an integer-array `specIdx` — and resolves it at
paste against the live tree.

### Snapshot

`tm:aliasSrcSnapshot(rootUuid, specIdx)` returns the leaf node's
children (deep-cloned, so the paste brings the source's alias-children
along under the new node) plus a `chain`: one xform-clone per
**ancestor** segment of the path. The leaf is the source — editing or
moving its xform between copy and paste stays compatible. Only
**ancestor** edits count as tree-mutation drift. This is why the chain
excludes the leaf.

For multi-event clips that contain a parent and its descendant, the
collector also records `parentClipId` (the nearest in-clip ancestor's
position in the clip) and `pathXform` (the per-field op-lists
concatenated from family-parent to descendant via `tm:pathXform`). The
paste-side family writer reattaches the descendant under its in-clip
parent's freshly-pasted spec node, using `pathXform` to reproduce the
structural relationship without re-resolving against the source tree.

### Resolution

`tm:resolveAliasSrc(rootUuid, specIdx, chain, evtType)` returns one of
three shapes:

- `nil` — the root is gone, or a path index doesn't resolve. The
  caller demotes silently to a plain write. This is the *(A) case*:
  the source's address space no longer exists; carrying on with the
  alias relation would manufacture a relation against the wrong thing.
- `{ mismatch = true }` — a captured ancestor's xform disagrees with
  the live xform (the user edited the tree between copy and paste), or
  a path xform contains a producing-op (`rand`) we cannot re-roll
  faithfully. The caller demotes loudly: it counts the demotion and
  surfaces a warning ("spec tree edited"). This is the surprising case
  that warrants telling the user.
- `{ resolved = field-table }` — composition succeeded. The caller
  computes a corrective delta against `resolved` and creates the new
  spec node via `tm:createAlias`.

The split between silent and loud demotion is load-bearing. (A)
demotions are routine: deleted-source pastes are how users wipe an
alias relation. Drift demotions are rare and unexpected; failing
silent here would make the alias surface feel arbitrary.

### Family writer

The paste-side writer dispatches by family relation. Events with no
`parentClipId` go through the resolve-and-corrective-delta path
above. Children with a captured `parentClipId` attach via
`tm:createAlias` against the **parent's recorded outcome** (alias
parent → under the parent's new `specIdx`; plain parent → top-level
on the parent's mm-uuid, which mm writes back into the paste record
post-flush). If a parent hasn't fired yet, or its mm-uuid isn't yet
visible to the child, the child is deferred to a `pending` queue and
drained on the next pass.

The writer pipeline (region clear, tail clamp, cap) is identical
between plain-mode and alias-mode pastes. Only the per-event write
differs. This is why `aliasSrc` is collected unconditionally at copy
time: the mode choice happens at paste, so a single clip can paste
either way without re-collecting.

## Visual layer — `vm.aliasIdx`

vm holds its own per-rebuild index over visual-grid records:

```lua
aliasIdx.byUuid[uuid]            = { col, row, evt, chan, ppq, treeParent? }
aliasIdx.byChildren[treeParent]  = sorted list of records
```

`treeParent` is the **spec-tree** parent's uuid — the root for
top-level aliases, an intermediate alias for nested ones. It is
derived from `tm.nodeMeta`, not from `evt.parentUuid` (which always
points at the root, because the walker emits flat).

The visual index is a throwaway snapshot built once per `vm:rebuild`,
not a live cache. Its consumers are the alias-tree navigation
commands and the transient focus highlight; neither needs membership
beyond the rendered range, so the index is keyed by grid-visible
events only.

## Cross-cuts

- **Frames.** Aliased events route relative ops against `ppqL` / `durL`
  (logical), not `ppq` / `endppq` (realised). The realiser re-derives
  the realised stream from logical at rebuild. `delay` is per-emit
  and not in the alias vocabulary; this is the reason
  `quantizeKeepRealised` severs aliased planned events before writing
  — the realised-preservation promise cannot be expressed as an xform.
- **Tuning.** `pitch` and `octave` in the alias vocabulary are
  tuning-step deltas under the active temper, not MIDI semitones. The
  realiser resolves them to `(midi, detune)` at emit. `detune` itself
  is not in the alias vocabulary; alias children inherit the root's
  detune. The corrective-delta computation in the paste writer mirrors
  this: under a temper, the pitch delta is a step delta absorbing both
  pitch and detune shifts; without one, it's a plain semitone delta.
- **`fit`.** A spec node may carry `fit = true`. At rebuild, its
  materialised `endppq` is clipped to the next event on the same
  column, so the alias never spawns a new lane for its successor.
  Paste sets `fit` on newly-created spec nodes by default; aliases
  authored by direct command paths inherit the same default. The
  field exists on the spec node, not on the materialised event.

## What mm sees

Nothing changes at the mm boundary. Roots carry `children` as
pass-through metadata; materialised children carry `parentUuid`. mm's
structural-fields + extension-data split is unchanged. The walker
plants new materialisations under `mm:modify`, which mm calls back
through `'reload'`; tm's rebuild is reentrancy-guarded, so the trip
does not loop.
