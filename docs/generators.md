# generators

How a kind turns a host's contents into derived events, how a chain of
kinds composes, and how continuous output reaches the wire. `generators.lua`
is pure and holds no state of its own; the passes that run it and reconcile
what it produces are tm's, and `docs/trackerManager.md` describes those.

Four words carry the model. A **kind** is an entry in the `generators.kinds`
registry — retrig, arp, sine, slide. A **stage** is one kind with its params,
as it sits in an fx list. A **chain** is the ordered list of stages on one
host. A **host** is the region or note the chain hangs on, and its **window**
is the span that chain owns.

The decisions behind all of this, and the readings dismantled on the way,
are `design/archive/note-macros-v2.md`.

## Hosts and membership

**1** A host is a **channel × ppq span carrying an fx list** — not a set of
columns. Continuous output is channel-wide, and its target is a chosen
property of the fx rather than something inferred from the column the host
sits in. So a host says only *where, on what channel*; what the fx does is
the fx's business.

**2** **The note host is the degenerate region.** The interface a generator
sees is always a region; the representation is dual. A note presents itself
as a region whose channel and window are its own and whose fx list is
`note.fx`, but that region is never materialised — it is just the note
carrying `fx`. Explicit region objects exist only for the many-note and
no-note cases. Storage stays dual because the note case is cheap and rides
copy, move and group propagation for free; the producer is every
note-as-implicit-region together with every explicit region; and PA,
provenance and dirty-keying bind to whatever holds the fx.

**3** **Input is membership, not storage**, and the coupling between window
and input *reverses direction* between the two host kinds. For a note the
note is primary and the window is derived from it, its effective interval.
For a region the region is primary and the input is derived from it by an
overlap query. So the primitive is a region plus a membership rule — `{self}`
for a note, the overlapping notes on the channel for a region, the empty set
for a free LFO — and there is no special-casing below the contract.

**4** **Membership is by onset.** A note belongs to the region entire if it
starts inside the window, and a note whose onset precedes the window is not a
member and sustains through it. The rule reads the same in both directions,
which is what keeps it a rule rather than a pair of cases.

**5** **Replace absorbs; augment queries.** An augment's members stay in the
take: they sound, and they feed the generator. Replace cannot leave them
there, because a member the output stands in for must not also sound — and
muting won't serve, a muted note still carrying a note-on/off pair that
`MIDI_Sort` mispairs against a same-pitch derived note, and a CC or PA having
no mute bit at all. So replace **parks** its members off the take into a
store, re-homed each rebuild as coverage changes. The parked members are
still the membership, and — inverted from intuition — they are the *visible,
editable* surface: you see and edit the chord, while the generated arp is
hidden realisation. The invariant underneath is that **creating an fx region
never changes what the user sees**, and it holds for every replace path — the
note chord, the cc source, and pb. Whether a host parks is read from its
kinds rather than from a mode toggle on the host.

**6** **A note host parks itself.** A note carrying a discrete-replace kind is
its own membership, `{self}`, so it parks exactly as a region parks a covered
chord: every hit is derived output, and the parked cell — the one carrying the
`fx` — is the visible, editable surface. The two host kinds then differ only in
membership and in where the fx is stored, which is the precondition for a stage
behaving uniformly on both.

**7** **There is no dirty tracking to design.** The rebuild regenerates and
diffs unconditionally, so "membership changed → regenerate" is a non-problem:
a region re-queries its covered notes each rebuild, and the output is stable
so long as that query is a pure function of current note positions. The
membership query is the one genuinely new mechanism, a note host never
needing one because it *is* its own membership.

## The chain

**1** Bare kinds are rigid in a particular way: you can arp, but not shape
the arp's velocity; vibrate, but not bend the rate in flight. The first
model ran every kind against the *same* host and unioned the results, so no
kind ever saw another's output and "shape the arp's velocity" had nowhere to
live — a second kind could read the chord, never the arp's notes.

**2** So the list is a **series, not a fan-out**. A `{notes, delta}` stream
is threaded through the stages, each transforming what the last produced.
`[arp, velPattern]`: arp turns the chord into arp notes, velPattern rewrites
their velocities.

**3** One contract, no role. Every stage is the same pure function returning
its own *output*, which the runner folds — there is no source/transformer
distinction in the data, and no privileged head. Every kind reads `stream`,
so any kind composes at any position: `[velPattern, arp]` arps the
re-velocitied chord, `[retrig, arp]` arps the tiles.

**4** `host` is the second argument purely so a stage *can* read the
untouched original. That is cost-free provenance; slide's next-note lookup is
the one real use, being keyed on the original note record's identity.

**5** `mode` is the **fold** — replace overwrites the stream's dest channel,
augment adds to it — and belongs to the kind. `dest` is chosen per entry from
the kind's domain profile, so one dest-blind sine serves pb and every cc
rather than one kind per wire, and a param expressed as a magnitude scales
into whatever wire it lands on. The two stay independent axes, which is what
makes continuous-replace and discrete-augment both expressible.

**6** Order is therefore semantic rather than cosmetic. A note-replacing
stage overwrites `notes`; an augment adds to the typed continuous channel; a
velocity transformer reads and writes `notes` and passes the rest through.
`[replace, augment]` wobbles the replaced curve, `[augment, replace]`
overwrites the folded stream.

**7** A transformer rewrites event *values* and nudges *discrete* timing. It
cannot coherently rewrite a continuous source's **rate**, because those
breakpoints are placed by accumulated phase and resampling them loses
coherence. Hence the line: value and discrete timing are chain stages, while
rate, period and phase stay params inside the source. Moving one without
resampling anything is `design/pipe-dreams.md` § Param modulation.

**8** A **bypassed** stage stays in the chain with its params intact and
contributes nothing — the A/B gesture, which otherwise costs you the stage.
Its identity in the fold is augment-with-no-output rather than an early skip:
ownership is registered inside the fold, so a skipped stage would emit no
record at all and the parked chord and parked base it left behind would never
be re-seated — silence, not neutrality. `chainDestType` reads the same rule
from the other end, counting a bypassed stage as augment so that a bypassed
replace stops overwriting a lower-precedence chain's curve on the same target.
The flag is realisation metadata and reaches nothing else
(`docs/trackerView.md` § Note FX stages).

**9** Composition buys a *smaller* vocabulary rather than a larger one. Most
wishes for a new kind turn out to be spellings of a few hard primitives —
strum is `[arp, humanize]`, a gated arp is `[arp, densityGate]` — so the
registry stays small and expressivity comes from the series. This is
generators-as-config one level up: a kind is data when its body is arithmetic
over ctx ops, and a chain is composition as data.

## Output

**1** A stage's output is the **total realisation within its window** — every
audible event, all of it derived. Two channels carry it, notes and deltas,
and the set is meant to stay at two: PCs belong to PC synthesis, and sysex
was the rejected path.

**2** **New events only, never edits to inputs.** What looks like a
generator truncating its host is the tail walk clamping *realisation*, not
the generator revising a note. Output is strictly new derived events, and
that is what preserves the intent/realisation split and the round trip.

**3** **Lane allocation resolves all overlap, and output never self-clips.**
Discrete output can be polyphonic — a chord arp, a dense fill — so its notes
need voice allocation within the region's channel. Simultaneous generated
notes take separate lanes; sequential ones share a lane and abut; authored
notes are immovable, so derived notes pack into lanes free within the
region's span and append a lane only when none is free. This is the packing
the tracker already runs on authored notes, re-pointed. There is no
tail-clipping among a generator's own members.

**4** Determinism is the whole ballgame. Because lane allocation is the sole
overlap resolver, it has to be a pure function of the region's occupancy —
lowest free lane first, deterministic append. Lean on iteration order or on a
counter and a flush → rebuild → flush cycle reshuffles lanes into permanent
churn.

**5** One overlap lane separation cannot fix: two generated notes at the
*same pitch* that overlap collide on the wire whatever lane they sit in. That
is a constraint on kinds — don't emit same-pitch overlap — rather than a
defect in the allocator, and it would bite a fill or an arp folding back onto
a pitch.

**6** PA binds to the region: channel × ppq, stable and persisted, with the
degenerate note host binding PA to its note. A PA parks with its host,
region-parked or self-parked.

## Emission is ownership

**1** A stream channel is emitted, and its authored base parked, exactly when
some stage's `dest` targets it. Untouched channels stay authored and
sounding.

**2** The tempting rule is the simpler one — the final output *is* the final
stream — and it re-emits a vibrato-only host's untouched membership as
derived duplicates of notes already on the take. Ownership is the correction:
`parkWindows` names a window per continuous target, and `parksNotes` fires on
any note-dest kind, mode irrelevant.

**3** A chain that folds nothing still owns what it claimed. It re-seats the
parked base, or, over an all-zero pb base, registers an empty window so stale
seats sweep.

## Input streams

**1** `host` and `stream` are one record, scoped to a window and channel, in
the logical frame and in intent units.

**2** The continuous channels are **absolute closed curves**, seeded from the
authored base *as parked* — the park stash authoritative inside its windows,
the on-take stream elsewhere — and sliced to the window with entering and
closing edge values, so a curve is total over the closed window. A stage can
therefore read `stream.pb` and `stream.ccs` as real summed curves, and
`stream ≡ host` holds for the continuous channels, not just for notes.

**3** PA is not special. It was once framed as a park/re-emit/rebind problem;
it is instead one of several typed input streams a generator reads over its
window. An ADSR gated by note-ons, a CC-controlled vibrato and a
pressure-aware arp all fall out of that one shape.

**4** **Read the real projections, never mm.** Re-deriving a view projection
at the seam is a smell, and for pb outright wrong — mm's pb is raw, not the
cents-minus-detune the absorber computes. The streams are cheap *because*
their intent value needs no computation, and they are projected to columns
before the producer runs. The PA projection lands after externals and parking
but before the producer, note columns being settled only by then, and it must
stay before the logical projection so pitch-column matching still works in
the raw frame.

**5** The stream key is `evt.ppqL or evt.ppq`, not a bare `ppqL` slice. An
authored cc, at or PA carries no `ppqL` wherever raw already equals logical —
identity swing, or a swing-neutral position — so the fallback gives the
logical position with no round trip through `toLogical`.

**6** The phasing is the structural move: **project inputs → generate →
reconcile outputs**. A generator consumes finished input projections, and its
output feeds the later passes.

## The ctx discipline

**1** ctx is the evaluation environment a kind's body composes against, and
it binds what the generator cannot compute for itself — only that. Pure
arithmetic stays in the module. The moment a body must find a neighbour or
honour a config bound, it reaches into ctx, and the bound set stays short
enough to state in one `--invariant:`.

**2** **A notation is read by a gesture and never by a derivation.** A pitch
demand is stored in cents, so a trill's alternation and a chord stamp's rebase
are offsets from what their host sounds, and ctx binds no temper at all. The
notation is the ladder such a demand is typed on, which the fx strip walks at
authoring time; a step count stored in a param would instead sound different
under a lens change, which renames a take's notes and leaves them where they
are (`design/sounding-anchor.md` § The notation is not a derivation input).

**3** `interval` is the instructive non-example. It looks temper-bound and is
pure note arithmetic — the microtonal offset already rides in detune — so it
lives as a module helper rather than a ctx op, beside `displaced`, which is
the same arithmetic run backwards.

**4** The direction this serves is for the kind *set* to become config: a
kind as data rather than a function. When a body is nothing but arithmetic
and named ctx operations it is already data. **Build no interpreter** — the
move costs almost nothing as long as new kinds are shaped as composition and
ctx accretes as named ops, and the same discipline is the contract surface a
user-authored kind would be written against (`design/pipe-dreams.md`
§ Scripted kinds).

## Offline continuous realisation

**1** Realisation for the continuous channels is **wholly in the take**: no
runtime component, no JSFX dependency, exportable as plain MIDI, WYSIWYG. The
earlier model summed at the node, a JSFX recomputing `base + Σ carrier` per
audio block, so the take was not what you heard until the node ran. The
carrier, the add-bank slots and that per-block summation are all retired.

**2** **One model: park the base, seat the sum.** A continuous fx region
parks the authored automation its window covers off the take, exactly as
note-replace parks the chord — bounded to authored breakpoints, visible, and
editable by re-seat. The producer emits the region's **absolute** target
curve, augment summing parked base plus macro and replace being the macro
alone, and seats it on the target lane. The two modes collapse to one
realisation path, differing only in whether the parked base folds in.

**3** **Summation adds points only where a curve is genuinely curved.** Two
piecewise-linear curves sum exactly at the union of their breakpoints. A
curved segment has no closed-form sum, so it is sampled onto the grid — the
same densification the absorber runs when a detune onset splits a curved
segment. Extra points therefore land only on genuinely curved authored
automation under a macro, or on a curved-shape macro segment; a pre-sampled
vibrato or LFO emits linear breakpoints and sums exactly. Densification adds
MIDI, never sidecar.

**4** **The grid is time-absolute, and that is what makes densification
idempotent.** Sample points snap to a global `k·gridStep` lattice in ppq, not
to a segment's own endpoints, so a curve re-densified next rebuild lands at
identical ppqs and the content-keyed reconcile sees no churn. A
segment-relative grid would be stable only while its bounding points were
authored, and a summed curve's are themselves derived.

**5** **The rule is about sums, not about curves.** Sampling every curved
segment, whether or not a second curve was there to sum against, sent a lone
sine to the wire as some thirty linear breakpoints where ten `slow` ones say
the same thing exactly. A curve that is the only thing moving across a
segment *is* its own sum plus a held constant, and interpolation is affine in
the endpoint values, so that offset shifts the curve and leaves its shape and
tension untouched. It has to be the *whole* segment: a shape function reads a
normalised `t` over the segment's own span, so half a `slow` re-fitted across
its own left half is a different curve. The test is that the pair's ends
coincide with the constituent's own breakpoints, at both ends and not merely
the far one.

**6** **Sparse output makes the fold's span load-bearing.** While every
curved segment went onto the lattice, the fold's output was the same however
its span was cut — a global function of time lands on identical ppqs under
every decomposition. A verbatim segment is not: it depends on where its own
ends fall relative to the cut, which put the gated rebuild and a full
re-derive in disagreement wherever the dirt sliced a channel differently from
its record edges. So the fold runs over its covering records' own **extent**
and treats the span as a selection of what to emit. Idempotence simply
stopped coming for free from the lattice; the fold pays for it now by not
letting the dirt decide where segments fall.

**7** The near miss worth marking: slicing a curve asks what looks like the
same question and answers it differently on purpose. A cut curve carries its
shape *and* tension across the slice edge and accepts the re-fit, because an
authored bezier is meant to keep its tension inside an fx window. Summing and
slicing are not one rule waiting to be unified, and teaching the slicer to
densify what it cuts breaks that immediately.

**8** **Detune folds in unchanged.** Each pb seat's wire raw is the curve
value plus detune, split at detune onsets exactly as the replace-pb path
seats: detune stays realisation on the pb wire and the curve rides on top. cc
has no detune residual, so a cc seat is the curve value verbatim.

## Route-by-window

**1** The seats carry **no per-event metadata**. A dense curve is thousands
of breakpoints, and a `derived=` sidecar on each explodes the persisted data.
They are recognised as generator-owned *structurally* — by the region's
window, not by a marker. Inside it every event is re-derived each rebuild,
content-reconciled, routed out of the column, and kept out of the authored
value stream by the window alone.

**2** Continuous only: a target is pb or a cc number, never a note. A note
carries a uuid and notation sidecar for identity and round-trip regardless,
so markerless elides nothing there. Only the continuous streams, whose seats
are pure realisation, win anything.

**3** **The enabling invariant is exclusive ownership.** A markerless seat is
indistinguishable on the wire from an authored pb or cc, so recognition works
only if *everything* on-take inside a replace window is generated. The
authored events are stashed off-take into one `evType`-tagged list, and stay
visible through a render union the view folds in — symmetric with how it
unions the parked chord. Audibly a no-op: an authored bend already sounded as
the curve.

**4** **Live recognition needs no standing record.** A live region
recognises its own seats by its own current window, in hand every rebuild,
and reconciles churn-free against the freshly computed curve by
`(ppq, val, shape)`. The absorber's back-derivation must **skip** in-window
pbs: a seat has no cents and must not acquire any, or it stops looking like a
seat. A *deleted* region's orphans are swept by a one-shot cleanup with the
bounds the delete site still knows — no persisted window mirror, which would
be redundant every rebuild the region lives.

**5** **Bounds are logical; convert once, compare raw to raw.** A region's
bounds are logical and its seats are raw-only — that absence is the win — so
the bounds convert once per `(chan, window)` and raw seat ppqs test directly
against a half-open `[startRaw, endRaw)`. This is exact by construction,
seats being placed by the same function that converted the bounds.
Round-tripping each *event* raw → logical instead, the inverse of seat
placement, is the shape to avoid. One predicate serves recognition and
coverage, on pb and cc alike.

**6** **The re-centre folds inward rather than the interval opening out.** A
pb window must return the channel to centre before it exits, and the tempting
seat for that is the window end itself. That would buy a closed interval for
pb alone, and the cost is not the special case but what it does to the end
row: recognition, the sweep and the CC walk all read that row as seat
territory, while coverage and the view's edit routing read it as authored. A
breakpoint landing there is claimed by both and protected by neither — it
loses its `ppqL`, drops out of the column, and goes with the next sweep. The
re-centre seats a tick inside instead, which is where it was always meant to
act, and a stage closing its own span on the end row folds inside as well.
The end row belongs to whatever is authored on it, so abutting windows are
disjoint in fact as well as in the test.

**7** **A generator cannot be trusted to close its own window.** The tempting
reading is that where a curve ends is the generator's own business: it
authored the shape, so it authors the shape's last point. Two of the three
continuous kinds behaved exactly so and said as much in their contracts. The
third did not — `lfo` closed on whatever phase the window happened to end on,
with `offset` on top, leaving the channel bent after its region for good.
That is action at a distance: an effect of the fx legible past the span the
fx owns. A promise two kinds in three keep is not an invariant, and nothing
downstream can tell which kind wrote the breakpoint it is holding.

**8** **So the machinery closes, and the generator does not.** The last tick
of every window carries the stream the stage *inherited*, evaluated at the
window end: what the target would read with no fx there at all. One
expression serves both fold modes, because both ask the same question of a
different stream — a replace hands back what it took over, an augment hands
back what it summed onto. The kind contracts stop being promises and become
consequences, and `lfo` is sealed without having to know it.

**9** **The handback costs a tick, and the tick comes from the stage.** A
stage's own material folds below the closing tick, and anything at or past
that line collapses onto the last tick inside it. Letting the close displace
whatever already sits on its tick looks cheaper and is not: a curve whose
geometry lives in its closing control point has that point eaten, and a lone
interpolated segment rising to its target flattens to a straight line at
nothing. The price of folding below instead is that the geometry compresses
by two ticks, which at the working resolution is not a quantity anyone can
hear, and would bite only on a window a few ticks long.

**10** **A parked value is handed back, not suppressed.** A pb region parks
the authored pbs it covers, which makes it tempting to close on centre, or on
detune alone — the parked value is not sounding, after all. But it is not
sounding *because of the fx*. To close on anything less would let the region
reach past its window and silence something authored beyond it, the same
action at a distance in the other direction. The criterion is the
counterfactual and nothing besides: past the window, the wire reads as it
would read with no region at all.

## Transitions and edges

**1** **Diff windows, don't mirror.** A markerless seat is invisible to the
park scan, so the scan cannot run every rebuild — it would re-park the seats.
It fires at the create and remove instants only: the current windows are
diffed against a RAM baseline and a one-shot transition staged for the next
rebuild to drain. A new window **parks** its authored events off-take, a
removed one **sweeps** its orphaned seats, and the queue is transient rather
than persisted.

**2** **The diff lives in tm rather than at the view's edit site, because the
edit site cannot see undo.** Take, regions and park stash revert atomically,
and REAPER's undo watcher delivers the rewind as a data change carrying
`invalidate`; the observer reads the flag and only resyncs its baseline,
enqueueing nothing — a stray sweep is exactly what would delete the
just-restored authored pb. Reload resyncs the same way, and on a plain remove
the parked authored restores on its own, being no longer covered.

**3** **cc drains earlier than pb.** The CC walk runs *before* the park, so
cc cannot park-then-recognise the way pb does. The same transition is staged,
but the walk drains it itself: a freshly created window is excluded from the
fill-recognition set, its authored ccs left in columns for the following park
pass to stash — recognising them as fill first would let the reconcile delete
them — and a removed window's orphans are deleted inline.

**4** **Swing at a boundary.** A seat is raw-only, so a swing change moves it
while its logical window stands still, and a seat within a few ticks of an
edge can land outside the current bounds and escape recognition. The channel
is flagged and its replace-target seats regenerated wholesale rather than
reconciled; churn on a swing change is acceptable.

**5** **Mixed kinds on a self-parked host.** A self-parked host can chain a
note-replace kind alongside a continuous one. Removing the last note-replace
kind un-parks the host as a note *in the same rebuild* the surviving
continuous kind still runs, so that kind's target window must keep
registering — otherwise the authored cc or pb it covers restores onto the
take and collides with the seats still being derived. The window pass
therefore registers on any surviving `spec.fx` rather than on the
note-parking predicate, which is true only while a note-replace kind is
present and would drop the window on exactly this frame.

## Multiplicity — pack, sum, layer

**1** Every output target folds overlapping contributions, and overlap is
well-behaved exactly when that fold is order-free. Notes **pack**: any number
of chains flow into free lanes, and two note-replace chains merge, sharing
the parked chord and packing into separate lanes. Augment continuous **sums**,
commutative and offline at seat time. Replace continuous has no commutative
fold, so it **layers**.

**2** Layering makes **storage order the precedence**: the later chain wins
pointwise in the overlap, a painter's algorithm — the same left-to-right fold
used within a chain, one level up. The tracker exposes that order as the fx
column's lane index, and the verbs that reorder it are `docs/trackerView.md`'s.

**3** Each per-chain continuous record therefore carries a mode — replace if
any dest-targeting stage replaces, else augment — and a target's records fold
in storage order from the authored base, an augment record adding its
base-relative delta and a replace record overwriting. Two replace curves on
one target layer rather than sum, which is what dissolved the old
one-replace-region-per-target guard.

**4** Overlapping regions with *differing* windows sub-split at every record
edge: between consecutive cuts the active set is constant, so each layer
folds only where it applies and an exclusive tail keeps its own curve. The
all-coincident case routes to the whole-span fold verbatim, so a same-window
replace emits its raw curve with no synthetic edge point. The conflict is
scoped per channel and *exact* target — distinct cc numbers are independent
wires.

**5** Continuous emission converts its windows at zero delay. The park scan,
the removal sweep and seat recognition all do, so delay-shifted seats would
orphan on removal — and doctrinally, delay is a per-note-on offset
(`docs/timing.md`) while a channel-wide curve has no note.

## pb and cc

**1** **pb as generator input is authored breakpoints only.** Their logical
value is the persisted `cents` sidecar, so the pre-producer walk reads it
directly — no cents-minus-detune reconstruction, no absorber split. A
foreign-MIDI pb lacks the sidecar for one rebuild until the absorber
back-derives and persists it, which is harmless and self-healing. The heavier
path, the absorber's densified stream as input, stays unbuilt until a kind
needs more than breakpoints.

**2** **A pb replace seats an absolute curve on the base lane.** The producer
records the replace window with its curve, and inside the window the stream
value is the *curve* rather than the authored breakpoints; the curve's
breakpoints become derived seats carrying their shape. An authored pb inside
the window rides the curve on its wire with its column cents untouched and
visible, and a curved segment split by a detune onset densifies exactly as an
authored one does. Two bounded artifacts come with it: the boundary from
authored base to curve can step, and a non-step authored pb inside the window
rides the curve in value while keeping its own outgoing shape over the next
cell.

**3** **cc reaches the same place by a slightly different route** — no
absorber, no detune residual. Augment sums offline and seats markerless as pb
does. Replace parks the authored cc off-take and writes the generated curve
as literal cc events on the target lane; the parked cc is re-seated for
display, so it stays the visible, editable surface and the fill never shows.
Creating a cc-replace region leaves the lane looking unchanged, and that is
the invariant.

**4** **Rest is the base when nothing is authored.** A cc-augment target with
no authored automation has nothing to sum onto, so the fold seeds from the
dest's resting value. Polarity is the controller's own and its default rest
says it: one resting mid-scale swings both ways, one at a rail only runs
inward. The base is per target and authored in the column — inside the window
or governing from before it — deliberately not a per-region field, so two
regions over one target cannot disagree about it.

## What the model does not express

**1** **PA replace** — a generator consuming and re-emitting a PA — has no
generic form. The input→output mapping preserves no event correspondence to
carry one across: an arp samples a chord and emits one stream, and which
input PA maps to which output note is undefined. Reading PAs as an input
stream is defined; rebinding them is not.

**2** Limits of the model are this section's subject. Behaviour that merely
surprises — a slide arriving late, a chain drawn nowhere until the caret
reaches it — is `docs/oddities.md`'s.

## Conventions

- **Periods are QN** per the `periodQN` convention — a scalar or `{num, den}`.
- **pb values are cents; cc values are the controller's own 7-bit numbers.**
  A param declared as a magnitude scales into whichever wire its dest names,
  which is what lets one kind serve every target.
- **The glyph set divides by what a kind touches** — a letter for one that
  shapes notes (`R` `T` `A` `O` `C` `V`), a wave mark for one that paints a
  continuous stream (`∿` sine, `/` slide, `~` lfo). Case would have drawn the
  same distinction and lost it: at one cell a letter against a squiggle
  survives where upper against lower does not.
- **A kind resolves through the registry's own accessors**, never by indexing
  it bare, so a kind the registry has lost draws `?` instead of faulting its
  caller — the mark a user-authored kind that failed to load would carry.
- **The registry is the only seam.** One entry per kind, and nothing
  downstream asks where an entry came from.
