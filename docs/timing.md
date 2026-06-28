# timing

Cross-cutting reference for time in Continuum: the two frames, who
owns them, and the transforms between them. Also the API reference
for `timing.lua`, the pure module that implements those transforms.

## The two frames

Time in Continuum lives in two frames:

- **logical** (`ppqL`, `endppqL`) — the authoring grid. Row `r` sits
  at `r · logPerRow(rpb, denom, res)`. What the musician sees and
  edits.
- **realisation** (`ppq`, `endppq`) — what REAPER stores: swing
  applied to the logical position, plus the per-note delay nudge on
  note-ons.

Single forward transform:

```
ppq    = swing.fromLogical(ppqL,    cm.swing) + delayToPPQ(delay)   -- note-on
endppq = swing.fromLogical(endppqL, cm.swing)                       -- note-off, no delay
```

`ppqL` is the source of truth. Raw is a derived view, rebuilt from
ppqL each `tm:rebuild`. The inverse `swing.toLogical` has exactly
one call site — the rebuild rule's predicted-check arm, which
derives ppqL from raw when an externally edited or freshly imported
event arrives without a usable stamp (see Reswing).

Repeated swing edits do not accumulate ε: each rebuild starts from
the same ppqL and applies the current swing afresh.

## Frame ownership

| layer            | sees                  | duty                                                                                     |
|------------------|-----------------------|------------------------------------------------------------------------------------------|
| `midiManager`    | realisation           | REAPER's storage; raw `ppq` only                                                         |
| `trackerManager` | both (private)        | hold the pair on every event; rebuild raw from ppqL on stale or external edit            |
| `trackerView`    | logical               | row math is identity over ppqPerRow; column events expose `evt.ppq` as the logical position |
| `editCursor`     | logical (rows)        | row units only                                                                           |

Above tm only one frame exists. The column-projection step at the
end of `tm:rebuild` overwrites `evt.ppq` with `round(evt.ppqL)` for
every event that carries a logical stamp; that is the value vm and
above consume. Raw is held alongside on the same record but is not
on the consumer surface.

`evt.delay` rides through to vm unchanged so delay editing UIs can
read it, but it has no effect on row math: vm sees the position
already in logical frame, where delay is absent.

## Stamping

Authoring sites stamp `ppqL` from cm's rpb/denom/res at write time;
the note-off stamps `endppqL` the same way. Swing arithmetic does
not enter the stamping path. Editing delay shifts raw's note-on but
never touches ppqL — delay is orthogonal to the logical/realisation
boundary.

`rpb` is purely a view concern. Changing rpb changes how rows map
to ppqL but does not change any event's ppqL. Events placed under
one rpb appear at non-integer rows under another. Same accepted
trade-off class as deliberately off-grid notes.

## Reswing

The take's swing is held by cm — a take-wide *global* layer and an
optional *per-column* layer, with column inside global:

```
E_c = global ∘ column
```

Whenever a channel's resolved swing changes, raw is recomputed from
ppqL against the new swing. Triggers all collapse to "the swing
this channel resolves to changed":

- global swing edited
- this channel's per-column swing edited
- a library entry referenced by either is edited or renamed in place
- a slot is reassigned to a different library entry

The configChanged subscriber on tm marks the affected channels via
`tm:markSwingStale(chan)` (or `nil` for all 16, when the global
layer changes). Cross-take propagation is `seqMgr:reswingAll`,
which visits every take using a renamed library entry and binds
through `tm:bindTake(opts.markSwingStale=true)` so the visited
take's rebuild rebuilds raw from ppqL under its current swing.

### Rebuild rule

Step 4.7 of `tm:rebuild`. For each non-derived event:

- **fake** (absorbers, synthesised PCs) — exempt; reseated by step
  4.8 from host raw.
- **stale and ppqL present** — rebuild raw:
  `ppq = round(swing.fromLogical(ppqL)) + delayToPPQ(delay)`, and
  similarly `endppq = round(swing.fromLogical(endppqL))`. The
  staleSwing flag is cleared at the end of the pass.
- **else** — predicted-check. Compute
  `predicted = round(swing.fromLogical(ppqL)) + delayToPPQ(delay)`.
  If `|raw − predicted| ≤ 1 ppq`, no-op. Otherwise rederive
  `ppqL = swing.toLogical(raw − delayToPPQ(delay))` and
  `endppqL = swing.toLogical(endppq)`. Missing ppqL counts as
  disagreement.

The `rpb` mark survives as authorship provenance (it gates reswing
and clipboard symmetry) but no longer gates this rule. Between
rebuilds swing cannot change without setting the channel stale, so
any raw/predicted disagreement on a non-stale channel is an
external edit and ppqL follows raw. The earlier "rpb-stamped is
exempt" arm froze ppqL silently and then wiped the external edit
the next time the channel went stale — a recoverable disagreement
turned into a silent loss.

The single rule covers three cases that look distinct from
outside but reduce to the same code path: a steady-state rebuild
where ppqL and raw agree; a user editing in REAPER's piano roll
between rebuilds; and an event arriving without a persisted ppqL.

### "Caller speaks raw" signal

Some callers — `tm:rescaleLength`'s plan-then-mutate path — have
already computed raw locally and want the assignment to bypass the
forward translation. The signal is an
explicit `rawTime = true` on the `tm:assignEvent`/`tm:addEvent`
payload: the realise step threads the caller's raw through
unmodified, applies only the delay-delta correction, and **consumes
the flag** (strips it) so it never persists on the record or reaches
mm. Absent the flag, realise runs `fromLogical` to derive raw from
the (possibly updated) logical stamp.

`ppqL`/`endppqL` are intent stamps, not the bypass signal. They are
orthogonal: a logical caller (groups projecting an instance) sets
`endppqL` to express the intent ceiling while still wanting the
onset swung. Conflating the two — treating the presence of the data
stamp as the control signal — placed group-projected notes off-grid
by exactly the swing displacement under a non-identity swing
(`tests/specs/gm_swing_spec.lua`).

## Swing: logical → realisation

A *swing* is a piecewise-linear orientation-preserving homeomorphism
of `[0,1]` fixing the endpoints, tiled periodically along a QN
axis. Identity swing means logical equals realisation (ignoring
delay).

Consumers go through `resolveComposite`, which produces a single
clipped Shape over `[0, length]`:

```
shape = timing.resolveComposite(composite, length_ppq, ppqPerQN)
ppq   = timing.eval  (shape, ppqL)
ppqL  = timing.invert(shape, ppq)
```

The Shape captures the entire factor stack as one PWL with slopes
∈ `[1/K, K]`; the boundary clip absorbs overhang from id-shift,
phase, and negative-shift atoms (see Boundary clip below).
`applyFactors` / `unapplyFactors` remain as the unclipped primitives
on a resolved factor array, used by the editor's QN-space preview;
take-level callers should not use them directly.

The helper is `tm:swingSnapshot()`, which freezes both layers
against the current cm config and returns ready-to-use `fromLogical`
/ `toLogical` closures keyed by channel. The rebuild rule captures
one snapshot per pass and routes both arms through it.

### Shape representation

A swing shape is a sorted array of control points starting at
`{0,0}` and ending at `{1,1}`, with strictly increasing x and y:

```
S = { {0,0}, {x1,y1}, ..., {xn,yn}, {1,1} }
```

Evaluation `S(x)` and inversion `S⁻¹(y)` are O(log n) via binary
search. Shapes form a group under composition; the identity is
`{ {0,0}, {1,1} }`. Strict monotonicity is the invariant that makes
inversion well-defined — atoms document their `|a|` bound
explicitly, and pushing past it collapses a segment.

**Smooth atoms are sampled.** `classic`, `pocket`, `lilt`, `shuffle`,
`tilt` are continuous parametric curves that emit dense PWL
approximations (240 segments per unit square). The runtime treats
them identically to hand-built PWL — eval/invert/tile/compose all
consume the canonical control-point form. Smoothness is a property
of how the shape is generated, not of the runtime. The sample
count is a multiple of 12 so principal-pulse breakpoints
(x = 1/4, 1/3, 1/2, 2/3, 3/4) all land on exact sample points —
the cross-atom drop-in invariant stays algebraic. `id` is the only
atom that returns a sparse 2-point shape, and the only atom whose
endpoints are not pinned: `id(a) = {(0, a), (1, 1+a)}`. Plugged
into `tile`, the result is a constant output translation
`p → p + T·a` — the substrate for delay. The endpoint convention
is relaxed because `resolveComposite` absorbs the resulting overhang
at the take edges (see Boundary clip).

### Tiled extension

To act on a time axis, attach a period `T`:

```
tile(S, T, p) = T * (floor(p/T) + S((p/T) mod 1))
```

Every multiple of `T` is a fixed point. `T <= 0` degrades to
identity so callers can drive the transform from a possibly-empty
composite without special cases.

**Period unit is quarter notes**, scalar or `{num, den}`. QN is
preferred over "beat" because a beat is denominator-dependent (6/8
vs 4/4), whereas one quarter note is always one quarter note.
`periodQN` normalises both shapes; other inputs are a caller bug
and raise.

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

`atom` names an entry in `timing.atoms`, `period` is the *user
pulse* in QN, and `shift` is the QN-displacement of the atom's
principal — the principal lands at `principal_qn + shift` after the
factor applies, regardless of atom or period. The realised view
transform is the composition of the factors' tiled extensions —
earlier factors are inner, later are outer (`applyFactors`). A
bare `{}` and `{factors = {}}` both denote identity.

The composite-level `phase` field is reserved as a global QN offset
applied across the whole take. It is shape-only at present;
consumers treat its absence as `0`.

`shift` is **atom-independent in QN**: switching `atom` preserves
the QN-amount of `shift`. The principal it shifts is atom-specific
— its unit-x location is in the atom table (API reference), and
its qn-position is `T_tile · x_principal`. Atoms with the same
`x_principal` *and* the same `pulsesPerCycle` are drop-in
replacements at fixed `period`.

#### Tile period vs user period

```
T_tile(factor) = periodQN(factor.period) × atomMeta[atom].pulsesPerCycle
```

`lilt` and `pocket` have `pulsesPerCycle = 2` — one atom cycle
spans two user-pulses, so the actual repeat period is double what
the user picks. The unit-square parameter consumed by the atom
shape is `a = shift / T_tile`. `compositePeriodQN` and the
editor's per-factor preview both use `atomTilePeriod` so the
displayed repeat matches the realised one.

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
PPQ (`ppqPerQN · periodQN(phase)`) and rides into the resolved
factor as `{S, T, phase}`. Absent or zero phase is a no-op —
`apply` collapses to the original `tile`.

#### Boundary clip

Tiled factors don't naturally align with the take's `[0, length]`.
With identity-shift, or with phase, or with negative-shift atoms,
the apply at `x = 0` lands above or below `0`, and similarly at
the trailing edge. `resolveComposite(composite, length, ppqPerQN)`
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
directly. `tm:swingSnapshot()` carries one Shape per layer
(`global` + per-channel `column`), recomputed each rebuild.

The clip is **load-bearing, not edge-case correction.** Without it,
identity-with-shift and phase break injectivity at the take edges.
With it, the entire factor stack collapses to a single PWL with
slopes ∈ `[1/K, K]` — `unapply` is just `invert`, and the apply
path costs one binary search per layer instead of one tile per
factor.

Tradeoff: events authored in the leading or trailing partial tile
get the corner ramp, not the swing transform. Bounded by tile
width on each edge; documented and accepted. Identity composite
or `length ≤ 0` returns a 2-point identity over `[0, length]`.

The runtime library lives in `cfg.swings` at project scope; slots
in `cfg` reference composites **by name only**. Name lookup goes
through `findShape(name, userLib)`; a missing name or missing
library returns nil, and callers treat nil as identity.

`timing.presets` is **seed data only** — never consulted at
slot-resolution time. Its role is to populate the UI's "copy into
library" menu.

## Delay: per-note nudge

`delay` is a per-note metadata field (signed milli-QN, defaulted
to 0). It nudges only the note-on:

```
ppq    = swing.fromLogical(ppqL) + delayToPPQ(delay)
endppq = swing.fromLogical(endppqL)
```

A positive delay shrinks raw duration by exactly `delayToPPQ(delay)`;
a negative delay extends it. Classical tracker sub-row note-on
nudge.

`delayToPPQ` rounds at source, making the map an **integer
bijection on ℤ**: every arithmetic use stays in ℤ, so realise /
strip round-trips are algebraic rather than approximate.

Absorbers (`fake=true` pbs at lane-1 detune-jump seats) carry no
`delay` field of their own. They sit at the host note's raw —
`reconcileBoundary` sets them on edit paths; rebuild's absorber pass
reseats them when the host moved. See `docs/tuning.md` §"The
fake-pb absorber".

## Cross-frame invariants

- **Delay does not affect column allocation.** `noteColumnAccepts`
  judges overlap in logical, where delay is absent.
- **`ppqL` is delay-independent.** Authoring stamps ppqL from row
  arithmetic; delay nudges shift raw `ppq` but never `ppqL`. This
  is what lets reswing reseat events without losing the user's
  authoring intent.
- **`endppq` carries no delay.** Only the note-on receives the
  offset, at every layer.
- **Float `ppqPerRow`.** vm holds `ppqPerRow = logPerRow(rpb, denom, res)`
  without pre-rounding. Under non-divisor `rpb` (e.g. 7) the rounded
  form would seed ε that compounds through swing inversion; with
  floats, `rowToPPQ` / `ppqToRow` are mutually exact (single round
  only at the column-projection step) and on-grid tests collapse to a
  clean integer compare against `evt.ppq`.

## Conventions for `timing.lua`

- **Endpoints are pinned.** Atom shapes pin `{0,0}` and `{1,1}`;
  `id`-with-shift is the lone exception, and `resolveComposite`'s
  boundary clip absorbs its overhang. Resolved take-level Shapes
  pin `(0,0)` and `(length, length)`. `compose` re-writes its
  endpoints after computation to absorb floating-point drift —
  downstream binary search depends on these exact pins.
- **Composite names resolve within the project library.** tm/vm
  never look into `presets`; resolution goes through `findShape`,
  nil is identity.
- **Factor order is inner-to-outer.** `applyFactors` walks forward,
  `unapplyFactors` walks backward — preserve the order when editing
  a composite.
- **Atoms do not clamp.** Callers read `timing.atomMeta[name].range`
  and clamp there.
