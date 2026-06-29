# groupManager

A group is a region; an instance is one concrete placement of it. Every
instance's events are a *pure replay* of the shared group pattern plus
that instance's own overrides — recomputed from scratch on every flush,
never diffed forward. gm wraps the pure `groups` core with the anchor
maths between the group frame and the instance frame, and rides tm's
flush seam.

## Why replay, not diff

The model exists to kill one bug. A length-4 group ABCD; in instance Y
locally delete C; switch to group mode and edit B. The duration written
to the *template* was computed against Y's distorted geometry (B grown
over the C-shaped hole, to D) instead of pristine ABCD (B clipped to
C's onset). The edit travelled through a realising instance and the
realisation leaked into the shared identity. A diff-forward design
can't fix this: once a distorted value is stored it propagates. Replay
can — the group holds canonical geometry, every instance is re-derived
from it each flush, so one bad projection can never become the source
of truth.

Three mechanisms enforce that:

- **Intent into the group frame.** A tracker edit on a concrete
  instance event is transferred into the group frame through the
  instance anchor as pure *intent* — onset, and the ceiling (a finite
  `endppqL` → group `dur`, or `endppqL == util.OPEN` → nil dur). The
  realised note-off tm re-derives never enters the frame.
  `group.events` only ever holds the canonical pattern.
- **Per-flush re-derivation.** `groups.project` clones the group and
  replays the instance's deletes/adds/assigns, resolving geometry from
  scratch. A terminal set, order-independent — not an incremental patch.
- **Origin round-trip.** `reproject` re-drives *every* instance's
  concrete event from the pristine projection, the user-touched one
  included. Skipping the user's own event ("its geometry is the user's
  own") was exactly how the distorted value survived; that skip is
  gone.

`userOwned` survives only where re-driving would duplicate work the
user's edit already staged in tm — a create reuses its own event as the
projection carrier, a delete needs no second `tm:deleteEvent`. It no
longer suppresses the `set` writeback. It is keyed per concrete event,
not per instance: per-instance gating once flagged both sides "origin"
when two notes were edited in one flush through different instances and
suppressed both writebacks, so neither edit reached the other.

## Intent in, realisation out

gm carries *intent* across the seam and nothing else. A note's intent
is its ceiling: a finite authored `endppqL`, anchor-rebased to a group
`dur`; or `endppqL == util.OPEN` — a freshly-placed note with no
ceiling, which travels as a nil group dur. `toGroup`/`toInstance`
rebase between frames; `updToGroup`/`updToInstance` are the exact
partial-update inverses (`util.OPEN` ⇒ `dur` removed, a finite `dur` ⇒
`endppqL` restamped). The realised note-off never enters the group
frame.

The onset is logical the same way the ceiling is. The group frame is
the authoring grid; a concrete's `ppq` is realised — swing and the
note's `delay` baked in by tm's `realiseNoteUpdate`. So onsets cross on
`ppqL`, never `ppq`: `toGroup` rebases off `evt.ppqL`, and `updToGroup`
moves the group onset only when the update carries `ppqL` (the explicit
"logical onset moved" stamp tm sets). A pure `delay` edit leaves `ppq`
raw with no `ppqL` — it must move no group onset; `delay` rides across
as its own scalar via `copyScalars`. The two coincide only under
identity swing with zero delay, which is why a `delay` edit was the
first to expose the leak: the offset entered the shared template and
every sibling reproject re-realised it a second time, pushing the
copies off-grid.

Realisation is tm's, universally. tm's tail pass re-derives *every*
note's raw note-off each rebuild, clipping it to whatever physically
follows in the same lane — and because it walks all of `mm:notes()`,
that "whatever follows" is cross-instance for free. An earlier design
carried a per-instance `conform` marker and replayed legato inside the
group frame so the last-in-lane note's tail could be clipped across
instances; the universal pass subsumes both. There is no `conform`
field, no group-frame legato, no conform-tail rebuild pass.
`groups.project` never clips or grows a `dur` (its contract): a blocker
delete regrows the realised tail back up to the surviving `endppqL`
ceiling, never merely to the old clip.

## Lane identity is per channel

The region is per-channel — `rect.streams` is keyed `[chanOffset][streamId]`,
so `streamId` there is correctly channel-free; the offset is its own
dimension. But geometry *inside* the group frame — `groups.project`'s
slot-dedup and `groups.laneId` — resolves per lane, and a lane lives in
one channel. Keying those by `streamId` alone
(`evType:key`) collapsed two channels at the same lane and onset into one
slot: the lower-vuid (leftmost) note claimed it, the other was conflicted
out of `desired` and never projected, so only the leftmost channel of a
multi-channel group mirrored. `groups.laneId` (`chanDelta` + `streamId`) is
the group-frame lane identity those passes key by; `streamId` stays the
channel-free region-membership key — `evType:key`, never a column
position, because inserting a cc reindexes neighbouring columns, so an
index-based region would not survive a column insert or reorder.

## Regions are disjoint

Two groups whose footprints overlap have no defined behaviour, so
`markGroup` and `newInstance` reject a placement that collides with a
live instance and the op becomes a silent no-op (the existing
out-of-range precedent). Two failures motivate the bar. A freshly
typed event with no prior identity is adopted by `classifyCreate`,
which walks `pairs(groups)` and takes the first containing region — so
in an overlap *which* group claims the note, and therefore which
siblings it mirrors into, is unspecified and can change between
rebuilds. And `groups.project`'s slot-dedup resolves within one group;
two overlapping instances each project a note-on into the same slot
with no cross-group dedup — the cross-identity leak the replay model
exists to kill, reappearing across groups where replay cannot see it.

"Footprint" is per `(channel, streamId, time)`: the half-open span
`[anchor.ppq, anchor.ppq + rect.dur)` against the absolute
`(anchor.chan + chanOffset, streamId)` cells of `rect.streams`. Same
bars on a different lane or channel do not collide, and an adjacent
stack (`next = ppq + dur`, the cascade's normal step) does not either —
the span test is strict.

## The flush seam

`reproject` runs *inside* tm's `preflush`, re-entrantly, so it must not
call tv (tv's edit verbs assume cursor/grid/audition and themselves
call `tm:flush`). It stages through tm and lets the in-flight flush
carry the ops. `propagating` guards gm's own staged adds from
re-entering `applyEdit` as user edits; `selfStaged` does the same for
newInstance's projection adds, which commit on a later flush.

`reconcile` compares `desired` against the projection *shadow*
(`rec.groupEvt`, what reproject last wrote), not the live concrete —
cheap, and the two agree as long as only gm drives concretes. But tv
is group-unaware: a user edit mutates a projected concrete's intent
(`ppq` / `endppqL`, including `util.OPEN`) in place, with no
group-geometry change,
so the shadow still equals `desired`, reconcile emits nothing, and the
edit never reaches the siblings. So before reconcile, `reproject`
refreshes the shadow from the live concrete (`toGroup(rec.evt)`) for
every record whose concrete the user touched this flush
(`touchedUuids`). Scoped there because only a user edit can mutate a
concrete behind reproject's back; gm's own staged adds never enter
`touchedUuids`, so the steady-state shadow path is untouched. This is
the same cross-identity leak the replay model exists to kill, at the
one seam where reconcile's optimisation let it back in.

`uuid` is gm's only durable identity. tm swaps every event table on
rebuild, so the runtime projection is re-anchored by uuid each window;
only the vuid→uuid slice persists, rebuilt by `rehydrate` on a
take-changed rebuild.

## Instance lifecycle & region resize

`reconcile` is drift-driven and the group frame is anchor-invariant, so
a pure re-anchor produces *zero* drift: `reproject` would compare an
unchanged shadow against an unchanged `desired` and emit nothing.
`moveInstance` therefore cannot delegate the move to the seam — it
reconciles the instance's concretes against the *desired* projection at
the new anchor itself, mapping each through the group→instance dual.
Placing concretes directly also makes it own the take-edge call the seam
would otherwise make: through `onTake` it withholds a member the move
pushes off the take end (deleted + unlinked) and revives it (re-added)
when a later move brings it back on. Only the bottom edge can hang — the
caller clamps the anchor so the top stays on-take, mirroring the absent
start-edge trim. That staged assign echoes
back through `preflush` like any gm-driven write; for a synced instance
it is neutral, but on an override instance the echo would re-enter
`applyEdit` and accrete a base-valued sticky `assign` that later pins
the instance. So move-echoes carry their own `selfAssigned` marker. It
is deliberately *not* `selfStaged`: the `preflush` assigns loop runs
before the adds loop, so one shared set would let the assigns pass
drain a pending `newInstance` add-echo (whose add then misclassifies as
a user create) and vice versa. One marker per loop, each drained only
by its own.

The move is *previewed* before it is sealed, on three axes. A row nudge
accumulates `regionCursor.moveDelta`; a sideways shift
(`eventShiftLeft/Right`) accumulates `regionCursor.chanDelta` and/or
`regionCursor.laneDelta`. All only slide the caret — gm and tm stay
untouched. The sideways dispatch mirrors `shiftEvents`' note-vs-other
split: a multi-channel or has-CC instance **channel-moves** (lane
preserved, clamped so every member channel stays in 1..16, no "hang off"
sideways); a single-channel all-notes instance **walks lane-by-lane**
within the channel and, at the lane boundary, spills the whole block into
the adjacent channel's edge lane — `shiftEvents`' note wrap, lifted to the
instance.

Channel and lane decompose differently, and must. Channel is a
per-instance *base* (`anchor.chan + chanDelta`); lane is a per-instance
*offset* (`anchor.laneDelta`, default 0) layered over the absolute `key`,
because `key` doubles as the stream identity `rect.streams` is keyed by —
it cannot move without breaking membership. Lane is also rebuild-owned
(`assignNote` rejects a relane), so `moveInstance` realises a lane change
by **del+add**, not assign; `pickStampedLane` then honours the authored
lane verbatim and materialises the column if missing, so the move holds
through rebuild and a member never renders invisible. Conflict stays
lane-accurate by shifting each instance's `streams` keys through
`groups.shiftStream(sid, laneDelta)` — the lane analogue of applying
`anchor.chan` to `chanOffset`.

`trackerRender` reads `tv:movePreview` to draw the armed instance shifted
by all three deltas — its cells ghosted at the destination columns
(sourced through `destSrc`, matched on the group-frame
`(chanOffset, streamId)`), the source footprint and the foreign cells
under it suppressed render-only, so sweeping back restores them for free.
`sealMove` runs the real `clearMoveGap → moveInstance → flush` once, on
mode exit or before any structural verb, so a pending preview never leaks
onto another instance.

A region resize moves the boundary, never the music. Trimming the
start edge re-origins — every anchor shifts by `startDelta`, every
group event counter-shifts — so realised positions are invariant
(`(anchor+Δ) + (g−Δ)`) and siblings do not visually jump. The rejected
alternative, dragging content with the edge (DAW clip-slip), is wrong
here precisely because a group's instances would lurch under a resize
none of them authored. Because the re-origin *is* group-frame drift,
`reproject` then does the concrete work for free as ordinary `set`s.

A member the shrunk rect no longer covers **leaves** the group: it is
dropped from `group.events` and unlinked from every instance *before*
`reproject`, so reconcile sees it in neither `desired` nor `current`
and emits no `del`. Its concrete is untouched — it persists as an
ordinary, unmanaged event. The region defines membership, not
existence; deleting on shrink would be a destructive surprise. Symmetrically,
events an *expanded* rect now covers are absorbed — but gm has no
tm-enumeration surface (the dropped-hose decision), so they arrive from
the acting instance via the caller, folded at that instance's anchor,
the same events-passed idiom as `markGroup`.

Take and region bounds, and clearing the destination, are the caller's
(tv/ec). gm validates only group-domain invariants — channel range and
cross-group disjointness, the moving instance excluded from its own
collision. `takeLen` stays advisory; gm holds no take authority, as
`newInstance` already established.

## localMode

A single global UI flag, not per-instance. Off (default), an edit
mutates the shared group and propagates to every sibling. On, the edit
is a per-instance sticky `assign`/`add`/`delete` and never touches
`group.events`, so no sibling's projection sees it. The origin's own
event is still round-tripped from its locally-augmented projection —
that is realisation, not propagation; containment means the *shared*
group and *other* instances stay untouched.

A locally deleted event still lives in `group.events`; the delete only
shadows it for this instance. So a global-mode create on that slot is
not a new event — `classifyCreate` would otherwise allocate a fresh
vuid coincident with the still-alive original, which `groups.project`'s
slot-dedup then silently collapses, losing one. Instead `revivableVuid`
matches the typed event against the instance's `deletes` by stream +
onset; on a hit the create clears `instance.deletes[vuid]` and
overwrites that existing group vuid in place — "type over deleted
clears the delete". This is the delete-ov case of the override
transitions below.

## Override transitions

One principle governs every override: *a local override pins this
instance's visible event at that slot; a group-event existence flip
never silently breaks the pin.* It splits by whose action it is.

**Same-instance, global mode — "on-ov ⇒ local".** Once an instance
carries its own override at a vuid, a further edit there stays local
and never propagates. In `localMode` that is the definition; in global
mode it holds *because the override is a declared intent to differ* —
re-touching it must not silently re-merge you into the group, and the
way to rejoin is to clear the override, not to have an unrelated edit
clear it for you. So global mode means "propagate **except** on cells
this instance has locally diverged." The table (acting instance, the
slot carries its override):

- add-ov + amend → edit the add in place (no propagation).
- add-ov + delete → the local add is just gone. (`deletes[vuid]=true`
  would not work: `project`'s adds pass ignores `deletes`.)
- assign-ov + amend → accrue the assign locally; `group.events`
  untouched, no sibling sees it.
- assign-ov + delete → drop the assign, the cell rejoins the shared
  group value. The user's keystroke already removed this instance's
  concrete, but the group event survives, so the projection link still
  reads vuid-alive and `reconcile` would emit `set` against the dead
  event; the branch must `unlink` so it emits `add` and the group note
  re-materialises here. (A second delete then does the propagating
  group delete — you cannot one-keystroke-destroy a shared event from
  a diverged instance.)
- delete-ov + amend (type) → `revivableVuid` (above).
- delete-ov + delete → no-op. Unreachable by construction — a hidden
  slot has no concrete event to delete — but the guard is load-bearing:
  without it the bare global-delete branch would fire a *propagating
  group delete from a cell invisible in this instance*.

`localAmend` is the shared amend body; `onOv` gates the acting
instance onto this path before the global branches.

**Cross-instance — `absorbSiblingOverrides`.** When the acting
instance's global create/delete flips whether a shared event exists at
a slot, a *sibling* carrying its own override there must keep its
visible event:

- sibling add-ov + a peer global **create** at that slot → the add-ov
  *upgrades* to an assign-ov on the now-real vuid (its fields become
  the per-field delta from the new group event). Runs after the create
  is linked into `group.events`, so the delta is taken against the
  committed group event.
- sibling assign-ov + a peer global **delete** of that event →
  *demote* to a materialised add-ov: `groups.resolve(groupEvt,
  assign)` snapshots group-base + delta *before* the group event is
  cleared (an assign delta is meaningless without its base). A sibling
  that locally hides the slot has no visible event — skipped.

Neither sweep unlinks the stale concrete; the touched group reprojects
and `reconcile` deletes the now-absent vuid and adds the new one. The
acting instance is the on-ov-local path's job and is skipped here, so
the two mechanisms never double-handle a slot.

## DERIVED opt-out

`copyScalars` carries the full event payload across the group/instance
frame boundary, minus the keys in `DERIVED`. The list is opt-out, not
opt-in: an allowlist would silently drop every unlisted key (the
rpb-drop bug). Three categories of denied key:

- **positional/identity** — the four duals (`ppq`/`ppqL`, `endppq`/`endppqL`)
  translate explicitly between frames; copying them raw would
  double-write or leak realised time.
- **regenerated** — `tm` re-derives these every rebuild; they must
  never persist into the shared group template.
- **absorber synth** — `derived`/`hidden` pbs are re-seated from note
  onsets each rebuild; carrying them into the group frame would corrupt
  the template with ephemeral realisation state.

## `conflicted` is not UI-reachable

`groups.project`'s slot-dedup marks the loser at a colliding
`(chanDelta, streamId, ppq)` slot `conflicted`. No UI gesture
constructs that collision. A group event projects into *every*
instance, so the first create's concrete pre-occupies that cell
everywhere; a second edit there classifies to the existing uuid (an
on-ov/assign), never a fresh `classifyCreate`. If the instance locally
deleted the event so the cell *is* empty, `revivableVuid` revives the
shadowed vuid in place rather than allocating a coincident second one.
Two distinct group vuids at one slot therefore only arise off the UI
path — a hand-edited or corrupt persisted blob, `rehydrate` after an
external take mutation, a future programmatic API. `conflicted` is the
defensive guarantee that `project` stays a deterministic total
function under that input; it is dead with respect to the editor.

## Region rendering

The page draws each instance as a wash over its whole membership area
(selected streams × time span), not only its occupied cells: a region
is a place, present even where empty. Hue is per group —
`(groupId-1) % 8 + 1` into the shared 8-colour `palette.region`, stable
because `groupId` is stable and persisted, so deleting a group never
recolours the survivors. Colour carries group *identity*; the per-cell
`overridden`/`conflicted` overlay is a louder coat on top — divergence
read against the group's own hue, never instead of it (hence its
heavier alpha, so it stays legible over the wash). A member instance
shows only the wash. Outside region mode the instance the caret sits
inside gains a 1px hue outline — a quiet "you are here". In region mode
that gives way to the region-cursor instance's 2px outline plus the
`x=-1` gutter slot, which lights only when the cursor is genuinely
inside the instance (a member stream at the cursor column ∧ ppq within
the span), not merely sharing a row. A conflicted instance always
outlines in any mode — an alarm that must always show.

## Block-shift injectivity

`gm:footprintAliases` is a precise per-cell predicate for propagating block ops
(decision 3 in group-aware-editing). Each footprint cell maps to a region slot
via `classifyCreate` + `toGroup` + `laneId` (the `sameSlot` triple). Two cells
on one slot — two instances of a group overlapping the block at the same relative
position — make the op non-injective: the re-adds at the destination would
double-write the shared pattern.

Precision matters: disjoint slots of two instances stay legal. A block covering
the top half of one instance and the bottom half of another maps those cells to
distinct slots — no alias, op allowed. A conservative "≥2 instances in footprint"
test would over-refuse this case; the per-cell slot key avoids it.
