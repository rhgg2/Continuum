# Group-aware editing — kind-keyed mutation facade

Status: approved plan, ready to implement. Build fresh from this doc.
Targets: `trackerView.lua`, `groupManager.lua`, a new small view-owned
facade module, the row/paste planners later. Line refs are as of this
writing; re-locate by quoted comments if they drift.

## Why

`shiftEvents` (`trackerView.lua:1904`, bound to `eventShiftLeft/Right`)
corrupts mirror groups. Full-stack repro in
`tests/specs/gm_shift_out_spec.lua` (registered in `run.lua`):

- **Synced member shifted out of its region → siblings vanish.** The
  raw `tm:deleteEvent(src)` classifies as a *propagating* group delete;
  `reproject` strips the vuid from every instance.
- **Overridden member shifted out → duplicate.** The delete drops this
  instance's override but leaves the shared group event alive;
  `reproject` re-materialises a fresh concrete at the origin slot, while
  the moved clone lands at the destination. Two notes where there was
  one.
- **Repeated in/out → stacked notes.** The clone keeps `src`'s uuid
  (`util.clone` strips only `token`/`loc`), so `classify` keeps
  unlinking and re-adopting it, desyncing the projection links a little
  more each pass.

## Root cause

The architecture is **editing verbs are group-blind; gm reinterprets
them at the tm flush seam** (`applyEdit`, `groupManager.lua:649`). That
works whenever the low-level op stream *encodes the intent* — an
in-place `assignEvent` reads unambiguously as "edit this slot," so
pitch/vel/delay/etc. propagate correctly today. It fails for a **move**,
which `shiftEvents` expresses as `deleteEvent` + `addEvent` of the same
note across columns (lane/channel can't be assigned — lane is
rebuild-owned, see `moveInstance`'s relane del+add). The seam can't see
the two halves are one note relocating, so it guesses "destroy a member"
+ "create a foreigner," and the override/sibling machinery does the
rest of the damage.

The cure is to stop guessing: let the call site speak *intent*, and
route that intent to whoever owns the event.

## Second goal — gm stops eavesdropping on tm

Routing intent through the facade isn't only a corruption fix; it lets
gm stop *listening* at the flush seam. `applyEdit` is the sole reason gm
subscribes to `preflush` (fired at `trackerManager.lua:535` on the
*staged* op buffers — before the commit and the pre-clip collision scan,
not after them). So the seam never reacted to committed geometry; it
inferred intent from the *shape* of staged ops. The facade delivers that
intent named, which removes the inference — and the subscription with it.

The whole self-echo defense exists only to keep that sniffer safe from
gm's own staged writes re-entering it:

- `propagating` (set around `newInstance`/`moveInstance`/`reproject`,
  gated at the preflush guard) — reentrancy guard;
- `selfStaged` — newInstance's projection adds, skipped in the adds loop;
- `selfAssigned` — moveInstance's re-place echo, skipped in the assigns
  loop.

All three guard one consumer. Once every edit arrives through an explicit
verb that flushes itself under `propagating`, gm no longer needs the
subscription — drop it and the apparatus goes with it. This is the
terminal goal of stages 3–4, not incidental tidy-up.

Loose end: the `reproject` drain (`touchedGroups`/`pendingReproject`,
`groupManager.lua:753`) lives inside the preflush handler. When the
handler dies it needs a new home — folded into the verbs or a thin
commit hook. (The collision scan already issues its fixups *after*
preflush fires, so gm never saw collision nudges; that's pre-existing,
not introduced here.)

## The model

### Kind-keyed facade (leaf dispatch)

A view-owned facade exposes the leaf editing verbs and routes each by
the event's **backing**, not by op-stream inference:

- gm owns this uuid (`gm:stateOf`/`locByUuid`) → gm's member API
- stash-backed generated fx event → the stash (future; not built — fx
  cells are display-only today)
- else → tm directly

```
-- kind-keyed; one cell/event at a time. Dispatch by backing.
facade.setValue(evt, update)   -- value edit on an existing event
facade.move(evt, dest)         -- relocate an existing event to a column/row
facade.delete(evt)             -- remove an existing event
facade.create(spec)            -- new event at a cell (dispatch by POSITION)
```

`setValue`/`move`/`delete` dispatch on the event's owner. `create`
dispatches on **position** — does the cell fall in a region? →
`gm:createMember`; in a stash region → stash; else `tm:addEvent`.

This is **leaf dispatch only**. It knows nothing about bulk semantics,
selections, or time topology — those live above it (see Bulk planners).
Every leaf op targets exactly one pattern slot, so it is always
injective (see Injectivity) and never trips the group hazards.

Realisation note: kind-keyed **facade**, not callbacks bound onto cells.
Cells are rebuilt every window (gm re-anchors by uuid each rebuild);
binding closures per cell would re-close on every rebuild and add a
staleness surface. The facade is a lookup keyed by the event's backing,
which gm already knows by uuid.

### gm grows an explicit member API

`applyEdit`'s intent-guessing (classify/classifyCreate/onOv branches)
is replaced — eventually retired — by an explicit front door, mirroring
the structural ops gm already exposes (`moveInstance`, `resizeGroup`,
`newInstance`). The replay machinery (`reproject`/`reconcile`, the
override-transition table, `touchedUuids`, `userOwned`) stays exactly as
is; it just gets called through clear methods instead of reverse-
engineered from the op stream. Each verb makes the override-transition
decision *with the operation known*, which makes that intricate table
(add-ov+delete, assign-ov+amend, …) read per-verb instead of as one
inference blob.

```
gm:addEvent(evt)                 -- create in a region (was: classifyCreate)
gm:assignEvent(uuid, update)     -- value edit  (was: applyEdit assign branch)
gm:deleteEvent(uuid)             -- delete      (was: applyEdit delete branch)
gm:footprintAliases(cells)       -- injectivity predicate (see Injectivity)
-- a move is NOT a verb: the facade composes delete[srcKind] + add[destKind]
```

These stage through tm under `propagating = true` and flush themselves,
exactly like `moveInstance` — so their ops never re-enter `applyEdit`.

## Decisions (settled)

1. **Move edits the shared pattern (option B).** A sideways shift of a
   group member is a pattern edit. In-region → move the pattern slot,
   propagating to every instance. Out-of-region → the member leaves the
   pattern (siblings lose it) and the acting instance keeps a standalone
   note at the destination. An *overridden* member follows the existing
   on-ov-local rule: the move stays local to this instance.

2. **Creates auto-join; `localMode` is the opt-out.** A created or
   pasted event landing inside a region is adopted into the group and
   propagates (global mode), consistent with how *typing* a note already
   behaves (`classifyCreate`). To place content without propagating, turn
   on `localMode` — the edit becomes a per-instance override. No
   per-op special-casing.

3. **Injectivity is the bulk-edit invariant.** A positional edit in
   propagating mode is well-defined only if its footprint maps onto
   pattern slots **one-to-one** — each touched slot written at most once.
   Two ways to break it:
   - **time bisect** — the cut slices a fraction of one instance's
     timeline (insert/delete-row);
   - **aliasing** — the footprint covers ≥2 instances of the *same*
     group, so each shared slot is addressed once per instance.

   Whether a non-injective op corrupts depends on its class:
   - **idempotent / content-uniform** (delete, set-to-constant) —
     double application agrees; safe.
   - **relative / content-varying** (transpose+Δ, nudge-by-Δ, paste) —
     compounds (transpose lands +2Δ on the aliased slot) or contradicts
     (paste writes two values); unsafe.

   Resolution: **in propagating mode, refuse a relative/content-varying
   edit whose footprint is non-injective** (no-op + surface, the
   off-grid-edge precedent). `localMode` dissolves it — instances stop
   aliasing one pattern, so different content per instance is legal.

4. **Time-topology ops treat instances as atomic blocks.** `insertRow`/
   `deleteRow` (and a ripple/insert-paste variant, if one exists):
   an instance wholly at/after the cut re-anchors as a rigid unit
   (`moveInstance`); a cut strictly inside an instance is refused
   ("add/remove a row in the macro" is a region resize, done in region
   mode). They never reach inside a pattern.

5. **Plain (overwrite) paste is not a time-topology op.** It is
   slot-for-slot clear+write, so it decomposes into leaf ops: clear the
   destination (per-slot deletes) then write (per-slot creates,
   auto-joining per decision 2). It needs *no* atomicity guard — only
   the injectivity guard (decision 3), to refuse a paste covering ≥2
   instances of one group in global mode.

## Move semantics — delete + add, not a primitive — the heart of stage 1

A move is not a gm verb. The facade composes it: `delete[srcKind]` at the
source + `add[destKind]` at the destination, each dispatched on the cell's
positional kind tag; `relocateDrop[srcKind]` decides the moved copy's
identity. Given a member `uuid` and a `dest` (absolute chan + type +
lane/cc, same row/ppq the caller computed):

- **dest outside any region** (`destKind = plain`): the member leaves.
  - synced, global → `gm:deleteEvent` drops `group.events[vuid]`
    (propagating delete to siblings, absorbing a sibling override first);
    `add` materialises a standalone at `dest` with a FRESH identity
    (`relocateDrop.member` sheds uuid — reusing it lets `reproject`'s del
    of the vanished member kill the standalone).
  - overridden / localMode → `gm:deleteEvent` drops this instance's
    override only; the fresh standalone lands here, siblings untouched.
- **dest inside a region** (`destKind = member`): auto-join via
  `gm:addEvent` (decision 2). classifyCreate finds the covering region;
  global adopts the moved event into that group's shared pattern (every
  instance gains it), localMode keeps it a per-instance add. The same arm
  serves a dest in the *source's own* group (within-pattern / cross-
  instance move) and in *another* group — the destination position alone
  decides, so no per-case branching. Covered by `gm_shift_in_spec`
  (into a group, group→group, instance→instance), all global.

The caller (`shiftEvents`) stops its own grouped `del+add`: it dispatches
`delete[srcKind]` + `add[destKind]` per cell. Single-event shift (the
reported bug) is always injective and needs no guard.

## Injectivity predicate (gm:footprintAliases)

```
-- cells: the absolute (chan, streamId, ppq-span) footprint of a bulk op.
-- Returns true if the footprint maps any group pattern slot more than
-- once (≥2 instances of one group covering the same slot). Caller refuses
-- a relative/content-varying op in propagating mode when true.
gm:footprintAliases(cells) -> bool
```

Settled: shipped **precise** (slot-level). It was not fiddly -- the
group-frame slot identity (`toGroup` + `laneId`, the `sameSlot` triple)
gives an exact per-cell key, so the disjoint-halves case (top half of I1
+ bottom half of I2) maps to distinct slots and stays legal. No
over-refusal; no conservative fallback shipped.

## Layering

- **Leaf dispatch (facade)** — one cell → tm/gm/stash. Always injective.
- **Bulk planners** (above the facade) — `insertRow`/`deleteRow`,
  `paste`, block transpose/nudge. They consult gm geometry
  (`eachInstance`, `footprintAliases`), classify instances as
  contained / missed / bisected, decide refuse vs whole-instance
  move/delete, then emit leaf ops + instance ops. Plain paste needs no
  planner beyond a clear+write loop + the injectivity gate; only the row
  ops need the atomic-block planner.

## Stages (each lands green; nag to commit between)

1. **Facade skeleton (`delete`/`add` kind dispatch) + `gm:deleteEvent` +
   route `shiftEvents`.** Single-cell move = `delete[srcKind]` +
   `add[destKind]`; out-of-region and in-region both done (the `add`
   `member` arm is `gm:addEvent`). Convert `gm_shift_out_spec` from a characterisation
   harness into red→green assertions (synced + overridden, member leaves).
   **This fixes the reported bug.** `applyEdit` still serves value/
   create/delete in this stage — transitional two-path state is fine.
   *Done, including the auto-join arm: moves into a group, between groups,
   and between instances are covered (global).*
2. **Injectivity predicate + block-move guard.** `gm:footprintAliases`;
   refuse a non-injective block shift in global mode. New spec: block
   shift spanning two instances of one group.
   *Done: shipped **precise** (per-cell, slot-keyed) -- not conservative.
   Predicate maps each footprint cell to its group slot via
   `classifyCreate` + `toGroup` + `laneId` (the `sameSlot` triple); two
   cells on one slot => alias. Guard in `shiftEvents`, gated on `gm` and
   `not localMode`. Spec `gm_block_shift_alias_spec`: aliasing-refused +
   disjoint-allowed (the latter pins precision against a conservative
   regression).*
3. **Migrate value edits.** Route `setValue` through the facade →
   `gm:setMemberValue`; retire `applyEdit`'s assign classification.
4. **Migrate create/delete, then drop gm's preflush subscription.**
   `createMember`/`deleteMember`; retire the `applyEdit` seam sniffer
   entirely, then unsubscribe gm from `preflush` and delete the
   self-echo apparatus (`selfStaged`/`selfAssigned`/the `propagating`
   reentrancy guard) — see "Second goal" above. Relocate the `reproject`
   drain out of the dead handler. `reproject`/`reconcile` and the
   override-transition logic remain, now behind the explicit verbs.
5. **Time-topology atomicity.** `insertRow`/`deleteRow` planner:
   whole-instance re-anchor at/after the cut; refuse mid-instance.
6. **Paste through the facade.** Clear+write leaf loop + injectivity
   gate + auto-join. Ripple/insert-paste (if it exists) under stage-5
   atomicity.

**Stash arm** is deferred until fx events become mutable (note-macros
v2 made them displayable, not editable). When that lands it is a single
arm on the facade + a stash write path — not a fourth mechanism.

## Open decisions (settle as the stage arrives)

- ~~Injectivity precise vs conservative~~ -- settled: shipped precise (above).
- Move-out landing in another region: adopt (decision 2) vs leave
  standalone. Lean adopt for consistency; confirm with a stage-1 test.
- Row-op refusal granularity: refuse the whole op, or just the
  bisected column/instance, when a multi-column op straddles one
  instance.
- **`localMode` affordance (UI, out of scope here but flag it):** mode
  now silently decides whether a paste/create rewrites the macro
  everywhere or only here. A quiet indicator + a surprised user = a
  destroyed macro. The indicator must be unmistakable.

## Ground rules

- Repo style (CLAUDE.md): closures-over-state, `local fn do … end`
  scoping, `----- Name` banners, comments for WHY only (≤2 lines
  inline), no OO conventions. `.map` files regenerate via the post-edit
  hook — never hand-edit.
- Annotation/doc caps and the contract/`--KIND:`/doc boundary:
  `docs/CONVENTIONS.md`. The WHY for this work belongs in
  `docs/groupManager.md` (the replay model) with one-line pointers at
  the code; this design doc is the plan, not the eventual prose.
- Specs exercise **real** wiring: full-stack `harness.mk{ groups=true }`
  (`tests/harness.lua`) — real tm/mm/gm/tv, fake REAPER only. Bugfix
  specs red-first. Verify each stage with
  `mcp__readium_tests__lua_test_run` + full suite green.
- Key source anchors: `shiftEvents` (`trackerView.lua:1904`),
  `applyEdit` (`groupManager.lua:649`), `reproject`
  (`groupManager.lua:573`), `moveInstance` (`groupManager.lua:828`),
  `classify`/`classifyCreate` (`groupManager.lua:289`/`370`). Model
  prose: `docs/groupManager.md`.
```
