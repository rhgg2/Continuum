# Alias addressing — drop ids, drop paths, use references

A refactor of the alias spec-tree addressing scheme established in
`aliases.md`. Three persisted fields disappear; the materialised
event's link to its spec node becomes a tm-side side table keyed by
uuid. The spec tree is the sole address space; identity is table
identity.

## What goes away

| field | location | today | after |
|---|---|---|---|
| `id` | each spec node | base-36 string, allocated per-root | gone — position in `children` is identity |
| `aliasCtr` | each root event | next-id allocator | gone — `#children + 1` is the next slot |
| `specPath` | each materialised event | dotted base-36 string, set at emit | gone — replaced by `specOf[evt.uuid]` in tm |

The persisted shape per spec node reduces to `{ xform, children }`.
The persisted shape per materialised event reduces to `parentUuid`.

## The side tables

`tm` holds, alongside `aliasIndex`, two maps:

```lua
local specOf      = {}   -- [uuid] = SpecNode (live table within root.aliases)
local nodeMeta    = {}   -- [SpecNode] = { parent = SpecNode|nil, uuid = evtUuid|nil }
```

- `specOf` — given a materialised event, find its spec node.
  `nodeMeta[node].parent` — given a spec node, find its parent
  (nil for top-level spec children: their conceptual parent is the
  root event, addressed by `root.uuid`, not a spec node).
  `nodeMeta[node].uuid` — given a spec node, find the uuid of its
  materialised event (nil if suppressed).

The two maps are inverses across the materialised slice; `parent`
extends the relation upward through the spec tree.

- **Built** during `tm:rebuild`'s walker pass. For each emit:
  ```lua
  um:addNote(emit) or um:addCC(emit)   -- mm stamps emit.uuid back
  specOf[emit.uuid] = e.spec
  nodeMeta[e.spec] = { parent = e.parentSpec, uuid = emit.uuid }
  ```
  Suppressed nodes (collision losers) get a `nodeMeta` entry with
  `uuid = nil` so the parent chain stays walkable even when an
  intermediate alias did not materialise.

  `mm:addNote` already writes the minted uuid onto the caller's table
  (midiManager.lua:766); `addCC` does the equivalent. No mm change
  required for threading.

- **Lifetime.** Both cleared at the head of every `tm:rebuild`;
  repopulated by the walker. Across reload boundaries they are rebuilt
  from scratch, so save/load erases them harmlessly.

- **Keying.** `specOf` by uuid (uuids survive the mm round-trip).
  `nodeMeta` by node table identity (`root.aliases` is mutated in place
  between reloads; identity is preserved within a rebuild cycle).

- **Membership = aliased.** `specOf[evt.uuid]` returns nil for plain
  events. The `evt.parentUuid` flag remains the persisted "this is an
  alias child" marker, but in-memory the side-table lookup is what
  routing consults.

## Upward navigation — `aliasUp` and friends

```lua
function tm:aliasParentEvent(evt)
  local node = specOf[evt.uuid]
  if not node then return nil end
  local parent = nodeMeta[node].parent
  if not parent then                       -- top-level: parent is the root event
    return mm:byUuid(evt.parentUuid)
  end
  local puid = nodeMeta[parent].uuid
  return puid and mm:byUuid(puid) or nil   -- nil if parent suppressed
end
```

A future `aliasDown` (first child) and `aliasNextSibling` follow the
same shape over `node.children` and `nodeMeta[parent].children`
indexing.

## Routing rewrites

```lua
-- tm:routeAliasOp (was: aliases.find(root, evt.specPath))
local node = specOf[evt.uuid]
if not node then return false end
node.xform = aliases.appendOp(node.xform, field, op)
```

```lua
-- tm:severToRoot, tm:severEvents — same substitution
local node = specOf[evt.uuid]
```

`aliases.find`, `aliases.parentOf`, `splitPath`, the dotted-base36
grammar — all delete.

## `tm:aliasIndex` retires; `vm:aliasIdx` reads from `tm.nodeMeta`

Two indices live in the codebase today under similar names:

- `tm:aliasIndex` (trackerManager.lua:113, 1432, 1460) — `byUuid`,
  `byParent` keyed by flat materialisation root. **Already dead.** Its
  only consumer is a shadowed `aliasNav` at trackerView.lua:2045,
  superseded by the spec-tree-aware `aliasNav` at line 2079. Delete
  the whole block (state, builder, accessor, the `--@map:invariant` at
  line 113) and the shadowed function.

- `vm:aliasIdx` (trackerView.lua:142, 2269, 1913) — `byUuid`,
  `byChildren` keyed by spec-tree parent. Records carry visual-grid
  coordinates (`col`, `row`, `chan`, `ppq`) alongside `treeParent`.
  **Survives, but shrinks.** Visual coordinates remain vm's business;
  the spec-tree derivation moves to `tm.nodeMeta`.

The current two-pass build (trackerView.lua:2269–2329) does:

1. Pass-1 — scaffolds `bySpecPath[rootUuid][specPath] = rec`.
2. Pass-2 — strips the last segment of `evt.specPath` to find the
   intermediate parent's record; falls back to `evt.parentUuid` for
   top-level aliases.

Under the new design, treeParent resolves directly:

```lua
local node = tm:specOf(evt.uuid)
if node then
  local pSpec = tm:nodeMeta(node).parent
  if pSpec then
    rec.treeParent = tm:nodeMeta(pSpec).uuid    -- nil if suppressed
  else
    rec.treeParent = evt.parentUuid             -- top-level → root event
  end
end
```

`bySpecPath` and the string parsing delete. The (ppq, chan) sort on
`byChildren` (lines 2324–2329) stays — visual order, not spec-tree
creation order, and vm is the right home for it.

## Cascade-delete (was: prefix-match on specPath)

Replace the string prefix-match at trackerManager.lua:1822 with
set-membership over spec-node tables:

```lua
local subtree = {}
local function collect(node)
  subtree[node] = true
  for _, c in ipairs(node.children) do collect(c) end
end
collect(S)

for _, e in ipairs(events) do
  if subtree[specOf[e.uuid]] then ...
end
```

## Severance ordering

`tm:severEvents` today sorts targets by `depth(specPath)`, deepest
first, so a parent's pluck never invalidates a sibling-grandchild's
path. Under positional spec nodes the same hazard reappears in a
sharper form: plucking sibling index 2 of `[A,B,C,D]` shifts C and D
down by one.

**Resolution.** Resolve every target to a spec-node *reference* up
front, then walk the spec tree bottom-up and pluck by node identity
(scan the parent's `children` for the table, not by index). The
ordering hazard dissolves: plucking by identity is independent of
sibling indices, and a parent-pluck only affects descendants of that
parent (we've already chosen which targets to process).

## Copy/paste — the one place a path is still wanted

`aliasSrcSnapshot` / `resolveAliasSrc` capture the source for a later
paste, possibly across reloads. They cannot store a node reference
(reload swaps `root.aliases` for fresh tables). They store the path.

Under positional addressing this path is an array of integer indices:

```lua
local function pathOf(root, target)
  local function walk(list, acc)
    for i, node in ipairs(list) do
      if node == target then return { table.unpack(acc), i } end
      local r = walk(node.children, { table.unpack(acc), i })
      if r then return r end
    end
  end
  return walk(root.aliases, {})
end
```

At paste time, walk by index. The chain identity check (today: per-
ancestor xform-equality, with `id` as a static anchor) collapses to
xform-equality alone. Behaviour shift: a sever of sibling-1 between
copy and paste makes sibling-2's recorded path point at a different
node — paste silently demotes via the existing nil → silent-demote
branch (`resolveAliasSrc` line 1885 ff.). Documented, accepted.

## What mm sees

mm sees no change. The walker no longer stamps `specPath` onto emits,
so mm's metadata pass-through has one less field to serialise. mm's
existing structural-fields + extension-data split is unchanged. The
"ephemeral fields" mechanism flirted with earlier is **not needed**:
nothing transient ever rides on the materialised event.

## What persists across save/load

- Per root: `aliases = [ { xform, children }, ... ]`.
- Per materialised event: `parentUuid`.

That's it. Loading replays mm's add path; tm's first rebuild after
load sweeps the parentUuid-tagged events, walks each root's spec tree,
re-emits with fresh uuids, and stamps `specOf` along the way. Cold
state and hot state converge at the first rebuild.

## Migration

No legacy data (per `MEMORY.md#project_no_legacy_data`). Old
`id`/`aliasCtr`/`specPath` fields simply stop being written and stop
being read; existing serialised takes are pre-beta and can be wiped.

## Test surface

Adjacent specs in `tests/specs/aliases_*.lua` need the addressing
substitution; behaviour-preserving in every case except the documented
copy/paste shift above.

- `tm:routeAliasOp` — routes when `specOf` is populated; returns false
  when not (plain event, or aliased event whose first rebuild has
  not yet run).
- `tm:severToRoot` — same.
- `tm:deleteSubtree` cascade — set-membership replaces prefix-match;
  add a test exercising a three-level subtree with mixed materialised
  and suppressed nodes.
- `tm:severEvents` batch — pluck-by-identity replaces depth-sort; add
  a regression where two siblings of the same parent are severed in
  one call (today's depth sort happens to handle this; under
  positional with index-sort it would break; under identity it
  works).
- Copy/paste — paste after intervening sibling-sever demotes silently;
  paste after intervening ancestor-xform-edit still raises "mismatch"
  via xform comparison.
- Round-trip — save, reload, rebuild, route. `specOf` is populated
  fresh; routing on a still-aliased event succeeds.

## Out of scope

The touched-set optimisation (Phase 2.5 in aliases.md) is unaffected.
`specOf` is rebuilt incrementally if the walker is incremental;
full-sweep today, incremental later — same code shape either way.
