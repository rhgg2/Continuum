# fx freeze — committing generator output

> Working design doc, split from `design/note-macros-v2.md` § Freeze
> after the 2026-07-11 design round. That section's framing — freeze as
> the invertibility axis, unfreeze restoring the fx region — is
> superseded: **freeze is one-way in both directions**. The generator
> is discarded by both verbs; there is no unfreeze and no dormant
> record. The want unfreeze was carrying ("instance the vibrato, keep
> tweaking it") is a different feature — **fx on groups** — pinned at
> the end, not built here.

## Status at a glance

**Open**
- [ ] F2 — the freeze pair: freeze-to-raw, freeze-to-group, and the
      curve thinner freeze-to-group needs

**Done**
- [x] F1 — pb/at as first-class gm members: audited and pinned
      (`gm_pb_member_spec` ×6, `gm_at_member_spec` ×2). Every seam
      rides generically; the only production change was `toGroup`
      sourcing pb intent from `evt.cents` + `makeEntry` carrying the
      pb `uuid` (see docs/decisions.md 2026-07-11).

**Pinned (design later, not gating)**
- [ ] fx on groups — group events are the *host material*, the fx
      chain rides the group record, realisation is derived per
      instance (§ Pinned)
- [ ] the split verb — freeze the discrete stages, transport the
      continuous stages onto the group as live fx; a composition of
      F2 + fx-on-groups (§ Pinned)

## The model

Three mechanisms, three points on the generator spectrum
(note-macros-v2 § The generator spectrum):

- **live fx region** — lossy macro, regenerated each rebuild. Shipped.
- **freeze** — a one-way projection *out of the derived lifecycle*.
  To **raw**: output becomes plain authored MIDI. To a **group**:
  output becomes the authored template of an ordinary gm mirror
  group — hand-editable with mirrored edits, instanceable. Both
  discard the generator; params are gone.
- **fx on groups** (pinned) — the live generator riding the
  invertible substrate. Not freeze at all: nothing is committed.

Freeze-to-group targets a *stock* gm group on purpose. An earlier
draft kept the generator live on the frozen group (params editable
under event overrides); it died on two structural collisions: a
generator-owned template inside gm re-imports G3 (a global-mode edit
is clobbered by the next param change, so group-mode editing must be
forbidden — a new species of group), and event overrides key by vuid,
which any param edit that changes output *structure* (arp rate,
vibrato period) shatters. With the generator discarded, gm behaves
stock: authored template, overrides amend an unchanging base, zero
new machinery inside gm.

**Why no standing `frozen` flag either.** The take has two event
lifecycles — authored (re-realised under swing, editable) and derived
(regenerated each rebuild). A region flagged frozen-but-present would
be a third: neither regenerated nor re-realised, and every pass —
tail walk, park reconcile, pb/cc transitions — must learn the
exception, forever. The verbs are one-time conversions; after freeze,
nothing downstream knows freezing ever happened. The corollary: the
conversion must be **total in one flush**, or the third state appears
anyway, unlabelled — see § Atomicity.

## F1 — pb/at as first-class gm members

Live testing shows pb/at members half-work already: `keyOf` falls
through to `0` for anything not note/cc (`groupManager.lua:97`),
`copyScalars` is opt-out, and `streamId`/`laneId` are generic — so a
pb/at event rides the duals with stream identity `'pb:0'`/`'at:0'`
and its payload crossing as scalars. "Neither implemented nor not":
the type-specific seams were never built. F1 is the audit +
completion, pinned by specs.

**The one design decision — the group frame stores pb intent under
`val`.** `makeEntry` builds the um entry's `val` as `rawToCents(wire)`
= intent + governing detune — realisation, stale at any sibling whose
detune differs. The group frame instead stores the frame-invariant
intent, keeping the existing field name `val`: `toGroup` sources it
from `evt.cents` (the intent), never the um `val`, and `detune` stays
`DERIVED`-denied so each seat re-derives its own wire at flush. One arm
at the single intent-ingress chokepoint (`toGroup`) beat renaming the
field to `cents` at every boundary. `makeEntry`'s pb pick also carries
`uuid`, without which gm's per-rebuild re-anchor (`tm:byUuid`) loses
the member and no-ops every later edit. at and cc `val` *are* the
intent and cross generically. (Landed 2026-07-11 — docs/decisions.md.)

**Audit surface** (each either works generically — pin it — or gets
its arm):

- ✓ region collection → `rect.streams`: generic — the pb propagation
  spec marks a group off a `pb:0` stream via `eventsInRect`. A mixed
  pb+at+note rect stays unpinned.
- ✓ facade routing: a member pb value edit reaches `gm:assignEvent`
  and propagates to siblings (`gm_pb_member_spec`). No dedicated
  `updToGroup` pb arm — the group frame tolerates the `val`
  passthrough (verified red-first: only dropping `val` breaks it).
- ✓ `classifyCreate` adoption: a fresh in-region pb is adopted and
  propagates (`gm_pb_member_spec`); generic `keyOf`/`streamId`, no type
  arm. Its add-target is the member backing's `add` (trackerView.lua:85).
- ✓ `moveInstance` sideways dispatch: `laneWalkable`'s positive
  `^note:` allowlist (`editCursor.lua:648`) fails `pb:0`/`at:0`,
  routing them to channel-move. Verified by reading; no spec yet.
- ⏳ `revivableVuid` stream+onset matching (generic streamId — likely
  fine) — unpinned.
- ✓ persistence/undo: the `groups` blob carries pb intent under `val`
  (no cents sidecar — the landed design's whole point), survives
  serialise, and rehydrates live (`gm_pb_member_spec`). Undo is the
  same rehydrate off a ds-invalidate (`gm_persist_reload_spec`).

**pa stays out.** `keyOf` would collapse every pa lane onto `'pa:0'`,
and pa is note-column resident — it needs a lane-aware key arm and
has no consumer. Deferred with this note.

## F2 — freeze to raw

Output becomes plain authored MIDI; the region and its authored
membership are gone.

- **Notes**: clear the `derived` sidecar on the standing take events
  (they already carry uuids). They enter columns as authored notes on
  the next rebuild.
- **Continuous**: nothing moves. Seats are markerless natives
  recognised only by the live region's window (note-macros-v2 §
  Route-by-window); with the region gone they simply *are* authored
  automation. Baked verbatim — raw is the fidelity end; no thinning.
- **Parked members are destroyed** (both verbs). The chord you see
  vanishes; the arp you've been hearing appears. The one genuinely
  destructive step — the single place a confirm gate earns its place.
- **Tails**: promoted notes join the unified tail walk (derived
  region notes were exempt), so a frozen note whose tail crosses onto
  an occupied lane clips on the first post-freeze rebuild. That is
  what authored notes do; name it, don't fight it.

## F2 — freeze to group

Everything above, except the output lands as a stock gm group instead
of loose events:

- **Mint** via `gm:markGroup(events, rect)` (`groupManager.lua:429`)
  — the clipboard ingestion seam, reused verbatim. Members: the
  derived notes (uuids already minted) + the **thinned** continuous
  curves (pb members need F1). rect from the output footprint (note
  lanes used + curve streams × the region window); instance 1
  anchored at the region origin.
- **Curves are re-seated sparse.** The dense seats are deleted and
  the thinned breakpoints written as authored events (uuids + cents
  sidecars, gm links by uuid) in the same flush.
- **Validate first.** `markGroup` refuses a footprint colliding with
  a live group — its `regionConflict` check must pass before any
  mm/ds mutation, or freeze half-applies.
- After the mint the group is ordinary: mirror-edit it, instance it,
  delete it. No frozen-ness survives.

**The thinner.** A tolerance-bounded simplification (Douglas-Peucker
over the piecewise-linear rendering; curved shapes pre-sampled by the
existing densification; tolerance in cents for pb, steps for cc),
emitting linear breakpoints. Pure function, home beside the other
pure fx logic in `generators` (or a `curves` module if import wants
it too — it is also the thinner imported param automation has been
waiting for). Thinning is freeze-to-group's alone: it turns a dense
carried curve into sparse, genuinely hand-editable group material —
the point of choosing the group target. Freeze is already the lossy
projection; a bounded thin is honest.

## Eligibility gates (both verbs)

Freeze acts on a **whole chain**; partial-stage freeze is the split
verb (pinned). Refuse when:

- the region's **note window overlaps another live region's** —
  parked coverage is a merged-window union (`generators.parkWindows`
  + `mergeWindows`), so a chord member under two replace regions has
  no extractable slice;
- a **same-target continuous overlap** exists — the painter fold's
  seats belong to the fold, not to either chain; one chain's
  contribution is not separable;
- (group verb) the window **covers an fx-carrying host note** — an
  independent producer that would keep regenerating inside the new gm
  rect, behind gm's shadow;
- (group verb) the footprint **collides with a live gm group**
  (markGroup's own check).

A neighbouring (non-overlapping) region B on the channel may
reshuffle its lanes once after A freezes — promoted notes become
authored occupancy seeds for `allocateRegionLanes`. One reshuffle,
then stable; churn, not corruption.

Both hosts freeze. A note host rides the same seam (membership
`{self}`, parked host destroyed, tiles promoted); nothing
special-cases.

## Atomicity — the conversion is total, in one flush

The transition instant is where a half-done freeze would recreate the
third lifecycle state. All of the following land in one flush / one
undo block:

- **`fxParked` entries are removed, not suppressed.** Restore is a
  standing reconcile — region gone → `parkWindows` no longer covers →
  next rebuild restores the chord on top of the output. The entries
  leave the stash.
- **Observer baselines resync, never sweep.** `enqueuePbTransitions`
  / `enqueueCcTransitions` would see the vanished window and stage a
  seat sweep. Freeze needs the invalidate-style path (the
  `dataStore.lua:127` analogue): resync the baseline, enqueue
  nothing. cc drains inline in `rebuildCCs` *before* the park pass —
  the seam covers both drain points.
- **Marker strip + region delete together.** A rebuild between them
  regenerates the full output while `reconcileDerived` can no longer
  match the now-markerless notes — a complete duplicate set.
- **(group verb) ds `groups` write + take write revert as one.** gm
  persists on `postflush`; VERIFY the group's existence and the
  marker strip share an undo block, or undo leaves a group standing
  over re-markered derived notes.

## Pinned — fx on groups, and the split verb

**fx on groups.** The live-generator point of the spectrum: an
ordinary gm group whose record carries an fx chain. The group events
are the *host material* (the chord — visible, editable, propagating
through gm as always); realisation is derived per instance window and
hidden, exactly as a live region hides its output. The promising
unification: for a replace kind, an instance's projection should land
on the **parked surface, not the take** — the parked stash and the gm
projection are the same object ("the fx stash becomes the group
events"), which dissolves the tm-parks-gm-concretes ownership hazard
structurally. Per-instance *param* overrides ("this instance, depth
55") are the natural override grain and a clean increment. Its own
design round.

**The split verb.** Freeze the discrete stages into the template;
attach the surviving continuous stages to the group as live fx. A
composition of F2 + fx-on-groups. Gate: the partition must be
semantics-preserving — true for today's kinds (no discrete kind reads
a continuous channel; continuous kinds read window/params/`host`
only, and relative continuous order is preserved) **except** the
`host` rebind: a kind reading `host` (slide's next-note lookup) sees
the frozen template where it saw the original chord. Refuse or warn
on host-reading kinds; re-check the gate when any new kind lands.

## Tests

F1 (`gm_pb_member_spec`, `gm_at_member_spec`): ✓ pb intent frame (`val`
is intent, not the realised wire); pb+at uuid survives the rebuild so
gm re-anchors via `tm:byUuid`; pb value edit propagates to a sibling;
a fresh in-region pb create is adopted (`classifyCreate`); at `val`
crosses verbatim (no cents leak); the persisted blob carries intent and
rehydrates live; a sibling under a different governing detune
re-derives its own wire (`50 + seatDetune`, not a baked origin value) —
the core intent-vs-realisation payoff. Sideways channel-move dispatch
is verified by reading (`editCursor.lua:648`), not separately specced.

F2 (`tm_fx_region_spec` / `tv_fx_region_spec`): freeze-to-raw — arp
authored + audible, chord gone, seats stand, *no restore on the next
rebuild* (the standing-reconcile regression), tails clip
cross-window, one undo reverts wholly; freeze-to-group — group minted
with note + thinned-curve members, instance 2 replays both, mirror
edit propagates, ds+take undo atomicity, each refusal gate; thinner —
tolerance bound holds, idempotent on already-sparse curves.
