# Swing redesign — atoms as functions, ramps at the boundaries

A working design replacing `resolveComposite` / `buildLeadingClip` /
`buildTrailingClip` / corner-walk machinery with three pieces: a linear
ramp-on, an analytic middle, a linear ramp-off.

The goal is performance — real-time slider drag stutters on the
clipped path despite a candidate count that should be microseconds —
and parsimony: three wired-together mechanisms collapse to one shape.

The model is unchanged. Composites are PWL homeomorphisms of
`[0, length]` with slopes in `[1/K, K]` and `f(0) = 0`, `f(L) = L`.
What changes is *how* that shape is constructed and queried.

---

## Atoms as first-class functions

Currently each atom is a factory `function(shift) -> PWL[]`. The PWL
is sampled once at composition time (240 points for smooth atoms, 16
for `id`) and consumed by `applyFactors` via `tile` → `pwlEval`. Every
event eval pays for a `findSegment` binary search per factor.

In the new design atoms are pure unit-interval functions:

```lua
M.atoms.classic = {
  forward = function(u, s) return u + s * math.sin(math.pi * u) end,
  inverse = function(v, s) ... end,        -- closed form
}

M.atoms.id = {
  forward = function(u, s) return u + s end,
  inverse = function(v, s) return v - s end,
}

-- pocket, lilt, tilt likewise — closed-form forward + inverse.
```

`applyFactors` becomes function composition with tile bookkeeping —
arithmetic only, no PWL search. The atom-level binary search that
currently dominates eval cost vanishes.

**Shuffle is the exception.** Two-harmonic sums have no elementary
inverse. Shuffle carries `forward` plus a guarantee: monotonic,
endpoint-preserving on the unit interval. `resolveComposite` builds a
sampled PWL inverse for each shuffle factor at composition time;
`unapplyFactors` binary-searches it. Forward stays O(1); shuffle
backward is O(log n) per factor.

Sampling density for the shuffle inverse: **60 samples per QN of the
factor's period.** Period-1-QN shuffle gets 60 points on its unit
interval; period-2-QN gets 120; period-4-QN gets 240. The K-bound
(60) sets the resolution of slope distinctions we care about; tying
sample density to period in QN keeps absolute ppq-spacing constant
across periods.

## Three regions: ramp-on, analytic middle, ramp-off

The resolved Shape is:

```lua
{
  factors = ResolvedFactor[],
  a       = number,    -- ramp-on extent in PPQ
  b       = number,    -- ramp-off start in PPQ
  ya      = number,    -- applyFactors(a)
  yb      = number,    -- applyFactors(b)
  length  = number,
}
```

`eval(S, x)`:

- `x ≤ a`:           `x · ya / a`                          (linear)
- `a < x < b`:       `applyFactors(factors, x)`            (analytic)
- `x ≥ b`:           `yb + (x - b) · (length - yb) / (length - b)`

`invert(S, y)`:

- `y ≤ ya`:          `y · a / ya`
- `ya < y < yb`:     `unapplyFactors(factors, y)`
- `y ≥ yb`:          `b + (y - yb) · (length - b) / (length - yb)`

Continuity at the seams is automatic: ramp-on right endpoint is
`(a, ya)` by construction; middle at `a` is `applyFactors(a) = ya`;
similarly at `b`.

Endpoint pinning: ramp-on at 0 is 0; ramp-off at `length` is `length`.
Both by construction.

No Δ. The middle is bare `applyFactors`.

## Building the ramps — secant from the anchor

Forward walk to find `a`:

1. `step = ppqPerQN / 60`.
2. For `k = 1, 2, …`, let `x = k · step`, `y = applyFactors(x)`.
3. Compute secant slope `g = y / x`.
4. If `g ∈ [1/K, K]`, take this `(a, ya) = (x, y)` and stop.

The secant slope *is* the ramp's slope — bounding it directly bounds
the ramp. (The earlier proxy — local slope at the next sample —
doesn't.)

Backward walk to find `b`: dual.

1. For `k = 1, 2, …`, let `x = length - k · step`, `y = applyFactors(x)`.
2. Compute secant slope to the right anchor: `g = (length - y) / (length - x)`.
3. If `g ∈ [1/K, K]`, take this `(b, yb) = (x, y)` and stop.

Walk lengths in practice: 1–10 samples per side. Most composites' near-
endpoint behaviour places the secant in bound on the first step.

## Degenerate cases

**`a ≥ b` — ramps would overlap.** Possible only with extreme
combinations of tilt + id-shift + phase. Fall back to a 2-point
identity Shape: `eval(x) = x`, `invert(y) = y`. Acceptable because
this case is structurally pathological — no useful ramp could pin both
endpoints with K-bounded slopes.

**`length ≤ 0`.** Degenerate Shape with `a = b = 0`, `ya = yb = 0`.

**Identity composite.** No factors → `a = step`, `b = length - step`,
`ya = a`, `yb = b`. Eval reduces to identity in all three regions.
(Or short-circuit: skip Shape construction, return a sentinel.)

## Worked examples

### 1. Classic-58, tile-aligned length (4 QN at ppqPerQN=240, L=960)

`applyFactors(0) = 0`, `applyFactors(960) = 960`. Forward walk: at
`x = 4`, `y = applyFactors(4) ≈ 4 · 1.25 = 5.0` (slope 1.25 from
classic), so `g = 5/4 = 1.25 ∈ [1/60, 60]`. Stop. `a = 4`, `ya = 5`.

Ramp-on slope 1.25 — matches the natural local slope. Continuous with
the middle to the precision of a 4-PPQ step.

Backward likewise stops at `b = 956`, `yb = 955`. Middle covers
`[4, 956]` and is bare `applyFactors`. This is today's `naturalPin`
case; the new design subsumes it without a special branch.

### 2. id-shift, a = 0.1, period 1, L = 960

`applyFactors(x) = x + 24` in interior tiles (T = 240, a · T = 24).

**Forward.** At `x = 4`, `y = applyFactors(4) = 28`. `g = 28/4 = 7`.
In bound. Stop. `a = 4`, `ya = 28`. Ramp-on is `f(x) = 7x` on `[0, 4]`.

**Backward.** At `x = 956`, `y = applyFactors(956) = 980`.
`g = (960 - 980)/(960 - 956) = -5`. Out of bound (negative). Step.

At `x = 952`, `y = 976`. `g = (960 - 976)/8 = -2`. Out of bound. Step.

Continue. The natural y is `x + 24` always; the secant slope to
`(960, 960)` is `(960 - x - 24)/(960 - x) = 1 - 24/(960 - x)`. This
reaches `1/60` when `960 - x = 24 · 60 / 59 ≈ 24.4`, i.e.
`x ≈ 935.6`. Walk takes ⌈24.4 / 4⌉ = 7 steps. `b ≈ 936`,
`yb ≈ 960`.

Ramp-off: line from `(936, 960)` to `(960, 960)` — slope 0. But
slope 0 is below `1/60`. So the walk continues one more step where
the secant slope re-enters bound; settles at the first `b` where
`(960 - yb)/(960 - b) ≥ 1/60`. The middle carries the +24 PPQ delay;
the trailing ramp gives that delay back over the final ~24 PPQ at
the minimum slope.

### 3. Composite phase φ = 0.10 QN, classic shift 0.08, L = 960

The classic lattice rotates by 24 PPQ. `applyFactors(0) ≠ 0` —
typically a small positive value. Forward walks until the secant
from origin lands in bound, absorbing the rotation. Mirror at the
right end. Middle is the rotated `applyFactors` verbatim.

### 4. Mixed period — id shift 0.05 period 4 + classic shift 0.08 period 1

LCM period 4 QN. Tile structure has corners every 1 QN (classic) and
every 4 QN (id). Forward walk runs against whichever corner is
closest to x=0; backward dual. Walks terminate within a few samples.

## Inverses

`unapplyFactors(factors, y)` walks factors in reverse:

- For atoms with closed-form inverse (classic, pocket, lilt, tilt, id):
  `M.atoms.X.inverse(unit_y, shift)` — O(1) per factor.
- For shuffle: binary search in the factor's pre-sampled inverse PWL —
  O(log (60 · period_QN)) per factor, ≈ 6–8 comparisons.

The shuffle PWL inverse lives on the resolved factor (built once per
`resolveComposite` call). Atom-level state is stateless functions; the
PWL belongs to the composite's resolved factor list.

## What gets deleted

- `sampled`, `SAMPLES`, `SAMPLES_ID` — atoms aren't pre-sampled.
- `clonePrefix`, `gatherBreakpoints`, `buildExtendedPWL` — no
  candidate set is needed; ramps are linear.
- `walkFront`, `walkBack`, `clipToLength` — corner walk replaced by
  the secant walks.
- `buildLeadingClip`, `buildTrailingClip` — replaced by ramp construction.
- `naturalPin` and the short-take branch — both subsumed by the
  uniform ramp + middle structure.

`M.compose`, `M.tile`, `M.tileInverse`, `M.applyFactors`,
`M.unapplyFactors`, `M.findShape`, `M.isIdentity`, period helpers —
all unchanged in signature.

## Per-call cost

Per `resolveComposite` call (one slider tick):

- Two ramp walks: ~1–10 samples each side. Each sample is one
  `applyFactors` call (arithmetic only) plus a comparison. ~50 ops.
- Per shuffle factor: build a `60 · period_QN`-point inverse PWL.
  ~120 ops for typical period-1 shuffle, zero if no shuffle.

Per event eval (one of N events being reswung):

- Region dispatch: 2 comparisons.
- Ramp regions: one multiply, one divide.
- Middle: `applyFactors` arithmetic, no PWL search. ~5 ops/factor.

Per event invert: same shape; non-shuffle middle is closed-form arithmetic;
shuffle middle is one binary search per shuffle factor.

For a 100-event take with single-factor classic composite, slider
drag at 60fps:

- Composition: ~50 ops × 60 = 3K ops/sec.
- Reswing eval: 100 events × 5 ops × 2 directions × 60 = 60K ops/sec.

Lua at ~10M ops/sec ⟹ < 1% of one frame. Two orders below the current
clipped-path cost.

## Order of work

1. **Atom function rewrite.** Replace each `M.atoms.X` with a struct
   `{ forward, inverse }`. Closed-form forward + inverse for classic,
   pocket, lilt, tilt, id. Shuffle gets `forward` only plus a
   monotonic-and-endpoint-preserving guarantee. Spec: forward and
   inverse are unit-interval homeomorphisms with slopes in K-bound for
   in-range shifts; `forward ∘ inverse = identity` within ε.

2. **New `applyFactors` / `unapplyFactors`.** Call atom functions
   directly with tile bookkeeping. For shuffle factors,
   `unapplyFactors` consults the resolved factor's pre-built inverse
   PWL. Spec: agrees with the old PWL-based path on a sweep of
   composites.

3. **Ramp walks.** `findRampOn(factors, length, ppqPerQN) -> a, ya`
   and `findRampOff(...) -> b, yb`. Stop when secant slope is in
   `[1/K, K]`. Cap at `length / step` iterations as a safety. Spec:
   secant bound holds, monotonic, terminates.

4. **New `resolveComposite`.** Assembles the Shape `{ factors, a, b,
   ya, yb, length }`. Builds shuffle inverse PWLs onto resolved
   factors. Handles `a ≥ b` degeneracy. Spec: existing composite
   specs (endpoints pinned, K-bound, round trip, delay presets,
   composite phase additivity, mixed-period round trip) all pass.

5. **Delete dead code:** `sampled`, `SAMPLES`, `SAMPLES_ID`,
   `clonePrefix`, `gatherBreakpoints`, `buildExtendedPWL`,
   `walkFront`, `walkBack`, `clipToLength`, `buildLeadingClip`,
   `buildTrailingClip`, `naturalPin` branch.

6. **Performance check.** Drop `reaper.time_precise()` brackets around
   `tm:swingSnapshot`, `vm:reswingPreset`, and the editor draw.
   Slider drag should be smooth on every preset.

No external module changes — `applyFactors`, `unapplyFactors`,
`resolveComposite`, `eval`, `invert` keep their signatures. Spec
rewrites are local to `tests/specs/timing_atoms_spec.lua` and
`tests/specs/timing_composite_spec.lua`.
