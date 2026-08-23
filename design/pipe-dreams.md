# pipe dreams — designs we are deliberately not building

> opened: 2026-07-26 · status: standing collection; nothing here is queued
>
> A home for ideas settled enough to be worth writing down and
> deliberately not on any plan. Nothing here is queued, and nothing here
> should be started because it looks ready.
>
> Each entry says what it is, what it would cost, and — the part that
> earns its keep — **the obligation on today's work**: the small
> discipline that keeps the door open without building anything. An
> entry leaves this doc in one direction only, promoted into its own
> design doc when something real wants it.

## Param modulation — a stage that bends a sibling stage's parameter

> From `design/archive/note-macros-v2.md` § The chain surface. Read
> `docs/generators.md` § The chain first for the stream/stage/dest
> vocabulary this uses.

"Bend the vibrato rate in flight" generalizes `dest` once more:
`param:<stage>.<field>` — a continuous stage whose output targets a
sibling stage's parameter instead of a MIDI wire. Depth 1 only, the
modulator living inside the chain it modulates. That constraint is what
keeps it a comb rather than a graph: no modulator of a modulator, no
cross-chain reach.

It is the natural end of the transformer/source line the chain draws. A
transformer rewrites event *values* and nudges *discrete* timing; it
cannot coherently rewrite a continuous source's **rate**, because
vibrato's breakpoints are placed by accumulated phase and resampling
them loses coherence. So rate/period/phase stay source params — and
modulating a param is how you move one without resampling anything.

**The obligation now:** keep `dest` a clean single axis. Nothing else.

## Stepped feed — modulation's contract

A modulated param stops being a scalar and becomes a control signal, and
the contract must decide who integrates it over time. Handing bodies
`params:at(t)` leaves integration as per-author folklore — a closed-form
body under a varying param fails silently (vibrato's sine needs a phase
accumulator once `period` moves; the classic FM error).

The structural answer: the **runner drives the body through time** —
`expand(block, params, ctx, state)` — resolving modulators to *constant*
params per block and threading explicit state (vibrato: phase; arp: step
index; retrig: next fire). A block is just a **narrowed host** (window
shrunk, streams sliced), and a one-shot kind is a stepped kind run with
one block spanning the window — the same no-special-case-head move the
chain made when it retired the source/transformer role split.
Whole-window properties (vibrato's end-of-window re-centre) become runner
epilogues, not block business.

Blocks are **segment-driven, not fixed-size**: edges at the union of
modulator breakpoints and membership note-on/offs (sample-and-hold at the
modulator's own breakpoints — exact, no block-size/aliasing trade). With
membership edges in the cut, params *and* polyphony are block-constant —
a block is precisely an interval of constancy, and bodies go
straight-line: no scanning, no mid-block cases.

**Notes arrive as held + triggered.** Per block: `held` = sounding at
block start (onset before it), `triggered` = note-ons inside it. No
`released` set — every note carries `endppqL`, so gate-shaped bodies read
release edges off the events. The partition **tiles the membership**:
each note is triggered in exactly one block, held in every later block it
spans; union over blocks = today's overlap query. The degenerate
one-block case is *more* correct than the flat list (`playingAt` stops
being something arp implements and becomes `held ∪ triggered`, handed
in). Simultaneous onsets in `triggered` order by ascending realised pitch
so "first triggered" stays G4-stable; segmentation is a pure function of
the input streams, so determinism holds by construction. Cost stays
proportional to event count, all offline; the shape also mirrors the
node's per-block run one level up, and is streaming-ready if live feeds
(preview, plink) ever want it.

**The obligation now is a writing discipline only**, same register as the
ctx discipline: shape new continuous kinds *incrementally* — phase
accumulators and step loops, never closed forms over the window — so the
window can shrink without rewriting the body. Discrete kinds are already
step-shaped.

**When it lands, the build order writes itself:** segment cutter + state
threading in the runner, vibrato ported as the proving kind.

## Scripted kinds — a user-authored kind in a third editor pane

> From `design/archive/note-macros-v2.md` § The chain surface. Read
> `docs/generators.md` § The ctx discipline for what this rests on.

`generators.kinds` is already the seam. There is one registry entry per
kind, and nothing downstream asks where an entry came from, so a
user-authored kind is a Lua chunk evaluating to that same entry-shape and
the registry cannot tell it from a built-in. It would be edited in a
third editor pane beside swing and temper, riding `libraryTreeSpec`
whole — global/project tiers, promote/demote, new/import/delete, dirty
tracking — machinery that already models named, tiered, user-authored
artifacts and would gain a third artifact rather than a second shape.

The contract a script writes against is not a new one: it is the ctx
discipline. A scripted `expand` composes stream, host, params and the
named ctx ops, pure, with no reach into tm. That is what makes the idea
cheap rather than an interpreter project — a kind shaped this way is
already very nearly data, and the pane only has to load it.

What it would cost is that the registry stops being a constant. Loading
is eval-into-registry at startup and at library-save, so a kind can
arrive late, and a broken chunk has to degrade to its kind vanishing from
the registry with a status-bar complaint rather than a rebuild fault. The
readers are largely ready for that already, because a kind can go missing
by other means: `glyphOf` answers `?` for a kind the registry has lost,
and the fx tab resolves a lost kind through `labelOf` and draws the stage
as a heading alone (2026-08-08). What is untested is the load path
itself — a sandbox, an eval order, and a failure that must stay confined
to one entry.

**The obligation now:** hold the ctx discipline — new kinds as arithmetic
plus named ctx ops, ctx accreting as named operations and never as an
escape hatch into tm — and keep every reader of `generators.kinds`
tolerant of an entry that isn't there.

## Concert pitch in hertz — a reading, or an entry form

> From `design/archive/temper-root.md` § Open. Read `docs/tuning.md`
> § The root for the four fields this would sit beside.

A root is authored in cents, and concert pitch is thought about in
hertz. `(69, −101.27) = (10, 4)` is A=415 written the way the arithmetic
wants it rather than the way the ear asks for it. The editor could show
the hertz a root implies beside the fields, or take hertz as an entry
form and solve back to the detune.

What it costs is an anchor. Cents are a ratio and hertz are a frequency,
so a reading needs one absolute correspondence — MIDI 69 = 440 Hz — and
that correspondence is exactly the convention a root exists to make
editable. The figure would therefore be read against a nominal reference
the temper does not hold. Naming that reference in the pane is honest and
verbose; leaving it implicit invites reading the number as a promise
about what comes out of the synth.

**The obligation now:** the four authored fields stay the truth. A hertz
figure is derived at the pane and never persisted, so nothing downstream
has to learn what a reference frequency is.

## Typing a deviation — the readout as an entry form

> Read `docs/tuning.md` § Display for the readout this would make
> writable, and § The written step for the intent it would author.

The cell draws the cents a note stands off its step, and nothing types
that figure. A writable readout would author an intent directly — the
name held where it is and the sound bent away from it — which is a
gesture the editor does not offer today, a detune arriving from a step's
cents or from a solve.

How far notes actually drift decides whether an author wants it. Over
the five-part take at the dials' openings a strand stands 6.74¢ from its
seat on average and none stands past 11.15¢ (`docs/sonority.md` § What
it gives up), so the figures are small and the readout is mostly
confirmation.

**The obligation now:** the readout stays a reading of `(pitch, detune,
intentCents)` and takes no cursor stop, so nothing the cursor or the
clipboard holds has to move when one is offered.

## A class tied to one tuning — a fixed scale over a passage

> Read `docs/sonority.md` § The pull for the rest a strand relaxes
> against, and § The solve for where that rest is fixed.

A strand rests where the music stood when its note arrived, and
consecutive strands of one step-class rest independently of each other.
A spring between a class's own strands at a delta of nothing would hold
the class to one tuning across a passage, and its stiff end is a fixed
twelve-note scale.

Both ends of that were measured. Inside the search, at a stiffness of
eight every class does collapse to one tuning, and the pairs standing a
comma or more from a 5-limit interval rise from 41 to 50. Applied after
the spellings are chosen it splits the difference instead: one class's
spread falls from 26¢ to 17¢ while the chords' own springs go from 3.1¢
to 7.5¢ out, and no pair leaves the count. Those figures predate the
ambient rest, so they give the shape of the effect and not its size.

**The obligation now:** a strand's rest stays one frozen figure per
strand, which is what a class-wide tie would replace.

## A notational demand — the degree above whatever the host is

> Read `docs/generators.md` § The ctx discipline for why a derivation
> reads no notation, and `docs/trackerRender.md` for the two rows an
> interval takes.

A generator stores a cents demand, and the notation is the ladder the fx
strip walks when one is typed. "The degree above whatever the host is"
is a demand of another kind: a rule the notation answers rather than an
interval.

Re-reading such a rule on every rebuild is what the model forbids, a
temper change then re-sounding derived notes no author touched. So the
mode would resolve where the field is written, as a slide's target
chooses `Next` or `Fixed`, and what it stores is cents after all.
Nothing asks for it yet.

**The obligation now:** the interval field's stored value stays cents,
and the step ladder stays a reading of it.

## A per-placement overlay — one pattern, different each time it stands

> Read `docs/arrangeManager.md` § Variants for what a divergence costs
> today, and `docs/groupManager.md` § localMode for the routed override
> one level down.

Two pooled items are one source, so for one of them to differ a second
source has to exist — which is what `vary` mints. An overlay riding the
item instead, read at realisation — a transposition, a mute mask, a
macro depth — would let a placement differ while the source stayed
single. That is how one pattern stays one pattern across a whole song,
and it would collapse the fork and the repeat into one gesture.

The cost is a tier realisation does not have. Every rebuild reads the
take's events and the slot's metadata; the overlay adds a per-item
reading under both, and the tracker would then draw and edit a picture
that is no longer the pool's. That reaches well into the rebuild
pipeline for a divergence a fork already delivers.

**The obligation now:** divergence stays structural. A placement carries
a start QN and a rendered length and nothing else realisation reads, so
an overlay would be added rather than untangled.
