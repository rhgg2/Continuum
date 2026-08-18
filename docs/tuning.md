# tuning

Cross-cutting reference for pitch in Continuum: how a note's tuning is
*authored* (the coordinate system) and how it is *realised* (the
intent / realisation split). Also the API reference for `tuning.lua`,
the pure module that owns the coordinate-system layer.

The module is named `tuning`, after the word a musician would use. The
entity it operates on is called a **temper** in code, short for
*temperament* — a tuning system such as 12-EDO, 31-EDO, or a future
Just-Intonation lattice. The short form avoids prolixity at call sites;
it names the same thing.

## The pitch model

**1** Ask of a note *what pitch is that?* and two quite different
answers are in the offing. The trouble begins when one of them is given
to the other's question.

**2** The first answer **names** the pitch. The MIDI view names it
`(pitch, detune-in-cents)`; the scale view names it `(step, octave)`
under a temperament. `tuning.lua` converts between the two namings, and
holds no take state while doing it.

**3** The second answer says how the pitch is **delivered**. Detune is
the musician's intent, carried as per-note metadata. The channel-wide
pitchbend stream is the realisation — what REAPER stores, and what the
synth actually does. tm reconciles the two.

**4** These are orthogonal, and the orthogonality is load-bearing rather
than decorative. The temperament chosen for display does not change a
byte on the wire; a pb edit does not reach back and revise what the
musician meant. Where a system allows the second sort of thing, its
intents are not intents at all but a kind of residue.

## Intent vs realisation

**1** Three views of the same channel-wide cents line coexist:

- **Raw pb** — what REAPER stores on the wire: signed `-8192..8191`,
  centred on 0, channel-wide.
- **Logical pb** — what the musician authored: cents relative to
  prevailing detune. The smooth stream the user "drew."
- **Detune** — per-note metadata, signed cents.

**2** The tempting reading is that raw and logical are two quantities
standing in a relation. They are not. There is one quantity under two
descriptions, and the identity below is a rule for passing between the
descriptions rather than a conversion between things:

```
logical(chan, ppq) = raw(chan, ppq) − detune(chan, ppq)
```

where `detune(chan, ppq)` is the detune of the latest lane-1 note
starting at or before `ppq` (0 if none).

**3** Every note carries a `detune` field, but pb is channel-wide where
a note column is not. Only *one* note column per channel can drive
tuning realisation, and by convention that is **lane 1**, the first note
column of the channel. The choice is arbitrary in origin and not
arbitrary now: everything downstream is built on it.

**4** Higher lanes' detune values are still stored, and display layers
like the temperament lens consult them. They do not reach the pb stream.
A higher lane simply inherits whatever bend is in force at its onset.

### The fake-pb absorber

**1** When a lane-1 note's detune differs from the detune prevailing
just before it, a step enters the raw stream at the note's seat. Left
alone, that step surfaces in the logical stream too, and the musician
sees a jump she did not draw.

**2** So a pb seats at the note boundary and takes the step onto itself:
raw moves, logical does not. That pb is tagged `fake=true`, persisted as
cc metadata, and hidden from the pb column unless an interp shape pulls
it into view.

**3** Nothing is being counterfeited — *derived* is what the rest of the
system calls the same property. The pb is fake in virtue of its
provenance, not its constitution: on the wire it is an ordinary
pitchbend, indistinguishable from an authored one. That is why the tag
is persisted rather than recomputed. The wire cannot remember why
anything is on it.

**4** The absorber invariant runs in **both directions**, and it is the
second that gets forgotten:

- **Detune jump at a note seat ⇒ a fake pb seats at that seat.**
  Without it, a step in the raw stream surfaces as a step in the
  logical stream. Keeping logical smooth across detune changes is the
  whole point of the absorber.
- **No detune jump at a seat ⇒ no fake pb at that seat.** A stale
  absorber is not inert. It goes on absorbing a step that is no longer
  there.

**5** Mutations therefore reconcile both ends: "drop redundant" and
"seat missing" both run after every detune mutation that crosses the
seat. The implementation lives in tm's `reconcileBoundary`; see
`docs/trackerManager.md` for the call sites.

### Orthogonality

**1** The view layer above the realisation line never touches pb
directly. Detune drives pb seating; pb does not drive detune. Editing a
lane-1 note's detune seats, removes or shifts absorbers, and tm handles
it. Editing a pb event does not retro-mutate detune.

**2** That direction is what keeps detune durable as intent. Re-temper,
re-render and re-export all fall out cleanly from intent plus
realisation, because the intent survived the realisation.

**3** It also keeps the *realisation mechanism itself* swappable. pb is
the current implementation, not the model — MTS (MIDI Tuning Standard)
is the obvious candidate to substitute beneath the intent line without
disturbing anything above it. Each mechanism brings its own limitations:

- **pb** is channel-wide and single-voice, so only lane 1 contributes
  to realisation. A lane-2 note with `detune ≠ 0` displays as its
  microtone via the temperament lens and sounds at ambient pb.
- **MTS** retunes the 128-pitch grid rather than extending it: each
  scale step has to be assigned to a MIDI pitch, so a cluster of
  microtones near the same pitch forces an artificial allocation
  across neighbouring MIDI numbers — and those neighbours then can't
  be played at their nominal tuning simultaneously.

**4** The point of the orthogonality is that those limits live entirely
below the intent line. Concretely:

- vm authoring sets `(pitch, detune)` on a note; pb realisation is
  tm's job.
- Inside tm's `um`, `pb.val` is **always cents**; conversion to raw
  happens only at load (`rawToCents`) and at flush (`centsToRaw`).
  The cents window is `cm:get('pbRange') * 100` per side.
- mm holds raw pb only — it has no notion of detune. The raw/cents
  conversion is tm's boundary, parallel to tm's role on the timing
  side (see `docs/timing.md`).

### Invariants

The realisation layer's contract with everything above it. These
hold for every channel `c` and every ppq `P`, after every mutation:

- **I1 — Identity.** `logical(c, P) = raw(c, P) − detune(c, P)`,
  where `detune(c, P)` is the detune of the latest **lane-1** note
  onset at-or-before P.
- **I2 — Absorber, both directions.** At every lane-1 note seat S:
  - `detune(c, S) ≠ detuneBefore(c, S)` ⇒ ∃ pb at S (real or fake).
  - `detune(c, S) = detuneBefore(c, S)` ⇒ no **fake** pb at S —
    except the channel's first lane-1 onset (see I2a).
    Real pbs are user-authored and never deleted by reconciliation.
- **I2a — First-note anchor.** On a channel whose pb stream is ever
  non-trivial (some detune jump, or a real pb), the first lane-1 onset
  carries a pb (real or fake) even when its detune equals the implicit
  0 baseline. The reason is that the absence of a pb is not an
  assertion of zero: before the first pb the take says nothing, and
  playback inherits the synth's unknown prior bend. A pristine all-zero
  channel with no pb needs no anchor — there, saying nothing is safe,
  because nothing has been said either way.
- **I3 — Lane-1 monopoly.** Adding, editing, or deleting a
  lane-≥2 note never seats, removes, or moves any pb. Higher-lane
  detune is dead data *for realisation* and live for display; it
  persists as metadata so display layers and future lane-promotion
  paths can read it back.
- **I4 — Orthogonality.** Editing a pb never mutates any note's
  detune; editing a note's detune never demotes a real pb to fake
  nor seats a real pb. Detune drives pb seating; pb does not drive
  detune.
- **I5 — Cleanliness.** No two pbs share `(chan, ppq)`. Fake pbs
  exist only at lane-1 seats that have a detune jump.

I1-I5 are mechanism-independent: any future realisation layer (MTS
in place of pb, etc.) inherits the same contract entire. That is what
it is for a contract to be held with the layer above rather than with
the wire. Tests pin them by number in `tests/specs/tm_tuning_spec.lua`.
tm-specific contracts that fulfil these — frame, delay, persistence —
live in `docs/trackerManager.md`.

## Coordinate systems

**1** Two views on the same cents line:

- **MIDI**: `(pitch, detune)` — pitch in 0..127, detune in cents.
- **Scale**: `(step, octave)` — step is 1-indexed into `temper.cents`.

**2** The temper's **root** is the correspondence between them: it names
one `(pitch, detune)` and the `(step, octave)` that sounds there, and
every other pair follows from that one by the period. So the anchor is
authored rather than fixed — see *The root*.

**3** The default root is `(0, 0) = (1, -1)`: MIDI 0 is the unison of
octave -1. An unrooted temper therefore puts its unison on `C-1` and
numbers its octaves in the ASCII-MIDI convention (C4 = MIDI 60).

**4** A root moves both. Under `(69, 0) = (1, 4)` the unison of a 12-EDO
scale sounds A4, and MIDI 60 reads `D#3`.

## Temper shape

```
temper = {
  name        = '31EDO',
  pitches     = { '0\31', '1\31', ... }, -- source tokens, ascending; one per step
  periodPitch = '2/1',                   -- source token for the period (equave)
  stepNames   = { 'C-', 'C↑', ... },     -- one per step ('' = nameless → degree)
  periodAsStep = false,                  -- display: show the period as a trailing row?
  rootPitch   = 69,                      -- root: MIDI pitch of the correspondence (absent = 0)
  rootDetune  = -101.27,                 -- root: cents offset on that pitch (absent = 0)
  rootStep    = 10,                      -- root: the step it names (absent = 1)
  rootOctave  = 4,                       -- root: the octave it names (absent = -1)
  cents       = { 0, 39, 77, ... },      -- DERIVED from pitches by tuning.derive
  period      = 1200,                    -- DERIVED from periodPitch
  rootCents   = <cents>,                 -- derived; where the unison sits in sound
  octaveBase  = <octave>,                -- derived; the octave number for period-index 0
  octaveStep  = <index>,                 -- derived; see below
  octaveWidth = <chars>,                 -- derived; octave-field width within the cell
  cellWidth   = <chars>,                 -- derived; tracker pitch-cell width
}
```

### Intensional source: pitch tokens

**1** `pitches`/`periodPitch` are the editable truth; `cents`/`period`
are a derived cache that `tuning.derive` recompiles on every edit.

**2** The distinction earns its keep because `9/8` and `203.910` pick
out the same cents value and do not say the same thing. The first says
*a just major second*, and says it exactly. The second says a number,
and carries a rounding error. Keeping the token keeps what the number
lost.

**3** The realisation layer reads only the derived `cents[]` — it never
sees a token. A **pitch token** is one line of the Scala pitch grammar:

| token | meaning |
|---|---|
| `9/8`, `2` | ratio (bare integer = `n/1`) |
| `204.0` | cents (a decimal point present) |
| `7\31` | 7 steps of 31-EDO (`n*1200/m`) |

**4** `tuning.scalaPitch(token)` compiles one token to cents (or `nil`
if it doesn't parse). `edo(n, names)` emits `n\m` tokens rather than
rounded cents, so the EDO presets are editable as intensional steps;
their cents are now the exact `n*1200/m`, not the historic rounded
integers.

### Scala import

**1** `parseScalaPitches` (lenient: one token per non-comment line) and
`parseScalaFile` (strict `.scl`: description, count, then pitches) both
feed `scalaToTemper`.

**2** Its work is reconciling two conventions. Scala leaves the unison
tacit and lists the period last; we state the unison and hold the period
apart. So the bridge prepends `1/1` and splits the final pitch off into
`periodPitch`.

**3** That is the shape every translation between conventions has:
something the source thought too obvious to state must be stated, and
something it stated in passing must be given a place of its own. Imports
default to `periodAsStep = true` so they read top-to-bottom like the
source file.

### The `octaveStep` derivation

**1** Some temperaments have steps near the end of the period whose note
name is enharmonically the *next* C (`C↓` in 31EDO, `C↓` in 53EDO).
Arithmetically those steps sit inside the period; by label convention
they belong to the octave above. Here the name governs and the number
yields, which is the right way round — the octave label is a fact about
how musicians read, not about how cents accumulate.

**2** `octaveStep` is the first step index from which the bump applies.
It is auto-derived by scanning `stepNames` from the end for the last
non-C name: every step past it is a C-variant that reads as the next
octave. The derivation lives next to the temperament table so the two
cannot drift apart.

**3** A nameless scale has no C-tail, so the bump sits at the period
(`octaveStep = #cents + 1`, never reached by a real step). `stepToParts`
adds 1 to the displayed octave when `step >= octaveStep`.

### The root

1. `rootPitch`, `rootDetune`, `rootStep` and `rootOctave` state where
   a temper's root sits in sound and which MIDI octave carries it,
   authored where a preset states them and defaulting to `(0, 0) = (1,
   -1)` — MIDI 0 at the unison of octave -1 — where absent, which is
   the arithmetic an unrooted temper already assumed.

2. `tuning.derive` reduces the four into `rootCents` (the unison's
   cents position) and `octaveBase` (the octave number for
   period-index 0), read by `midiToStep`/`stepToMidi` in place of the
   constants they replace. The four authored fields are read through,
   never written back, so presets keep the shape they were written in.

3. The root names a step, so a step edit carries `rootStep` with the step it
   names: a deletion below it, or a sort that moves it, leaves it on the same
   step sounding what it sounded. Deleting the rooted step is the one edit with
   no successor — there the root restates on the unison at the `rootCents`
   standing before the edit, which is the same tuning written at the step every
   scale keeps. A generator replaces the scale the root placed, so it resets the
   root to the default.

4. Root state is project-tier. The library form of a temper — what
   `tuning.unrooted` computes, and what publishing writes — drops the four
   and re-derives at the default root, so the library holds a scale and a
   project holds a scale placed. Divergence from a library source is
   measured on the scale alone.

5. The editor clamps `rootPitch` and `rootStep` on entry, since they derive
   indexes into the scale; `rootOctave` and `rootDetune` are left free, since
   an out-of-range value only moves the root's display label, not which
   pitch it names. The root picker spells `rootPitch` in the untempered
   twelve names (sharps, signed octave) — deliberately not the tracker's
   `-`-marked naturals, since the temper's own naming is the thing a root
   fixes and so can't be used to name the root itself.

### Snapping and clamping

- `midiToStep` snaps to the nearest scale point **including the period
  boundary**: step 1 of the next period sits at `cents = period`, so a
  near-boundary input rounds to step 1 of `octave+1` rather than the
  last step of the current octave.
- `stepToMidi` wraps out-of-range step indices by adjusting octave,
  then **clamps the resulting MIDI note to 0..127** by folding the
  overflow into detune. A very-low step does not silently disappear: it
  is pressed against the floor and the remainder is carried as detune,
  so the call returns `(0, <large negative detune>)`.

### Addressable range

**1** The addressable range is the MIDI range: a note is *addressable*
only while the cents it sounds at sit in `[0, 12700]`, MIDI 0 to MIDI
127, at the fixed slope 100¢ = 1 semitone.

**2** Which `(step, octave)` coordinates fall inside it is the root's
doing, since the root moves both the pitch the unison sounds and the
number the octave carries. That is why the octave field is sized from
`rootCents` and `octaveBase` at either end — see *Display*.

**3** The pitchbend window (`pbRange`) can bend the *sound* a little
past either end, but the note's own `(step, octave)` cannot follow it:
below MIDI 0 and above MIDI 127 there is no coordinate to move to.

**4** A seated note's detune is always in `[-50, 50]` (it is
`cents − round(cents/100)·100`), and only a clamp-fold past the floor or
the ceiling pushes `|detune|` beyond 50. That makes `|detune| > 50` a
serviceable criterion for *this result has left the range*, and it is
what both the octave-column entry and the pitch **nudge** test.

**5** They reject rather than clamp, and the note stays put. An
unaddressable pitch is not a quieter pitch but no pitch at all here, so
drifting onto one is worse than refusing to move. Editing operations
enforce this, so the range — and the `cellWidth` octave budget derived
from it — stays exact.

## A temper read as moves

**1** A temper whose every pitch is a ratio reads two ways, and
`tuning.isTarget` passes it either way. As **points** it is a scale, its
pitches sitting on the pitch line wherever a key puts its `1/1`; as a
**move set** it is a collection of intervals that may be sounded between
two notes, its `1/1` being wherever a move departs from rather than a
pitch of its own. Nothing in the object says which reading was meant, so
the retune command carries the choice as a slot of its own
(docs/trackerView.md § Retune). Partch's diamond is a table of intervals
from a `1/1`, and reading it as a move set is closer to what it is than
reading it as a scale.

**2** `tuning.moves` compiles the second reading: each pitch and its
inversion, cents reduced into the octave, carrying the **coords** — the
exponents of the odd primes — that name the interval. Coords fix a ratio
up to the octave, so they identify a move outright and a temper's two
spellings of one move collapse: a generator stating its points over a
common root emits `9/6` where another emits `3/2`, and the set holds one
move either way.

**3** Complexity is **octave-free Tenney height**: the base-2 logarithm
of the product of the odd parts of a ratio's two terms, which
`tuning.height` sums off the coords as `Σ |exponent| × log₂ p`. Reading
it off the coords rather than off the terms is what makes an unreduced
token cost the interval it sounds — `9/6` read literally is 4.75, against
the 1.58 the fifth sounds. An inversion reads what the move reads, `5/4`
and `8/5` both at 2.32, so it sorts beside it; the set sorts simplest
first, and its last move states the **complexity bound**, the most
complex interval it holds.

**4** Height is what a chain spends, where odd limit is what a point
costs. Two `5/4`s are odd limit 5 apiece and `25/16` is odd limit 25,
where the heights are 2.32 apiece and 4.64 together, which is exactly
`25/16`'s. The same measure scores the result: a sonority's box is the
Tenney height of its octave-free `lcm/gcd` (docs/sonority.md § The box),
so one figure both bounds what a solve may join with and prices what it
reaches.

## Display

```
C-4 / 7-4 / 12-1               -- pitch-cell labels
```

**1** A step renders as its name plus the octave (`C-4`). A **nameless
step** — one whose `stepNames` entry is blank — falls back to its degree
with a dash separator (`7-4`), reusing the named cell's shape: *the
seventh step* does the work the name would have done, in the same number
of columns. A **negative octave** renders as its magnitude, tinted in
`colour.tracker.negative` (so MIDI 0 reads `C-1` with a tinted `1`,
against `C-4` for MIDI 60), which is what the delay lane already does
with a negative offset: the sign costs no column, and a temper root puts
octaves below -1 in reach, where a one-off like `M` has no answer.

**2** In the tracker cell the note and octave are each **right-aligned
within their own field** — the note in the left `cellWidth -
octaveWidth` columns, the octave in the right `octaveWidth` columns.
`tuning.stepToParts` exposes the two parts, and the negativity the octave
is tinted by.

**3** So the separator and the octave's units digit each keep a fixed
column across rows, even where octave labels vary in width (a sub-octave
period mixing single- and double-digit octaves). The reader scans a
column downward, and a separator that shifts between rows breaks the
scan with nothing to mark where it broke.

**4** The octave cursor stop (cell column `cellWidth-1`) lands on the
units digit, and a field wide enough to need them takes one stop per
place (`docs/editCursor.md` § Decoration). The note-entry stop (column
`0`) is a keyboard affordance rather than a reading position, so it may
sit on left padding for a short label without harm.

**5** `cellWidth` is the derived char width of the widest label: the
longest name (or a 2-digit degree) plus the **octave field**. The field is
sized on the octave numbers at the two ends of the range — the bottom
`floor(-rootCents / period) + octaveBase`, the top `floor((12700 -
rootCents) / period) + octaveBase` — and as magnitudes either end may be
the wider, because the root moves both the pitch the range starts at and
the number that octave carries.

**6** At the default root the bottom is `-1` and the top is `floor(12700 /
period) - 1`: 12-EDO and the other octave-period presets derive 3, and a
**sub-octave period** — more than ten period-cycles in the MIDI range —
widens the field to two digits. A root can widen the bottom past that, and
can equally narrow a sub-octave scale by numbering the octaves it spans
closer to zero. The budget is exact only because edits keep notes in
range — see *Addressable range*.

## Slot registry

Mirrors the swing model in `docs/timing.md`:

- `tuning.presets` is **seed-only** — never consulted at slot
  resolution time. Its role is to populate the UI's "copy into
  library" menu.
- The runtime library lives in `cfg.tempers` at project scope; slots
  in `cfg.temper` reference temperaments **by name only**.
- `findTemper(name, userLib)` resolves only within the userLib. A
  missing name or missing lib returns nil, and callers treat nil as
  "no temperament" — a determinate answer, not a failure to answer.

## Absorber reconciliation

The absorber pass of `trackerManager` runs after the tail walk finalises
lane-1 raw ppqs (same-pitch onset clamps, delay/clamp combinations that
reorder hosts) and after externals are placed. The ordering is forced: a
seat is a position, and a position cannot be fixed while the things it
sits between are still moving.

From the final realised lane-1 sequence it:

- Back-derives cents for any pb missing it (foreign-MIDI / first load):
  `cents = rawToCents(wire) − detune` at the pb's seat.
- Covers every detune-jump seat: a real pb at that ppq counts;
  otherwise reuse an existing fake if any (in-place first, else move),
  else create a new fake.
- Anchors a pb-active channel at its first lane-1 onset (even detune 0)
  unless a real pb already pins it at-or-before (I2a).
- Drops fakes whose seat is no longer needed.
- Skips frozen fx channels entirely: freezing already wrote their
  derived output into mm with absorber seats carried, so the dirty gate
  reads them clean and this pass never runs for them.
- Writes wire raw = `centsToRaw(cents + carrying lane-1 detune)`.
- Projects the pb column from the final set, with `val=cents` (the
  authored value tv displays) and `hidden` for every derived seat.

Reads pbs directly from mm; the um cache (`chans`, `byUuid`) is
rebuilt at the end-of-rebuild `reload()`.

### Seat-span-scoped onset walk

**1** Under interval dirt (`design/archive/interval-dirt-v2.md` § 3) the
detune-onset walk is scoped to disjoint seat spans rather than the whole
channel. Each span seeds its running `prev` from the detune carried in
from just before it (`lane1DetuneAt` at `span[1] - 1`), so a jump
entering a span from outside is still caught without re-walking the
untouched lane-1 ahead of it. A window may be small provided it knows
what it is a window onto.

**2** A note without authored detune reads 0 — ingestion's default on
the cell. An ungated call (`seatSpans == nil`, dirty-wholesale channels)
walks `{0, math.huge}`: the whole channel, same as before scoping.

**3** Spans are coalesced to disjoint ascending order first
(`mergeSpans`) because the seats table is written by overwrite while a
dual point seats one tick *below* its onset. With onsets out of
ascending order, one onset's dual point can clobber the seat belonging
to the onset just before it.

**4** The clobber leaves no trace. Both writes produce a well-formed
`{cents, ppqL, shape}` record, and only which of them landed second
tells them apart.

### Authoring onto a hidden seat

**1** Pitchbend is one value per tick, so two pb events at one
(chan, ppq) are not a hard case to adjudicate — they are a contradiction
on the wire whatever names them.

**2** An anchored or detune-seated onset already holds a hidden absorber
pb, and the projection hides it, so the pitchbend cell reads empty.
Authoring there must therefore **adopt** that seat: `addEvent` seeks
`chans[chan].pbs` for a pb at that onset and assigns it (new cents,
`derived` cleared) rather than pushing a rival.

**3** Pushing a rival was the "stuck after the first digit" bug. Back
when mm addressed by content key the two pbs shared a token, so the
reconcile's delete removed the authored one and the cell snapped back to
the seat's value — the user typing into a field that kept forgetting.
Adopting also reuses the seat's uuid sidecar instead of orphaning it.

### Value-aware seats and densification

**1** A seat is no longer value-blind. It samples the **prevailing
authored pb value** at its ppq (`streamValue` — interpolate between the
bounding breakpoints, hold the last past the end, 0 before the first)
and adds detune.

**2** The old `cents=0` discarded any authored value passing through the
seat, so you could not interpolate or hold a pb across a detune onset;
now the seat carries it. The two-number pb breakpoint (display `cents`
vs wire raw) is what lets the column still show the user's sparse
authored shape while the wire carries the realisation.

**3** How a seat realises depends on whether the authored value *ramps*
across the onset:

- **Flat / held / no stream** — a lone **step** seat holds the
  prevailing value and steps detune at the onset. This is the common
  pure-detune case; the value-aware machinery is inert (`streamValue`
  is 0 or a constant).
- **Ramps (sloped or curved segment)** — the seat must ride
  **linearly** so the curve tracks through it, so the detune step can
  no longer be the seat's own shape. It splits onto a **dual point**: a
  just-before seat carrying `streamValue(onset) + old detune` and an
  at-onset seat carrying `streamValue(onset) + new detune`. The curve
  rides through both; detune jumps between them, never smeared across
  the preceding cell.
- **Curved segment under an onset** — REAPER's fixed-tension shapes
  cannot be split at an arbitrary point, so a curve that cannot be cut
  is re-said as a chain of small straight ones: derived seats on a
  fixed grid (step = `resolution / CCINTERP` ticks — `CCINTERP` is
  interpolated points per QN, the density REAPER itself linearizes CC
  at) sampling the curve. Each segment misstates the curve a little and
  the chain of them is true enough to sound. The grid is fixed rather
  than curvature-adaptive, and keyed on the stable authored ppqs,
  because adaptive points would move between rebuilds and churn (the
  canon-ppq lesson): a description that comes out differently each time
  it is given is not yet a description. A curved segment with no
  interior onset rides REAPER's native shape untouched.

**4 Replace curves ride the same seats.** A pb-replace generator's
absolute curve is seated here, not on an additive carrier. Inside a
replace window `streamValue` returns the *curve* (interpolated over the
generator's breakpoints); the breakpoints become derived seats carrying
their shape, and a curved curve-segment split by a detune onset
densifies exactly as an authored one does.

**5** Authored pbs the window covers **park off-take** (the unified
`fxParked` stash, `evType='pb'`) so every on-take pb in the window is a
derived seat — exclusive ownership. They stay visible in-column via the
`parkedPb` render union and restore to the take when the region leaves.
Each wire raw is `centsToRaw(curve + detune)` — no carrier, no add-bank
slot. See `docs/generators.md` § pb and cc.

**6 In-window seats are markerless.** A replace seat writes native MIDI
only (`{ppq, val, shape}`), so `addCC` mints no uuid and no `eventMeta`
sidecar — a dense curve costs zero metadata.

**7** Recognition is then purely by region: exclusive ownership means
every on-take pb inside a live window is a seat, so `inSeatWindow` (raw
bounds, inclusive of `endRaw` for the terminal re-centre) classifies a
loaded markerless pb as a seat and tags `derived='absorber'` in RAM
only. The criterion has moved from the thing to its situation, which is
available only where the situation has exactly one owner: detune
absorbers *outside* any window have no such owner, so they keep their
marker + cents sidecar.

**8** The create/remove transition — park authored in, sweep seats out —
is diffed by tm's `fxRegions` observer, not carried as a standing
record. See `docs/generators.md` § Route-by-window. Origin and the
replace path (generator curves reusing the same seats):
`design/archive/pb-interpolation.md`.

## Conventions

- **Octave param is MIDI-relative** (C4 → 4, C-1 → -1), not
  period-index. Conversions between the two live inside this module;
  callers see MIDI octaves.
- **All `tuning.lua` functions are pure.** The temper is passed in;
  there is no module-level current temper, and so no question of whose
  it is. vm/tm read `cm:get('temper')` and forward it.
- **Step naming is optional.** A named step displays as name+octave; a
  blank name falls back to its degree (Option B). `octaveStep` and
  `cellWidth` derive from the names — `tuning.derive` restamps both on
  every cents/name edit.
- **Detune is cents** throughout (never raw 14-bit). Conversion to
  raw pb happens only inside tm's flush boundary.
