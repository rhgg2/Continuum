# tuning

Cross-cutting reference for pitch in Continuum: how a note's tuning is
*authored* (the coordinate system) and how it is *realised* (the
intent / realisation split). Also the API reference for `tuning.lua`,
the pure module that owns the coordinate-system layer.

The module is named `tuning` (matching the user-facing word). The
entity it operates on is called a **temper** in code (short for
*temperament*) — a tuning system such as 12-EDO, 31-EDO, or a future
Just-Intonation lattice. The shorter form avoids prolixity at call
sites without losing precision in headings and comments.

## The pitch model

Pitch in Continuum splits into two concerns that don't contaminate each
other:

- **Coordinate system** — how a note's pitch is *named*. The MIDI
  view is `(pitch, detune-in-cents)`; the scale view is
  `(step, octave)` under a temperament. `tuning.lua` converts
  between them; this is a pure layer with no take state.
- **Intent vs realisation** — how a note's tuning is *delivered*.
  Detune is the musician's intent (per-note metadata); the
  channel-wide pitchbend stream is the realisation (what REAPER
  stores and plays). tm reconciles the two.

These layers are orthogonal. The temperament chosen for display does
not change what's stored on the wire, and a pb edit does not retro-
mutate a note's authored detune.

## Intent vs realisation

Three views of the same channel-wide cents line coexist:

- **Raw pb** — what REAPER stores on the wire: signed `-8192..8191`,
  centred on 0, channel-wide.
- **Logical pb** — what the musician authored: cents relative to
  prevailing detune. The smooth stream the user "drew."
- **Detune** — per-note metadata (signed cents). Every note carries
  a `detune` field, but pb is channel-wide so only *one* note column
  per channel can drive tuning realisation; by convention that is
  **lane 1** (the first note column of the channel). Higher lanes'
  detune values are still stored — and consulted by display layers
  like the temperament lens — but they don't contribute to the pb
  stream. Higher lanes simply inherit whatever pb is in force.

The relationship between the two pb views is

```
logical(chan, ppq) = raw(chan, ppq) − detune(chan, ppq)
```

where `detune(chan, ppq)` is the detune of the latest lane-1 note
starting at or before `ppq` (0 if none).

### The fake-pb absorber

When a lane-1 note's detune differs from the prevailing detune just
before it, a pb must seat at the note boundary to absorb the raw
step while keeping the logical stream unchanged. That pb is tagged
`fake=true` (persisted as cc metadata) and is hidden from the pb
column unless an interp shape pulls it into view.

The absorber invariant — **both directions**:

- **Detune jump at a note seat ⇒ a fake pb seats at that seat.**
  Without it, a step in the raw stream would surface as a step in
  the logical stream too. The whole point of the absorber is to
  keep logical smooth across detune changes.
- **No detune jump at a seat ⇒ no fake pb at that seat.** Stale
  absorbers are noise; they survive only as long as they are
  needed.

Mutations reconcile both ends bidirectionally — "drop redundant" and
"seat missing" both run after every detune mutation that crosses the
seat. The implementation lives in tm's `reconcileBoundary`; see
`docs/trackerManager.md` for the call sites.

### Orthogonality

The view layer above the realisation line never touches pb directly.
Detune drives pb seating; pb does not drive detune. Editing a lane-1
note's detune seats / removes / shifts absorbers (tm handles this);
editing a pb event does not retro-mutate detune.

This keeps detune as the durable intent: re-temper, re-render, or
re-export from intent and realisation falls out cleanly. It also
keeps the *realisation mechanism itself* swappable. pb is the
current implementation; another mechanism — MTS (MIDI Tuning
Standard) is the obvious candidate — could substitute beneath the
intent line without disturbing anything above it. Each mechanism
brings its own limitations:

- **pb** is channel-wide and single-voice, so only lane 1
  contributes to realisation. A lane-2 note with `detune ≠ 0`
  displays as its microtone via the temperament lens but sounds at
  ambient pb.
- **MTS** retunes the 128-pitch grid rather than extending it: each
  scale step has to be assigned to a MIDI pitch, so a cluster of
  microtones near the same pitch forces an artificial allocation
  across neighbouring MIDI numbers — and those neighbours then can't
  be played at their nominal tuning simultaneously.

The point of the orthogonality is that those limits live entirely
below the intent line.

Concretely:

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
  0 baseline. Without it the take has no pb before that note and
  playback inherits the synth's unknown prior bend. A pristine all-zero
  channel with no pb needs no anchor.
- **I3 — Lane-1 monopoly.** Adding, editing, or deleting a
  lane-≥2 note never seats, removes, or moves any pb. Higher-lane
  detune is dead data for realisation; it persists as metadata so
  display layers and future lane-promotion paths can read it back.
- **I4 — Orthogonality.** Editing a pb never mutates any note's
  detune; editing a note's detune never demotes a real pb to fake
  nor seats a real pb. Detune drives pb seating; pb does not drive
  detune.
- **I5 — Cleanliness.** No two pbs share `(chan, ppq)`. Fake pbs
  exist only at lane-1 seats that have a detune jump.

I1-I5 are mechanism-independent: any future realisation layer (MTS
in place of pb, etc.) inherits the same contract. Tests pin them by
number in `tests/specs/tm_tuning_spec.lua`. tm-specific contracts
that fulfil these — frame, delay, persistence — live in
`docs/trackerManager.md`.

## Coordinate systems

Two views on the same cents line:

- **MIDI**: `(pitch, detune)` — pitch in 0..127, detune in cents.
- **Scale**: `(step, octave)` — step is 1-indexed into `temper.cents`.

Cents 0 corresponds to `C-1` (MIDI 0). The first step of every
temperament is `C`. Octave labels follow the ASCII-MIDI convention
(C4 = MIDI 60).

## Temper shape

```
temper = {
  name        = '31EDO',
  pitches     = { '0\31', '1\31', ... }, -- source tokens, ascending; one per step
  periodPitch = '2/1',                   -- source token for the period (equave)
  stepNames   = { 'C-', 'C↑', ... },     -- one per step ('' = nameless → degree)
  periodAsStep = false,                  -- display: show the period as a trailing row?
  cents       = { 0, 39, 77, ... },      -- DERIVED from pitches by tuning.derive
  period      = 1200,                    -- DERIVED from periodPitch
  octaveStep  = <index>,                 -- derived; see below
  octaveWidth = <chars>,                 -- derived; octave-field width within the cell
  cellWidth   = <chars>,                 -- derived; tracker pitch-cell width
}
```

### Intensional source: pitch tokens

`pitches`/`periodPitch` are the editable truth; `cents`/`period` are a
derived cache that `tuning.derive` recompiles on every edit. The
realisation layer reads only the derived `cents[]` — it never sees a
token. A **pitch token** is one line of the Scala pitch grammar:

| token | meaning |
|---|---|
| `9/8`, `2` | ratio (bare integer = `n/1`) |
| `204.0` | cents (a decimal point present) |
| `7\31` | 7 steps of 31-EDO (`n*1200/m`) |

`tuning.scalaPitch(token)` compiles one token to cents (or `nil` if it
doesn't parse). `edo(n, names)` emits `n\m` tokens rather than rounded
cents, so the EDO presets are editable as intensional steps (their cents
are now the exact `n*1200/m`, not the historic rounded integers).

### Scala import

`parseScalaPitches` (lenient: one token per non-comment line) and
`parseScalaFile` (strict `.scl`: description, count, then pitches) both
feed `scalaToTemper`, which bridges the two conventions: Scala omits the
unison and lists the period last, so it prepends `1/1` and splits the
final pitch off into `periodPitch`. Imports default to
`periodAsStep = true` so they read top-to-bottom like the source file.

### The `octaveStep` derivation

Some temperaments have steps near the end of the period whose note
name is enharmonically the *next* C (e.g. `C↓` in 31EDO, `C↓` in
53EDO). Those steps belong to the octave above by label convention.

`octaveStep` is the first step index from which this octave bump
applies. It is auto-derived by scanning `stepNames` from the end and
finding the last non-C name — every step past it is a C-variant that
reads as the next octave. Derivation lives next to the temperament
table so the two stay in sync. A nameless scale has no C-tail, so the
bump sits at the period (`octaveStep = #cents + 1`, never reached by a
real step).

`stepToText` adds 1 to the displayed octave when `step >= octaveStep`.

### Snapping and clamping

- `midiToStep` snaps to the nearest scale point **including the period
  boundary**: step 1 of the next period sits at `cents = period`, so a
  near-boundary input rounds to step 1 of `octave+1` rather than the
  last step of the current octave.
- `stepToMidi` wraps out-of-range step indices by adjusting octave,
  then **clamps the resulting MIDI note to 0..127** by folding the
  overflow into detune. A very-low step does not silently disappear; it
  returns `(0, <large negative detune>)`.

### Addressable range

The temperament hangs from a single anchor: cents 0 ≡ MIDI 0 (`C-1`).
Everything grows upward from there by the fixed slope 100¢ = 1 semitone,
so a note is *addressable* only while its cents sit in `[0, 12700]` — from
the anchor to MIDI 127. The pitchbend window (`pbRange`) can bend the
*sound* a little past either end, but the note's own `(pitch, octave)`
cannot: below the anchor you have crossed cents 0; above 127 the MIDI note
clamps.

Editing operations enforce this, so the range — and the `cellWidth` octave
budget derived from it — stays exact. A seated note's detune is always in
`[-50, 50]` (it is `cents − round(cents/100)·100`); only a clamp-fold past
the anchor or the ceiling pushes `|detune|` beyond 50. So both the octave-
column entry and the pitch **nudge** reject any result with `|detune| > 50`
— the note stays put rather than drifting onto an unrealisable pitch.

## Display

```
C-4 / 7-4 / 12-M               -- pitch-cell labels
```

A step renders as its name plus the octave (`C-4`). A **nameless step** —
one whose `stepNames` entry is blank — falls back to its degree with a
dash separator (`7-4`), reusing the named cell's shape. Octave -1 renders
as `"M"` (so `C-M` for MIDI 0 vs `C-4` for MIDI 60).

In the tracker cell the note and octave are each **right-aligned within
their own field** — the note in the left `cellWidth - octaveWidth` columns,
the octave in the right `octaveWidth` columns (`tuning.stepToParts` exposes
the two parts). So the separator and the octave's units digit each keep a
fixed column across rows, even when octave labels vary in width (a sub-
octave period mixing single- and double-digit octaves). The octave cursor
stop (cell column `cellWidth-1`) lands on the units digit; the note-entry
stop (column `0`) is a keyboard affordance, so it may sit on left padding
for a short label without harm.

`cellWidth` is the derived char width of the widest label: the longest
name (or a 2-digit degree) plus the **octave field**. The octave field is
one char for octave-or-larger periods — their displayed octave never leaves
`-1..9` (`"M".."9"`) — but a **sub-octave period** packs more than ten
period-cycles into the MIDI range, so its octave labels reach two digits
and the field grows to match. 12-EDO and the other octave-period presets
derive 3, the historic fixed width; only sub-octave scales widen. The
budget comes from the top of the natural `[0, 12700]`¢ range (floor
anchored at `-1`), which holds because edits keep notes in range — see
*Addressable range*.

## Slot registry

Mirrors the swing model in `docs/timing.md`:

- `tuning.presets` is **seed-only** — never consulted at slot
  resolution time. Its role is to populate the UI's "copy into
  library" menu.
- The runtime library lives in `cfg.tempers` at project scope; slots
  in `cfg.temper` reference temperaments **by name only**.
- `findTemper(name, userLib)` resolves only within the userLib. A
  missing name or missing lib returns nil; callers treat nil as
  "no temperament".

## Absorber reconciliation

The absorber pass of `trackerManager` runs after the tail walk finalises
lane-1 raw ppqs (same-pitch onset clamps, delay/clamp combinations that
reorder hosts) and after externals are placed. From the final realised
lane-1 sequence it:

- Back-derives cents for any pb missing it (foreign-MIDI / first load):
  `cents = rawToCents(wire) − detune` at the pb's seat.
- Covers every detune-jump seat: a real pb at that ppq counts;
  otherwise reuse an existing fake if any (in-place first, else move),
  else create a new fake.
- Anchors a pb-active channel at its first lane-1 onset (even detune 0)
  unless a real pb already pins it at-or-before (I2a).
- Drops fakes whose seat is no longer needed.
- Writes wire raw = `centsToRaw(cents + carrying lane-1 detune)`.
- Projects the pb column from the final set, with `val=cents` (the
  authored value tv displays) and `hidden` for every derived seat.

Reads pbs directly from mm; the um cache (`chans`, `byUuid`) is
rebuilt at the end-of-rebuild `reload()`.

### Authoring onto a hidden seat

Pitchbend is one value per tick, so two pb events at one (chan, ppq) are a
contradiction on the wire whatever names them. An anchored or detune-seated
onset already holds a hidden absorber pb; the projection hides it, so the
pitchbend cell reads empty. Authoring there must **adopt** that seat —
`addEvent` seeks `chans[chan].pbs` for a pb at that onset and assigns it (new
cents, `derived` cleared) rather than pushing a rival. Pushing a rival was the
"stuck after the first digit" bug: back when mm addressed by content key the
two pbs shared a token, the reconcile's delete removed the authored one, and
the cell snapped back to the seat's value. Adopting also reuses the seat's uuid
sidecar instead of orphaning it.

### Value-aware seats and densification

A seat is no longer value-blind. It samples the **prevailing authored pb
value** at its ppq (`streamValue` — interpolate between the bounding
breakpoints, hold the last past the end, 0 before the first) and adds
detune. The old `cents=0` discarded any authored value passing through the
seat, so you could not interpolate or hold a pb across a detune onset; now
the seat carries it. The two-number pb breakpoint (display `cents` vs wire
raw) is what lets the column still show the user's sparse authored shape
while the wire carries the realisation.

How a seat realises depends on whether the authored value *ramps* across
the onset:

- **Flat / held / no stream** — a lone **step** seat holds the prevailing
  value and steps detune at the onset. This is the common pure-detune case;
  the value-aware machinery is inert (`streamValue` is 0 or a constant).
- **Ramps (sloped or curved segment)** — the seat must ride **linearly** so
  the curve tracks through it, so the detune step can no longer be the
  seat's own shape. It splits onto a **dual point**: a just-before seat
  carrying `streamValue(onset) + old detune` and an at-onset seat carrying
  `streamValue(onset) + new detune`. The curve rides through both; detune
  jumps between them, never smeared across the preceding cell.
- **Curved segment under an onset** — REAPER's fixed-tension shapes cannot
  be split at an arbitrary point, so the segment is re-expressed as a
  **densified linear polyline**: derived seats on a fixed grid (step =
  `resolution / CCINTERP` ticks -- `CCINTERP` is interpolated points per QN,
  the density REAPER itself linearizes CC at) sampling the curve. The grid is fixed, not curvature-adaptive, and keyed
  on the stable authored ppqs — adaptive points would move between rebuilds
  and churn (the canon-ppq lesson). A curved segment with no interior onset
  rides REAPER's native shape untouched.

**Replace curves ride the same seats.** A pb-replace generator's absolute
curve is seated here, not on an additive carrier. Inside a replace window
`streamValue` returns the *curve* (interpolated over the generator's
breakpoints); the breakpoints become derived seats carrying their shape, and a
curved curve-segment split by a detune onset densifies exactly as an authored
one does. Authored pbs the window covers **park off-take** (the unified
`fxParked` stash, `evType='pb'`) so every on-take pb in the window is a derived
seat -- exclusive ownership; they stay visible in-column via the `parkedPb`
render union and restore to the take when the region leaves. Each wire raw is `centsToRaw(curve +
detune)` — no carrier, no add-bank slot. See `design/note-macros-v2.md`
§ Continuous pb replace.

**In-window seats are markerless.** A replace seat writes native MIDI only
(`{ppq, val, shape}`), so `addCC` mints no uuid and no `eventMeta` sidecar — a
dense curve costs zero metadata. Recognition is then purely by region: exclusive
ownership means every on-take pb inside a live window is a seat, so `inSeatWindow`
(raw bounds, inclusive of `endRaw` for the terminal re-centre) classifies a loaded
markerless pb as a seat and tags `derived='absorber'` in RAM only. Detune absorbers
*outside* any window keep their marker + cents sidecar (no exclusive owner there).
The create/remove transition — park authored in, sweep seats out — is diffed by
tm's `fxRegions` observer, not carried as a standing record. See
`design/note-macros-v2.md` § Route-by-window.

Origin and the replace path (generator curves reusing the same seats):
`design/archive/pb-interpolation.md`.

## Conventions

- **Octave param is MIDI-relative** (C4 → 4, C-1 → -1), not
  period-index. Conversions between the two live inside this module;
  callers see MIDI octaves.
- **All `tuning.lua` functions are pure.** Pass the temper; no
  module-level current temper. vm/tm read `cm:get('temper')` and
  forward it.
- **Step naming is optional.** A named step displays as name+octave; a
  blank name falls back to its degree (Option B). `octaveStep` and
  `cellWidth` derive from the names — `tuning.derive` restamps both on
  every cents/name edit.
- **Detune is cents** throughout (never raw 14-bit). Conversion to
  raw pb happens only inside tm's flush boundary.
