# mirrorManager

A group is a region; an instance is one concrete placement of it. Every
instance's events are a *pure replay* of the shared group pattern plus
that instance's own overrides — recomputed from scratch on every flush,
never diffed forward. mirm wraps the pure `mirror` core with the anchor
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

- **Group-frame legato.** A tracker edit on a concrete instance event
  is transferred into the group frame through the instance anchor, then
  tv's legato rule is replayed within the group's *own* pristine event
  set. `group.events` only ever holds the canonical pattern.
- **Per-flush re-derivation.** `mirror.project` clones the group and
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

## The two-layer conform split

Tail clipping happens in two places, and neither subsumes the other.
`mirror.project` clips to `patternLen` — a hard bound so a note-off
never runs past the take (REAPER would physically extend it). project
sees one instance's projection, so the *realised* next note may belong
to another instance and is not in `desired` by construction; it cannot
do the cross-instance clip. That is conform's job: `conformVuids` marks
the last-in-lane note per stream, `reproject` sets `conform=true` on it,
and trackerManager's conform-tail rebuild pass caps the realised
note-off against whatever physically follows, across instances. An
earlier design deleted conform; the cross-instance case forced its
return.

`conform` is a per-instance realisation marker mirm owns — never a
shared group field, never through `toGroup`, never set by the user.
Promote/demote does not surface as a reconcile op on the demoted note,
so `conformSweep` stages the marker delta off the live records
directly rather than relying on reconcile to carry it. `reproject`
sweeps every instance through it; `markGroup` runs the same sweep on
instance 1 at seed time. That symmetry is load-bearing: `markGroup`
adopts the user's existing take events as instance 1, and that
geometry is *canonical* for the group — only the realisation flag is
mirm's to add. Omitting the seed sweep left instance 1's last-in-lane
note unconformed until some later edit reprojected it, so the
conform-tail rebuild pass could not clip a pattern-length tail; a note
dropped inside that tail — the first duplicate copy placed one region
below — overlapped the live source tail and was bumped to a sibling
lane (later copies land past the CSK-clipped tail and were unaffected,
which is why only the first copy showed it).

Because the sweep stages conform assigns that can surface in a later
preflush, `conformOnlyUpdate` makes `applyEdit` pass a conform-only
update straight through: it is realisation, not a logical edit, and
must not retrigger `classify`/`groupPlaceLegato`/`reproject` or it
would churn the canonical group geometry.

## Lane identity is per channel

The region is per-channel — `rect.streams` is keyed `[chanOffset][streamId]`,
so `streamId` there is correctly channel-free; the offset is its own
dimension. But geometry *inside* the group frame — `mirror.project`'s
slot-dedup, its legato chains, `conformVuids`, `groupLane` — resolves per
lane, and a lane lives in one channel. Keying those by `streamId` alone
(`evType:key`) collapsed two channels at the same lane and onset into one
slot: the lower-vuid (leftmost) note claimed it, the other was conflicted
out of `desired` and never projected, so only the leftmost channel of a
multi-channel group mirrored. `mirror.laneId` (`chanDelta` + `streamId`) is
the group-frame lane identity those passes key by; `streamId` stays the
channel-free region-membership key.

## Regions are disjoint

Two groups whose footprints overlap have no defined behaviour, so
`markGroup` and `newInstance` reject a placement that collides with a
live instance and the op becomes a silent no-op (the existing
out-of-range precedent). Two failures motivate the bar. A freshly
typed event with no prior identity is adopted by `classifyCreate`,
which walks `pairs(groups)` and takes the first containing region — so
in an overlap *which* group claims the note, and therefore which
siblings it mirrors into, is unspecified and can change between
rebuilds. And `mirror.project`'s slot-dedup and `conformVuids` resolve
within one group; two overlapping instances each project a note-on
into the same slot with no cross-group dedup and each conform pass
blind to the other's tail — the cross-identity leak the replay model
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
carry the ops. `propagating` guards mirm's own staged adds from
re-entering `applyEdit` as user edits; `selfStaged` does the same for
newInstance's projection adds, which commit on a later flush.

`uuid` is mirm's only durable identity. tm swaps every event table on
rebuild, so the runtime projection is re-anchored by uuid each window;
only the vuid→uuid slice persists, rebuilt by `rehydrate` on a
take-changed rebuild.

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
vuid coincident with the still-alive original, which `mirror.project`'s
slot-dedup then silently collapses, losing one. Instead `revivableVuid`
matches the typed event against the instance's `deletes` by stream +
onset; on a hit the create clears `instance.deletes[vuid]` and
overwrites that existing group vuid in place — "type over deleted
clears the delete". This is one case of a general clear-any-override
mechanism; the others (local assigns/adds, local-mode revive) are not
yet implemented.
