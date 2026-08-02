# fx freeze — committing generator output

> opened: 2026-07-11 · status: parked — `plan/fx-freeze.md`
>
> Working design doc, split from `design/note-macros-v2.md` § Freeze
> after the 2026-07-11 design round (that section has since been
> removed there; this doc is the whole record). That section's framing —
> freeze as the invertibility axis, unfreeze restoring the fx region —
> is superseded: **freeze is one-way in both directions**. The generator
> is discarded by both verbs; there is no unfreeze and no dormant
> record. The want unfreeze was carrying ("instance the vibrato, keep
> tweaking it") is a different feature — **fx on groups** — pinned at
> the end, not built here.

## The model

Three mechanisms, three points on the generator spectrum
(note-macros-v2 § The generator spectrum):

- **live fx region** — lossy macro, regenerated each rebuild.
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

## pb/at as first-class gm members

pb/at members half-work by construction: `keyOf` falls through to `0`
for anything not note/cc (`groupManager.lua:97`), `copyScalars` is
opt-out, and `streamId`/`laneId` are generic — so a pb/at event rides
the duals with stream identity `'pb:0'`/`'at:0'` and its payload
crossing as scalars. Neither implemented nor not: the type-specific
seams were never built, and most of them turn out not to be needed.

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
intent and cross generically. (See design/decisions.md 2026-07-11.)

**How each seam behaves:**

- region collection → `rect.streams`: generic — a group marks off a
  `pb:0` stream via `eventsInRect`. A mixed pb+at+note rect is
  unverified.
- facade routing: a member pb value edit reaches `gm:assignEvent` and
  propagates to siblings. No dedicated `updToGroup` pb arm — the group
  frame tolerates the `val` passthrough, and dropping `val` is what
  breaks it.
- `classifyCreate` adoption: a fresh in-region pb is adopted and
  propagates off generic `keyOf`/`streamId`, no type arm. Its
  add-target is the member backing's `add` (trackerView.lua:85).
- `moveInstance` sideways dispatch: `laneWalkable`'s positive `^note:`
  allowlist (`editCursor.lua:648`) fails `pb:0`/`at:0`, routing them
  to channel-move.
- `revivableVuid` stream+onset matching rides the generic streamId,
  which is likely enough; unverified.
- persistence/undo: the `groups` blob carries pb intent under `val`
  (no cents sidecar — the design's whole point), survives serialise,
  and rehydrates live. Undo is the same rehydrate off a ds-invalidate.

**pa stays out.** `keyOf` would collapse every pa lane onto `'pa:0'`,
and pa is note-column resident — it needs a lane-aware key arm and
has no consumer. Deferred with this note.

## Freeze to raw

Output becomes plain authored MIDI; the region and its authored
membership are gone.

- **Notes**: clear the `derived` sidecar on the standing take events
  (they already carry uuids). They enter columns as authored notes on
  the next rebuild.
- **Continuous**: nothing moves. Seats are markerless natives
  recognised only by the live region's window (note-macros-v2 §
  Route-by-window); with the region gone they simply *are* authored
  automation. Baked verbatim — raw is the fidelity end; no thinning.
  Verbatim on the wire, that is, but not in the authored frame
  (2026-07-28): a live seat carries no cents sidecar, cents being
  RAM-only for a seat, so freezing a pb curve is the moment it
  acquires authored cents, rounded from the raw. Every breakpoint off
  an integer cent shifts by up to half a cent. Inaudible at usable
  depths, and the reason a freeze cannot round-trip exact.
- **Parked members are destroyed** (both verbs). The chord you see
  vanishes; the arp you've been hearing appears. The one genuinely
  destructive step — and still ungated (2026-07-28). An earlier draft
  put the sole confirm gate here, on the reading that only a
  discrete-replace chain destroys anything. It doesn't: `parkWindows`
  opens a cc/pb window per continuous dest for **augment as well as
  replace**, so any chain over authored material parks something, and
  the gate would fire on nearly every freeze. A confirm that always
  fires is a keystroke tax, not an interlock. What dies is on screen
  (parked cells render) and the conversion is one undo block, which is
  where every other destructive verb here leaves it.
- **Tails**: nothing to do (2026-07-28). This read "promoted notes
  join the unified tail walk, derived region notes having been exempt
  from it" — and they were never exempt. `walkable` filters the raw
  index only; derived notes reach the walk by the extras door
  (`noteLive`), where fresh ones are marked disturbed. Promotion swaps
  which door a note enters by, not whether it is clipped, so a frozen
  note's tail already is what an authored note's tail would be.
- **Parked PAs go with their host** (2026-07-28). A parked `pa` spec
  is anchored to a parked *note* spec (`hostParked`), not to a window,
  so dropping by window coverage alone strands it — and the next
  rebuild reads its host as unparked and restores it to the take, an
  orphan aftertouch on a pitch that no longer sounds. Freeze drops the
  pa entries riding a dropped note spec in the same pass.
- **Addressing declines at the view** (2026-07-28). `tm:freezeRegion`
  returns nil for a uuid that is neither a live region nor an
  fx-carrying note, so the tv verb could have leant on that alone: one
  refusal, in the layer that owns the projection. It doesn't — the
  keystroke path and the fx tab's button both test `tv:noteFx(uuid)`
  first. The button needs the *disabled* state rather than a refusal,
  and that has to be answerable without invoking the verb; testing the
  same fact on the keystroke keeps the two entry points agreeing about
  what counts as a freezable host.

## Freeze to group

Everything above, except the output lands as a stock gm group instead
of loose events:

- **Mint** via `gm:markGroup(events, rect)` (`groupManager.lua:429`)
  — the clipboard ingestion seam, reused verbatim. Members: the
  derived notes (uuids already minted) + the **thinned** continuous
  curves. rect from the output footprint (note lanes used + curve
  streams × the region window); instance 1 anchored at the region
  origin.
- **The rect is the region window exactly, and the conversion pulls
  the closing pb seat inside it** (2026-08-02). A pb window folds
  `closed`, so it seats its last breakpoint on `endppq` — one tick
  outside a rect of the region's own span. Leaving it there is not
  cosmetic: `tv:clearRegionAt` runs before the projection in
  `groupDuplicate` and clears `[anchor, anchor+dur)`, so tiling a group
  directly below itself deletes the copy above's closing member, and
  nothing reports it — gm calls every remaining cell synced and a later
  mirror edit reaches nothing. So `thinSeats` relocates that seat to
  `endppq - 1`, displacing whatever survived the thin on that tick. Two
  alternatives were measured and rejected. Widening the rect by a tick
  drifts every frozen pb group: `duplicateCascade` advances by
  `rect.dur`, so each copy in the cascade lands a tick further out.
  Tagging the terminal seat `derived` so it hides hands ownership to
  the pb pass, which re-derives what it owns — nothing predicts a
  closing re-centre for an authored curve, and the reconcile deletes
  the event outright. The move is the group verb's alone (freeze-to-raw
  mints no rect, so the shift would be distortion bought for nothing)
  and pb's alone (a cc window is half-open and seats nothing at its
  end).
- **Curves are re-seated sparse — by subtraction** (2026-07-31). The
  thin runs inside the raw conversion's own staging block: the doomed
  breakpoints are deleted along with everything else the conversion
  drops, and the survivors are simply the seats that were already
  standing. Nothing is written. An earlier reading here had the dense
  seats deleted and the thinned breakpoints authored fresh, uuids and
  cents sidecars and all — a flush's worth of work to arrive at the
  events that were already there — and it does not survive two facts.
  A seat is native MIDI with a RAM-only uuid
  (`trackerManager.lua:4462`), so it cannot be a member as it stands;
  but the closing rebuild's pb pass back-derives its cents and
  persists them the moment its window is gone
  (`trackerManager.lua:4296`), and that is exactly what stamps the
  sidecar and makes the uuid durable. The pass that authors the curve
  is one freeze-to-raw already performs. The group arm's whole job is
  to decide, before that flush, which points do not get to be
  authored.
- **Members are column events, not staged ones** (2026-07-31). gm's
  group frame is the authored one: `toGroup` reads `evt.ppq` as the
  logical onset, and `copyScalars` is opt-out over a `DERIVED` set
  that does not list `ppqL` (`groupManager.lua:19`) — which is why
  `projectEvent` strips the raw sidecar rather than let it "ride out
  through park / clipboard / gm" (`trackerManager.lua:2018`). A staged
  um event is the opposite of that: `realiseAddPpq` has put raw in
  `ppq` and logical in `ppqL`, so minting off staged tables computes
  the group offset in raw ticks against a logical anchor and carries
  the sidecar into the group frame. Cloning to fix the frame breaks
  the postflush uuid back-fill, which works by table identity. With
  the thin subtractive there is nothing staged to mint from anyway —
  the members are the promoted notes' and surviving breakpoints'
  column cells, exactly what `tv:eventsInRect` hands `gm:mark`.
- **Validate first.** `markGroup` refuses a footprint colliding with
  a live group — its `regionConflict` check must pass before any
  mm/ds mutation, or freeze half-applies.
- After the mint the group is ordinary: mirror-edit it, instance it,
  delete it. No frozen-ness survives.

**The thinner.** A tolerance-bounded simplification (Douglas-Peucker
over the piecewise-linear runs; tolerance in the dest's own unit, which
`generators.destProfile` already spells cents for pb and steps for cc —
so the function needs no dest branch at all). Pure function, home
beside the other pure fx logic in `generators`; a `curves` module was
the alternative "if import wants it too", but `paramAutomation` turns
out to be the JSFX param-binding applier with no curve import in it, so
there is one consumer today and `generators` already hosts non-stage
pure helpers (`parkWindows`, `curveAt`, `destProfile`) (2026-07-30).
Thinning is freeze-to-group's alone: it turns a dense carried curve into
sparse, genuinely hand-editable group material — the point of choosing
the group target. Freeze is already the lossy projection; a bounded thin
is honest.

**Tolerance is config, not a constant** (2026-07-31). The value comes
from a cm entry with a shipped default, in the dest's own unit as
above — chosen over a constant so it becomes user-tweakable from the
config editor when that lands. Exact key shape is implementation's.

**What the thinner is allowed to see** (2026-08-01). Not everything
standing inside the window is curve material. An absorber seated around
a detune onset went into the thin as an ordinary breakpoint, and being
at the window edge it was a hard keep — which quietly distorted the
chord Douglas-Peucker measures deviation against; had it fallen
mid-run instead, the thin would have deleted it outright. It is not
freeze's to touch either way: an absorber carries a persisted `derived
= 'absorber'` tag because it is realisation the pb pass owns and
**re-derives after the freeze**, around whatever detune onsets survive
it. So the raw gather skips any entry with `derived` set.

Worth seeing that this is the same partition `groupMembers` applies one
frame along as `not e.hidden` — the column projection draws `hidden` as
`pb.derived ~= nil`, so the two tests are one question asked in two
frames: is this a point the author put here, or a point the
realisation put here? Freeze only ever gets to speak about the first
kind. A future reader tempted to widen either test should expect the
other to need widening in step.

**Curved shapes survive verbatim** (2026-07-30). An earlier draft had
the thinner emit linear breakpoints throughout, on the reading that the
standing seats are already a densified polyline. They are not. A replace
stage assigns its delta verbatim (`trackerManager.lua:3311`) and
`foldChains` short-circuits a lone covering record, so a lone pb-replace
sine seats four `'slow'` extrema per cycle, tension and all. Only an
augment fold or overlapping chains densify — `sumStreams` samples a
feature-point pair only where a constituent is curved, and emits
linear/step — plus the detune-onset `densify`. So one rule covers every
non-linear shape: a point whose shape is not linear is a hard keep,
carried with its tension, and the recursion runs only inside maximal
runs of linear points. `'step'` because it means
held-then-jump and DP across it would ramp a stepped LFO; curved
because a `'slow'` pair is already two points and already exact.
Freezing a lone continuous macro is therefore *exact*, and its output is
better hand-editable material than a thinned polyline would be; the
bounded thin bites only where something genuinely dense exists. Two
things this rules out, so a later reader doesn't read the omission as an
oversight: flattening a curved segment when tolerance would allow it
(no saving — it is already two points — and pure loss), and refitting a
dense linear run back into a curved segment, which is curve fitting and
a much bigger animal.

**A non-linear point pins its successor too** (2026-07-30). The keep
rule above is half the story on its own. A shape governs the segment to
its *right* (`curveSample(shape, tension, t)`, `midiManager.lua:143`),
so dropping point *k* re-spans **`points[k-1].shape`** over the wider
gap: after a `'step'` the hold extends and the jump moves, after a
`'slow'` the half-cosine stretches — and in both the chord error term is
measuring a curve that will not be drawn. A point is removable only
when it *and* its predecessor ride linearly, which is what "the
recursion runs inside maximal runs of linear points" has to mean: a
run's closing endpoint is the non-linear point itself, its opening
endpoint that point's successor.

**A nil shape counts as non-linear** (2026-07-30). An earlier draft
read nil as linear. The repo is split on the default — the wire one is
step (`midiManager.lua:1253`, and the pb/cc base builders all read
`shape or 'step'`) while `sumStreams`' `governingShape` alone reads `or
'linear'` — but the seats the thinner is handed always carry an explicit
shape, so the choice only decides which way to be wrong. Nil-as-keep
under-thins, which is visible and harmless; nil-as-linear silently ramps
a stepped curve. So the predicate is `p.shape == 'linear'`, nothing
more.

**The error term is vertical, not perpendicular** (2026-07-30).
Textbook Douglas-Peucker measures perpendicular distance to the chord,
but one axis is ticks and the other cents: perpendicular distance
depends on an arbitrary ticks-per-cent aspect ratio, and "tolerance in
cents" would mean nothing under it. Same recursion, error
`|val(t) − chordAt(t)|`. And because DP *selects* input points rather
than inventing them, output values stay the exact authored integers —
no rounding question arises.

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
- the window **covers an fx-carrying host note** — for the group verb
  an independent producer that would keep regenerating inside the new
  gm rect, behind gm's shadow; for raw, a producer destroyed with the
  chord, losing either its seats or its whole output (2026-07-28,
  below);
- the frozen producer is a **note host whose span meets another
  producer's note window** — it emits no park window of its own, so a
  window-vs-window test has nothing to refuse on, and its promoted
  output would land inside that window and be parked straight back
  off-take (2026-07-28, below);
- (group verb) the footprint **collides with a live gm group**
  (markGroup's own check).

A neighbouring (non-overlapping) region B on the channel may
reshuffle its lanes once after A freezes — promoted notes become
authored occupancy seeds for `allocateRegionLanes`. One reshuffle,
then stable; churn, not corruption.

**The host-note gate is both verbs', not the group verb's**
(2026-07-28). It was group-only on the reading that only gm's shadow
makes a swallowed producer harmful. Raw has its own version: a covered
note carrying its own chain is destroyed with the chord. What that
costs depends on the chain — a continuous-only host leaves its windows
standing in the baseline, so the next rebuild diffs them as removed
and sweeps seats nothing produces any more; a note-dest host has no
windows to strand and loses its entire derived output instead. The
overlap gates reach neither, because a note host's own note window is
suppressed (`noteHost`) and a continuous-only chain shares no target
key with a note-dest region. The recourse is to freeze the host first
and the region second, which gives the right answer.

**A note host's own freeze needs the inverse gate** (2026-07-28). A
note-dest chain on a note emits no park window at all, so the frozen
producer can present nothing for a window-vs-window test to refuse.
Freeze a host whose span runs under a live region's note window and
its promoted output lands inside that window, is parked off-take as a
covered chord member, and the region's output stands in its place —
the conversion swallowed inside its own call. The test is the host's
span against other producers' note windows, which needs the producer,
not its (empty) window set.

**The gates read a producer census, not `prevWindows`** (2026-07-28,
correcting an earlier reading the same day). `prevWindows` looked like
the census — `assembleParkWindows` builds it from regions + on-take
hosts + parked fx hosts — but it is not one, in both directions. It
**double-counts**: parking is deferred to the tail-walk commit, so at
`settleWindows` time a self-parking host is still in `columns.notes`
*and* already in `noteParked`, and both arms add it. It is the same
collision `rebuildRegionPark` guards with `seen[evt]`, one level down
and unguarded. And it **under-counts**, by the note-dest host above.
Multiset accounting over such a table refuses every note-host freeze,
and no accounting recovers a producer that never appears at all.

So the census is a list of **producers** — the body of
`assembleParkWindows`, lifted to a named function returning
`{ uuid, chan, startppq, endppq, fx, noteHost }` records. Freeze drops
the frozen uuid and gates against the rest by owner identity rather
than by window value, which is what lets it tell "my second stage"
from "your identical window". It also collapses the three hand-kept
copies of the note-is-a-region literal to one — the agreement
`trackerManager.lua:4647` warns about. `prevWindows` goes back to
being only what it is good at: the set-semantics recognition baseline,
which is still what freeze's resync drops its own windows from.

**But the resync's own subtraction is one-for-one** (2026-07-28). The
baseline has set semantics downstream — the pb create/remove diff keys
windows by (chan, start, end) — and that is exactly why freeze must not
subtract with them: the entries carry no owner, so consuming every
`deepEq` match takes an identical-window neighbour's entry with it, the
next rebuild reads the survivor's window as newly created, and parks
the freshly authored curve straight back off-take as though it were
someone's authored base. Claiming one baseline entry per frozen window
is the fix in place. It is a multiset patch over an identity-less
table, and the census above is what dissolves it. The double-count is
fixed at its source in the same pass: a host present in both arms of
`assembleParkWindows` is taken from the parked arm, not the `hostWins`
one. Those two arms disagree where a lane clip bites (the parked arm
takes `endppq` from the spec unclipped), and the parked arm is the one
every subsequent rebuild will use — so preferring it makes the parking
pass's window agree with the next pass's, which is the whole property
the baseline diff rests on.

**The double-count is index lag, and the census was not its only
victim** (2026-07-29, correcting the mechanism above by measurement).
The reading that a self-parking host is "still in `columns.notes`" is
wrong: `reconcilePark` unlinks its cell from the lane at once, and only
the mm delete is deferred. What survives the park is the **fx-host
index** — membership turns over when that delete commits at the tail
walk, and `computeFxWindows`' per-host path resolves uuids through it.
So the stale entry is a reader's view of an index, not of a column, and
`assembleParkWindows`' dedupe was a reconciliation at the reader. Fx
expansion reads the same index-derived set with no dedupe, and
enumerates a mid-park host twice — once from `fxWindow`'s keys, once
from the parked cells — so the chain runs twice and its two pb chains
sum: a self-parking host carrying `sine depth=30` bends 60 cents. The
whole suite is green either way. The fix is notification instead of
reconciliation: the settle pass hands `computeFxWindows` the parked set
it already holds, the index's lag stops being observable anywhere, and
the census dedupe is deleted rather than lifted. Recorded here because
the census the gates rest on is only trustworthy downstream of it.

**Identity reaches the baseline as a stamped `id`** (2026-07-28). The
census names owners, but the baseline's entries don't carry the name,
so census-vs-baseline subtraction still bottoms out in value matching.
The missing half is one field: `generators.parkWindows` stamps every
window it emits with `id = <producer uuid>` (census records carry it),
`prevWindows` persists the field, and the resync becomes "drop the
windows whose `id` is the frozen uuid" — a chain's two identical
windows drop together because they are the same producer's, which is
what the one-for-one accounting was approximating. `id` is inert
downstream on purpose: the pb create/remove diff and `rebuildCCs`'
recognition stay span-keyed, because seat recognition is spatial — a
markerless seat belongs to whatever window covers it, and an
owner-keyed diff would sweep-and-repark on an ownership handoff whose
coverage never changed. Identity for subtraction, spans for
recognition. The other route — resync by recomputing the surviving
producers' windows and overwriting the baseline wholesale — was
rejected: freeze runs outside the rebuild's settle machinery, so every
window it recomputes differently from the last rebuild becomes a
phantom transition next rebuild, the field-for-field agreement problem
again for all producers at once. `freezeRegion` still computes
`windows` for its own `covered()`; nothing matches them against the
baseline any more. The persisted-shape change is free pre-beta.

**pb windows are closed at `endppq`, cc's are not.** Seat recognition
is inclusive there, so two abutting pb windows share their boundary
seat and a half-open overlap test reads them as disjoint — the gate's
predicate has to be inclusive for pb. The consequence (whether the
neighbour's fold actually re-derives that seat out of a frozen curve)
is unconfirmed; the phase's pb fixtures are where to settle it.

*Settled by the recognition rule, not a fixture* (2026-07-30). Whether
the neighbour's fold re-derives the shared seat turns out not to
matter. Freeze leaves that seat standing as authored, and the
neighbour's window still recognises it — recognition is inclusive at
`endppq` — so the next rebuild reads a frozen breakpoint as one of its
own seats whatever it then does with it. That holds whichever side
freezes, so the predicate is inclusive at both ends and abutting pb
producers refuse each other mutually. `tm_fx_region_spec`'s abutting
pair pins it against the half-open cc contrast.

**Refusals never surface** (2026-07-28). Freeze declines silently, at
tm and at the verb alike. There is no toast or alert facility and
building one for this is out of keeping with the house style. Note
that same-target continuous overlap is a **mutual** refusal — either
producer names the other — so a locked pair has no freeze-one-first
recourse, and editing or deleting a chain is the way out. Accepted
with that cost.

*The ordinary instance is a chord* (2026-07-30). That mutual lock is
not an exotic case: two chord-mates each carrying the same continuous
chain hold identical windows, which is simply what authoring a chord
with one macro produces, and neither member can be frozen while the
other's chain stands. A spec asserted the opposite until this phase —
freeze the first, survivor keeps its curve — and passed only because it
checked the survivor alone, never whether the frozen member's curve
survived as authored. It does not: the survivor's window still covers
those seats and its fold re-derives them.

**Freeze settles the take before it reads the census** (2026-07-30).
The census's three arms all answer "what is committed" — `fxRegions`,
the maintained fx-host index, the stash — while `freezeRegion`'s own
closing flush commits whatever was staged. A host staged and not yet
flushed is therefore invisible to the gate and then minted by the
freeze, landing a live window over the seats it has just frozen:
markerless, inside a window, re-derived by the very producer the gate
would have refused — delivered with success reported. Freeze flushes
first rather than documenting a settled-tm precondition, because the
precondition's failure mode is silent. The costs are one empty
`preflush` per freeze (`flush` fires it ahead of its no-op check) and,
where ops genuinely were pending, their landing inside freeze's undo
block.

**A refused freeze still opens an undo block** (2026-07-30, closed
2026-07-31). `tv:freezeRegion` is wrapped in `util.atomic`, which
begins and ends the block unconditionally, so a refusal leaves a
labelled entry that changed nothing — and per this section's silence,
that entry is the user's only signal that anything happened. Whether
REAPER materialises an empty block is unconfirmed. The fix is not
tm's: it belongs with the disabled-state predicate § Addressing
declines at the view already requires for the fx tab's button, which
eligibility is now a second input to.

**The close: eligibility as per-rebuild stored state** (2026-07-31,
landed ahead of phase 3's tv verb rather than with it).
`tm:freezeEligible(uuid)` — forwarded by tv, deliberately outside
`util.atomic` — reads a uuid→bool map that `settleWindows` republishes
wholesale each rebuild from the settled census: the parked set the
rebuild commits, not the head set. It is rebuild output, not a cache
with an invalidation story — every input to eligibility (regions, fx
hosts, stash, take length) changes only through paths that land a
rebuild, and every rebuild that enters the pipeline reaches
`settleWindows` exactly once — so the lookup touches nothing, where a
live query would have re-entered `computeFxWindows` per rendered frame
(the cache-warming risk the note below accepts for the verb alone).
Both view entry points, the keystroke and the fx tab's button, consult
the map before the undo block opens, so a refusal now leaves no entry
at all; the verb keeps its inline settle-first gate unchanged as the
backstop, correct even when its opening flush no-ops. The one
divergence is deliberate and pinned in tm_fx_region_spec: the map
reads the last rebuild's census, so a staged-not-flushed producer is
invisible to the predicate while the verb (which settles first)
refuses — and in exactly that path the block the verb opens is
non-empty anyway, because its flush lands the pending ops inside it.

**Freeze calls rebuild machinery from a mutation entry point**
(2026-07-30, accepted risk). The pre-gate `computeFxWindows` warms
`fxHostWin` for every on-take host from outside a rebuild. The
argument for safety is that freeze clears no dirt, so the seeds a
later rebuild re-derives on still stand, and with the leading flush
the columns it reads are settled ones. No test backs that argument:
`perHost`'s incremental path has no coverage anywhere in the repo
(docs/trackerManager.md § Fx window cache). A spec written for it in
phase 1 was removed rather than kept — it asserted an invariant it
could not reach, passing because `rebuild(true)` wholesales the
channel, and a green test read as coverage is worse than a recorded
gap. The fixture that would close it is later work.

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
- **Observer baselines resync, never sweep.** The observer is the
  `prevWindows` route-by-window baseline — no enqueue stage exists.
  Rebuild diffs current windows against last rebuild's persisted set:
  a removed window sweeps its seats (`pbRemoved`; cc recognition in
  `rebuildCCs` is prevWindows-keyed too). Resync = drop the windows
  stamped with the frozen producer's `id` from `prevWindows` in the
  same flush (§ Eligibility gates); the next rebuild sees the window
  on neither side of the diff and the seats stand as authored.
- **Marker strip + region delete together.** A rebuild between them
  regenerates the full output while `reconcileDerived` can no longer
  match the now-markerless notes — a complete duplicate set.
- **(group verb) ds `groups` write + take write revert as one.** gm
  persists on `postflush`, so the mint must precede a flush. The take
  conversion — thinning included — is the one flush above; the mint
  then rides a *second* flush carrying no mm ops at all, present only
  so `postflush` fires inside the undo block (`tm:requestRebuild`
  carries it past `flush`'s no-op gate). Revised 2026-07-31: this read
  "stage the thinned events, `markGroup` with the staged um events,
  then a single `tm:flush`" — the clipboard idiom — which the frame
  note in § Freeze to group retires. What must still not happen is
  flush-then-mint: that pushes the `groups` write to the *next* flush,
  outside the block.
- **The derived-clear rides eventMeta — project scope, which undo
  rewinds only through the pextStore mirror**
  (`design/archive/projext-undo.md`). Were the mirror absent, undo
  would restore region/stash/baseline/MIDI over notes still missing
  their tags: the next rebuild re-emits a fresh derived set and parks
  the untagged originals as bogus authored members. The mirror is
  what makes the take write and the tag clear rewind together.

## Implementation notes

- **The primitive is producer-shaped, not region-shaped.**
  `tm:freezeRegion(uuid)` handles both hosts — a region record, or a
  note host, on the take or parked. One seam, per § Eligibility gates'
  "both hosts freeze".
- **What destroys a note host is `parksNotes`, not where it was
  found** (2026-07-28). An earlier reading had the parked host
  destroyed on the grounds that a parked host is a self-parked one. It
  needn't be: a note carrying a continuous-only chain that sits under
  another live region's note window is parked by *that region* and
  still runs its producer — `assembleParkWindows` walks every parked
  note spec carrying `fx`, not only self-parking ones. So destroy the
  host iff its own chain carries a **note-dest** kind, which is what
  parked it — ownership by dest, not mode. A note-dest *augment* kind
  parks its host as squarely as a replace one; what augment buys is a
  fold that merges the host's own notes back into the emitted stream
  (`trackerManager.lua:3181-3189`), so the base note sounds as derived
  output. Either way the chain is already re-emitting whatever should
  sound and the parked host is redundant. Otherwise the host survives
  minus its chain, still parked by whatever parks it. The on-take arm
  needs no such test: an on-take host's chain has no note-dest stage at
  all, and its continuous stages may perfectly well be replace — a
  pb-replace host parks the authored curve, not itself.
- **Conversion order**, all before one rebuild, ds writes under the
  `flushingParked` suppression (which needs an error-path reset —
  today an error while the flag is up leaves every later region
  edit silently not rebuilding — and a widened comment): clear
  `derived` (mm metadata assign; notes keep uuid/lane/detune) →
  drop covered fxParked entries → drop the region → drop its
  `id`-stamped windows from `prevWindows` → dirtyChan + rebuild.
- **Gate placement.** Note-window overlap, continuous-target
  overlap, and the fx-carrying-host-note gate all live in tm
  (take-semantic); only the gm rect-conflict gate rides the tv verb
  — forced, tm has no gm reference. Compute the mint rect once,
  pre-freeze; reuse it for gate and mint.
- **Freeze-to-group choreography** is resolved in § Atomicity.
  Members passed to `markGroup` must be um-live staged events (gm
  re-anchors via `tm:byUuid`; detached clones make later mirror
  edits silently no-op).
- **Thinner input** is the standing seats in the **raw** frame
  (2026-07-31): the um index entries inside the producer's continuous
  windows, valued `entry.val - detuneAt(...)` for pb — the entry's own
  `val` is realisation, detune included, and without the subtraction a
  mid-window detune step reads as a feature of the curve — and
  `entry.val` for cc, which is intent already. The raw tick axis needs
  no apology: it is the time the curve sounds, and since the thin only
  decides which points die, no value and no onset is ever re-authored,
  so no round trip through the logical frame arises. The seats are not
  a densified polyline (2026-07-30, § Freeze to group): they carry
  whatever shapes the fold left them, curved ones included. tm's densify is a deriveChan-local closure, not reachable
  machinery, and nothing needs it: the thinner keeps curved points
  verbatim rather than sampling them.
- **Two verbs, no modal** (2026-07-31). Raw and group are parallel
  commands — group on Ctrl-Shift-E, mirroring Ctrl-Shift-D's
  duplicate-to-group — each with its own fx tab button. The earlier
  note here ("`util.atomic` wraps the post-confirm continuation")
  dated from the dropped destructive confirm; with no modal anywhere,
  `util.atomic` wraps the verb itself, as freeze-to-raw already does.
- **Three things need no extra work.** prevWindows resync suffices:
  pb absorber tags are per-rebuild clone marks off *current*
  windows, cc recognition is prevWindows-keyed, and note reconcile
  keys on `derived`. Lane stability holds: promoted notes carry
  persisted `lane`, and `allocateRegionLanes` assigns lanes only to
  derived specs. And the `derived` clear is metadata-only, so it
  takes mm's lockless path.

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
composition of freeze-to-group + fx-on-groups. Gate: the partition
must be semantics-preserving — true for today's kinds (no discrete
kind reads a continuous channel; continuous kinds read
window/params/`host` only, and relative continuous order is
preserved) **except** the `host` rebind: a kind reading `host`
(slide's next-note lookup) sees the frozen template where it saw the
original chord. Refuse or warn on host-reading kinds; re-check the
gate when any new kind lands.

## What the specs must pin

`tm_fx_region_spec` / `tv_fx_region_spec`.

Freeze-to-raw: arp authored + audible, chord gone, seats stand, *no
restore on the next rebuild* (the standing-reconcile regression),
tails clip cross-window, one undo reverts wholly, and a note host
freezes by the same seam. Each refusal declines before any mutation,
and a disjoint neighbour on the same channel still freezes. Under
those, the census itself: one producer, one entry, however many arms
of the assembly find it — and subtraction by identity: freezing one of
two identical-window producers leaves the other's window and curve
standing.

(2026-07-28) "One undo reverts wholly" is not pinnable in a unit spec:
the harness stubs `Undo_BeginBlock`/`EndBlock` to no-ops
(`tests/fakeReaper.lua`). What a tm spec can pin is the atomicity tm
itself owns — one flush, one rebuild, and the `derived` clear reaching
mm as a metadata assign; the pextStore mirror that makes that rewind
with the take is `pext_store_spec`'s subject.

The thinner is pure, so its cases live with the other pure fx logic in
`generators_spec`: endpoints kept, a collinear run collapsing, a spike
just inside and just outside tolerance, a step run and a tension-carrying
curved segment surviving intact, and output being a subsequence of input.

Freeze-to-group: group minted with note + thinned-curve members,
instance 2 replays both, mirror edit propagates, ds+take undo
atomicity, each refusal gate, and a post-freeze take round-trip
pinning that the cents-carrying seat assign mints uuid + sidecar
durably.

Thinner: tolerance bound holds, idempotent on already-sparse curves.
