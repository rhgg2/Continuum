# timing

Cross-cutting reference for time in Continuum: the three frames, who owns
them, and the transforms between them. Also the API reference for
`timing.lua`, the pure module that implements those transforms.

## The three frames

Time in Continuum lives in three frames, stacked from authoring down to
storage:

- **logical** (`ppqL`) — the authoring grid. Row `r` sits at
  `r · logPerRow(rpb, denom, res)`. This is what the musician sees and
  edits.
- **intent** (`ppqI`) — the nominal placement after swing has been
  applied. Under identity swing, `ppqI = ppqL`. Otherwise swing
  reshapes how the grid lands in time.
- **realisation** (`ppqR`) — what REAPER stores: intent plus the
  per-note delay nudge. Only the note-*on* carries the offset; the
  note-*off* is intent in storage too.

The frames stack:

```
ppqL  --[ swing.fromLogical ]-->  ppqI  --[ + delayToPPQ(delay) ]-->  ppqR
ppqL  <--[ swing.toLogical  ]---  ppqI  <--[ - delayToPPQ(delay) ]---  ppqR
```

Each conversion is a separate concern: swing is global+per-column
state held in `cm`; delay is per-note metadata. The two compose, but
neither contaminates the other.

## Frame ownership

Each manager holds one or two frames natively and converts at its
boundary with neighbours.

| layer            | native frame                  | conversion duty                                                                                |
|------------------|-------------------------------|------------------------------------------------------------------------------------------------|
| `midiManager`    | realisation                   | none — REAPER's storage frame                                                                  |
| `trackerManager` | intent (public surface), realisation (`um` and rebuild) | `tidyCol` strips delay on read; `um:add/assignEvent` restores it on write to mm |
| `trackerView`    | intent (timing math), logical (authoring stamps) | `ctx:ppqToRow` / `ctx:rowToPPQ` run swing; `stamping` records `ppqL` on authored events     |
| `editCursor`     | logical (rows)                | none — talks to vm in row units                                                                |

The two conversion boundaries:

- **Delay boundary** lives inside tm. `tm:rebuild`'s `tidyCol` is the
  *sole* place that subtracts delay from `evt.ppq` to enter intent
  frame; `um:assignEvent` / `um:addEvent` add it back when writing to
  mm. Inside `tm:rebuild`, ppq comparisons run in realisation frame
  until `tidyCol`; from rebuild's exit onward everything tm exposes is
  intent.
- **Swing boundary** lives inside vm. `ctx:ppqToRow` runs
  `swing.toLogical` on its input; `ctx:rowToPPQ` runs
  `swing.fromLogical` on its output. Authored events are stamped with
  `ppqL` (and `endppqL` for notes) at write time so reswing can
  re-derive intent under a new swing without losing the
  authoring-frame coordinate.

`tm` itself never inspects `ppqL` — those fields ride through as
sidecar metadata. Their semantics are entirely vm's.

## Swing: logical ↔ intent

A *swing* is a piecewise-linear orientation-preserving homeomorphism
of `[0,1]` fixing the endpoints, tiled periodically along a QN axis.
Identity swing means logical equals intent.

Consumers go through `resolveComposite`, which produces a single
clipped Shape over `[0, length]`:

```
shape = timing.resolveComposite(composite, length_ppq, ppqPerQN)
ppqI  = timing.eval  (shape, ppqL)
ppqL  = timing.invert(shape, ppqI)
```

The Shape captures the entire factor stack as one PWL with slopes
∈ `[1/K, K]`; the boundary clip absorbs overhang from id-shift,
phase, and negative-shift atoms (see Boundary clip below).
`applyFactors` / `unapplyFactors` remain as the unclipped primitives
on a resolved factor array, used by the editor's QN-space preview;
take-level callers should not use them directly.

Two layers of swing compose per channel — a take-wide *global* and an
optional *per-column* layer — with column inside global:

```
E_c = global ∘ column
```

Both layers always apply when present; the per-column layer doesn't
replace global, it acts first and global acts on its output. Identity
in either slot is a no-op, so a channel with no per-column swing
sees only `global`, and a take with only per-column swing on some
channels sees those channels swung and the rest straight.

The helper is `tm:swingSnapshot()`, which freezes both layers against
the current cm config and returns ready-to-use `fromLogical` /
`toLogical` closures keyed by channel. vm captures one snapshot per
rebuild and routes all row math through it.

### Shape representation

A swing shape is a sorted array of control points starting at `{0,0}`
and ending at `{1,1}`, with strictly increasing x and y:

```
S = { {0,0}, {x1,y1}, ..., {xn,yn}, {1,1} }
```

Evaluation `S(x)` and inversion `S⁻¹(y)` are O(log n) via binary
search. Shapes form a group under composition; the identity is
`{ {0,0}, {1,1} }`. Strict monotonicity is the invariant that makes
inversion well-defined — atoms document their `|a|` bound explicitly,
and pushing past it collapses a segment.

**Smooth atoms are sampled.** `classic`, `pocket`, `lilt`, `shuffle`,
`tilt` are continuous parametric curves that emit dense PWL
approximations (240 segments per unit square). The runtime treats
them identically to hand-built PWL — eval/invert/tile/compose all
consume the canonical control-point form. Smoothness is a property of
how the shape is generated, not of the runtime. The sample count is a
multiple of 12 so principal-pulse breakpoints (x = 1/4, 1/3, 1/2,
2/3, 3/4) all land on exact sample points — the cross-atom drop-in
invariant stays algebraic. `id` is the only atom that returns a
sparse 2-point shape, and the only atom whose endpoints are not
pinned: `id(a) = {(0, a), (1, 1+a)}`. Plugged into `tile`, the result
is a constant output translation `p → p + T·a` — the substrate for
delay. The endpoint convention is relaxed because `resolveComposite`
absorbs the resulting overhang at the take edges (see Boundary clip).

### Tiled extension

To act on a time axis, attach a period `T`:

```
tile(S, T, p) = T * (floor(p/T) + S((p/T) mod 1))
```

Every multiple of `T` is a fixed point. `T <= 0` degrades to identity
so callers can drive the transform from a possibly-empty composite
without special cases.

**Period unit is quarter notes**, scalar or `{num, den}`. QN is
preferred over "beat" because a beat is denominator-dependent (6/8 vs
4/4), whereas one quarter note is always one quarter note.
`periodQN` normalises both shapes; other inputs are a caller bug and
raise.

### Composite model

A user-facing swing has the shape:

```
composite = {
  phase   = 0,         -- optional, QN; reserved for composite-level offset
  factors = {
    { atom = 'classic', shift = 0.12, period = 1, phase = 0 },
    ...
  },
}
```

`atom` names an entry in `timing.atoms`, `period` is the *user pulse*
in QN, and `shift` is the QN-displacement of the atom's principal —
the principal lands at `principal_qn + shift` after the factor
applies, regardless of atom or period. The realised view transform is
the composition of the factors' tiled extensions — earlier factors
are inner, later are outer (`applyFactors`). A bare `{}` and `{factors
= {}}` both denote identity.

The composite-level `phase` field is reserved as a global QN offset
applied across the whole take. It is shape-only at present; consumers
treat its absence as `0`.

`shift` is **atom-independent in QN**: switching `atom` preserves the
QN-amount of `shift`. The principal it shifts is atom-specific — its
unit-x location is in the atom table (API reference), and its
qn-position is `T_tile · x_principal`. Atoms with the same
`x_principal` *and* the same `pulsesPerCycle` are drop-in
replacements at fixed `period`.

#### Tile period vs user period

```
T_tile(factor) = periodQN(factor.period) × atomMeta[atom].pulsesPerCycle
```

`lilt` and `pocket` have `pulsesPerCycle = 2` — one atom cycle spans
two user-pulses, so the actual repeat period is double what the user
picks. The unit-square parameter consumed by the atom shape is
`a = shift / T_tile`. `compositePeriodQN` and the editor's
per-factor preview both use `atomTilePeriod` so the displayed repeat
matches the realised one.

#### Per-factor phase

A factor may carry an optional `phase` (QN; scalar or `{num,den}`)
that rotates its fixed-point lattice. With `phase = φ`, the points
that pass through unchanged shift from `{kT}` to `{φ + kT}`:

```
tile(S, T, p, φ) = φ + tile(S, T, p − φ)
```

Phase is *not* output translation. At a fixed point the function
returns its input; at any other point the swing still acts. The
visible effect is that the atom's principal — and the entire
breakpoint pattern — slides by `φ` along the tile axis, while the
tile's own period and shape stay fixed.

Resolution: at the tm boundary the user-facing QN value becomes
PPQ (`ppqPerQN · periodQN(phase)`) and rides into the resolved factor
as `{S, T, phase}`. Absent or zero phase is a no-op — `apply`
collapses to the original `tile`.

#### Boundary clip

Tiled factors don't naturally align with the take's `[0, length]`.
With identity-shift, or with phase, or with negative-shift atoms, the
apply at `x = 0` lands above or below `0`, and similarly at the
trailing edge. `resolveComposite(composite, length, ppqPerQN)`
materialises the apply across the take and clips:

1. Generate breakpoints over `[−margin, length + margin]` (margin =
   max factor `T`) — every factor's intrinsic kinks pulled back
   through the prefix factors.
2. Drop breakpoints with `x ≤ 0` or `x ≥ length`.
3. Walk corners from each end, deleting until the gradient from
   `(0,0)` to the first survivor (and from the last survivor to
   `(length, length)`) lies in `[1/K, K]`.
4. Pin `(0,0)` and `(length, length)`; return the resulting Shape.

Consumers eval/invert this Shape rather than calling `applyFactors`
directly. `tm:swingSnapshot()` carries one Shape per layer (`global`
+ per-channel `column`), recomputed each rebuild; vm routes
`ppqToRow` / `rowToPPQ` through them.

The clip is **load-bearing, not edge-case correction.** Without it,
identity-with-shift and phase break injectivity at the take edges.
With it, the entire factor stack collapses to a single PWL with
slopes ∈ `[1/K, K]` — `unapply` is just `invert`, and the apply path
costs one binary search per layer instead of one tile per factor.

Tradeoff: events authored in the leading or trailing partial tile
get the corner ramp, not the swing transform. Bounded by tile width
on each edge; documented and accepted. Identity composite or
`length ≤ 0` returns a 2-point identity over `[0, length]`.

The runtime library lives in `cfg.swings` at project scope; slots in
`cfg` reference composites **by name only**. Name lookup goes through
`findShape(name, userLib)`; a missing name or missing library returns
nil, and callers treat nil as identity.

`timing.presets` is **seed data only** — never consulted at
slot-resolution time. Its role is to populate the UI's "copy into
library" menu.

## Delay: intent ↔ realisation

`delay` is a per-note metadata field (signed milli-QN, defaulted to
0). It nudges only the note-on:

```
realised.ppq    = intent.ppq + delayToPPQ(delay)
realised.endppq = intent.endppq                  -- delay never shifts the end
```

A positive delay shrinks realised duration by exactly
`delayToPPQ(delay)`; a negative delay extends it. Classical tracker
sub-row note-on nudge.

`delayToPPQ` rounds at source, making the map an **integer bijection
on ℤ**: every arithmetic use (`intent ± delayToPPQ(d)`) stays in ℤ,
so realise/strip round-trips are algebraic rather than approximate.

## Cross-frame invariants

- **Delay does not affect column allocation.** `noteColumnAccepts`
  judges overlap in intent, so changing a note's delay can never push
  it into a different column or spring a new one.
- **Fake pbs inherit their host note's delay** at rebuild time so
  `tidyCol` shifts host and absorber into intent together. Without
  this, a delayed note and its absorber would desynchronise at the vm
  boundary. (Absorbers are the detune-realisation mechanism — see
  `docs/tuning.md`.)
- **`ppqL` is delay-independent.** Authored events stamp `ppqL` from
  row arithmetic; delay nudges shift `ppq` / `endppq` but never
  `ppqL`. This is what lets reswing reseat events without losing the
  user's authoring intent.
- **`endppq` is intent in storage** at every layer — mm, tm, vm. Only
  `ppq` has a realisation/intent distinction.
- **Float `rowPPQs`.** vm stores `rowPPQs[r] = r · logPerRow` without
  pre-rounding. Under non-divisor `rpb` (e.g. 7) the rounded form
  would seed ε that compounds through swing inversion; with floats,
  `rowToPPQ` / `ppqToRow` are mutually exact (single round only at
  realisation) and on-grid tests collapse to a clean integer compare
  against `evt.ppq`.

## Conventions for `timing.lua`

- **Endpoints are pinned.** Atom shapes pin `{0,0}` and `{1,1}`; `id`-
  with-shift is the lone exception, and `resolveComposite`'s boundary
  clip absorbs its overhang. Resolved take-level Shapes pin `(0,0)`
  and `(length, length)`. `compose` re-writes its endpoints after
  computation to absorb floating-point drift — downstream binary
  search depends on these exact pins.
- **Composite names resolve within the project library.** tm/vm never
  look into `presets`; resolution goes through `findShape`, nil is
  identity.
- **Factor order is inner-to-outer.** `applyFactors` walks forward,
  `unapplyFactors` walks backward — preserve the order when editing a
  composite.
- **Atoms do not clamp.** Callers read `timing.atomMeta[name].range`
  and clamp there.
