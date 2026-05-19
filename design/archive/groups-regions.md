# Plan — Groups feature, Regions UI

Status: approved, pre-implementation. Self-contained for resume after compaction.

## Vocabulary (settled)

- **Groups** — the abstract feature/engine. A group owns a shared region
  rect + group-frame events and has **instances** (concrete placements).
- **Regions** — the editCursor-owned modal selection UI for authoring
  groups. Dungeon's `region*` names port verbatim.

"mirror" is retired as a user/code noun.

## Why

`mirrorScope` authoring lived page-local in `trackerPage` (forward-declared
`mirrorMode`/`mirrorRect`/`mirrorSrc`, `exitMirror`, `mirrorPaint`, the
`MIRROR_KEEP`/`DUP_KEEP` sweeps) with **no render of the in-progress rect
and no mode signal** — so Super-R either no-ops (no selection) or enters an
invisible modal. `dungeon/integrations/editCursor.lua:290-786` is a
complete, clean ec-owned region mode; Continuum's live `editCursor` is that
file minus region mode. Porting it (rewired to the group engine) puts the
logic in its correct home and structurally fixes the no-feedback bug:
a live per-frame render + `ec:isInRegionMode()` affordance.

mirm stays the single store/projection/persistence/conform engine; ec owns
only the mode + the ephemeral authoring cursor; tv stays the logical↔grid
bridge.

## Commit 0 — pure rename (lands first, suite stays green, no behaviour)

| from | to |
|---|---|
| `mirrorManager.lua` | `groupManager.lua` |
| `mirror.lua` (pure core) | `groups.lua` |
| `mirm` (instance var) | `gm` |
| `docs/mirrorManager.md` | `docs/groupManager.md` |
| `docs/mirror.md` (if any) | `docs/groups.md` |
| cm take key `mirrorGroups` | `groups` (no migration — pre-beta, no legacy data) |
| `tests/specs/mirm_*` | `tests/specs/gm_*` (+ update `tests/run.lua`) |
| `mirror.project/resolve/...` refs | `groups.project/...` |

`.map` files regenerate via the post-edit hook — never hand-edit. Update
the two memory entries naming "mirm"/"mirror replay" after the rename.
trackerPage `mirror*` page-local symbols are deleted in Commit 2 (not
renamed here) — leave them as-is through Commit 0.

## Commit 1 — `groupManager` grows three public verbs

Built on existing private `reproject(groupId)` @608, `regionConflict(rect,
anchor)` @444 (returns colliding groupId | nil), `persist()` @235.
Shapes (unchanged): `group = { rect, events={[vuid]=groupEvt}, nextVuid,
instances={[instId]=instance} }`; `instance = { anchor={ppq,chan}, assigns,
adds, deletes }`.

```
gm:deleteInstance(groupId, instId) -> true | nil, reason
```
Stage `tm:deleteEvent` for every projected uuid of that instance, drop
`group.instances[instId]`, clear its `proj`/`locByUuid` slots, `persist()`.
**Confirmed:** if it was the group's last instance, also remove the group
from `groups`, `clearActive` if it pointed there, `persist()`. Unknown
id → `nil, reason`.

```
gm:moveInstance(groupId, instId, anchor) -> true | nil, reason
```
Re-anchor an existing instance. Disjoint gate: reuse the same check
`newInstance` applies, treating the instance as freshly placed at `anchor`
while **excluding its own current cells** (so it doesn't self-collide).
Verify `regionConflict` semantics at implement time — it is cross-group;
sibling-instance overlap within the same group must also be rejected.
On pass: `instance.anchor = anchor`, `reproject(groupId)`, `persist()`.

```
gm:resizeGroup(groupId, { ppq?, dur?, streams? }) -> true | nil, reason
```
Mutate the **shared** `rect` (changes membership for *every* instance):
`ppq` moves the start edge, `dur` the end edge, `streams` the per-channel
stream-set (extend/shrink). Validate every instance's resulting placement
stays disjoint from other groups; reject whole op if any fails.
On pass: mutate rect, `reproject(groupId)`, `persist()`.

Specs (red-first), `gm_*`: deleteInstance incl. last-instance→group-drop;
moveInstance disjoint-rejection + self-exclusion; resizeGroup all three
edges + per-instance disjoint rejection.

## Commit 2 — `editCursor` region mode (port + rewire) & `trackerView`

Port `dungeon editCursor:290-786` with the **regionData store removed**.
ec holds only an ephemeral authoring cursor:

```
regionCursor = { groupId, instId } | nil   -- UI nav state, NOT persisted
```

New ec dep (single bundle, **D-1 confirmed**):

```
groupBridge = { eventsInRect, cursorAnchor, instanceSelection, gm }
```

`trackerView` builds `gm`, builds `groupBridge`, injects it into `ec` at
instantiate. Verify current gm construction site at implement time
(mirm_* specs build it with `{tm,cm}`; production site is tv or
trackerPage). ec must never reach tm — all event resolution via the bridge.

New `tv:instanceSelection(groupId, instId)` — public wrapper over the
existing private `selectRegionAt`/`colsForAnchor`: instance anchor + group
rect → installed grid selection.

ec region-mode surface (verb → engine), the seven requirements:

| Req | ec verb | delegates to |
|---|---|---|
| 5 new group via first instance | `regionNew` | `gm:mark(eventsInRect(selRect), selRect)` |
| 4 new instance of active group | `regionInstance` | `gm:newInstance(groupId, cursorAnchor)` |
| 1 select an instance | `regionCommit` | `tv:instanceSelection`, then exit |
| 2 move instance | `regionNudgeBack/Forward` | `gm:moveInstance` (anchor ± row) |
| 3 delete instance | `regionDrop` | `gm:deleteInstance`, advance cursor |
| 6 resize group scope | `regionGrow/Shrink`, start-edge verb, paint | `gm:resizeGroup({dur/ppq/streams})` |
| 7 navigate groups/instances | `regionNext/Prev` | iterate `gm:eachInstance()`, set cursor, snap caret |

`ec:enterRegionMode` (push `region` scope; seed `regionCursor` if caret
inside an instance), `exitMode` (pop; clear cursor — group empty-sweep is
now `gm:deleteInstance`'s job, not ec's), `ec:isInRegionMode`,
`ec:paintRegionCell(row, colKey, 'extend'|'shrink')` → `gm:resizeGroup`
stream-set + span. Modal `region` scope + `REGION_PASSTHROUGH` (nav verbs
fall through) ported verbatim. Verbs named distinctly from tracker twins.

`trackerPage` shrinks to dungeon's integration shape:
- delete page-local `mirrorMode`/`mirrorRect`/`mirrorSrc`/`mirrorScope`/
  `exitMirror`/`mirrorPaint` and the `MIRROR_KEEP` sweep;
- `tracker:register('regionEnter', ec:enterRegionMode)` + bind the chord;
- region render pass: gate the active-outline/gutter on
  `ec:isInRegionMode()`; add an authoring-rect overlay for the active
  group's rect at the cursor (the missing feedback);
- paint via `ec:paintRegionCell`.

**Explicitly out of scope this pass** (do not delete): `mirrorMark`,
`mirrorPaste`, `mirrorDuplicate` cascade, `mirrorLocalToggle` on the
tracker scope — these are working quick-verbs / the duplicate-cascade
feature (memory: project_duplicate_cascade). A later consolidation pass
may fold `mirrorMark`→`regionNew` etc.; flag, don't silently remove.

Specs: ec region-mode spec modelled on `dungeon/tests/ec_regions_spec.lua`
— real `cmgr` scope + real `gm` (fake tm/cm, as gm_* specs do); drives
through the modal stack, never a hand-fake of the verb body (memory:
no-test-shaped-prod). Extend `gm_render_spec` for the ec accessor.

## Commit slicing

0. rename (green, no behaviour) → commit.
1. gm three verbs + gm_* specs → commit.
2. ec region mode + tv selector + trackerPage shrink + specs → commit
   (or split tv/ec from trackerPage if the diff is large).

## Open verifications at implement time

- gm production construction site & instantiation order vs ec.
- `regionConflict` exact semantics for moveInstance self-exclusion and
  same-group sibling overlap.
- start-edge resize UI (key/gesture) — "UI to be decided" per user.
