# pb interpolation — value-aware absorber seats and densification

> Plan doc. Fixes a live bug in authored pitch-bend interpolation, and in
> doing so builds the primitive the macro work needs for continuous-pb
> replace. Step 1 (here) stands alone — no generators. Step 2 is owned by
> `design/note-macros-v2.md` § Continuous pb replace and only consumes
> what Step 1 lands.

## The problem

`rebuildPbs` (`trackerManager.lua:1957`) seats derived pb breakpoints —
"absorber" seats — at every lane-1 detune jump, to step the channel-wide
pb stream to each note's detune. Each seat is born **value-blind**:
`cents = 0`, so its wire raw is `centsToRaw(0 + detune)` — pure detune,
no value (lines 2078 / 2081–2082 / 2085).

That assumption — *nothing of value passes through a seat* — is false the
moment an authored pb glide spans the seat. The two authored breakpoints
want to interpolate cents₁→cents₂ through the seat ppq M; instead the seat
punches the wire down to detune-only at M (and, marked step/hidden at
2126, it was never meant to sit mid-curve). The authored value at M is
discarded.

Net: **you cannot interpolate an authored pb across a detune onset.** A
live bug today, with no generator anywhere near it.

## The fix primitive

A derived pb seat should **sample the prevailing value stream at its ppq
and add detune**, instead of assuming 0:

```
val = centsToRaw(streamValue(ppq) + detune)
```

where `streamValue` is the authored breakpoints' own interpolation. When
generators land, a replace region swaps `streamValue` for its curve — same
primitive, different source. This doc builds the primitive; note-macros-v2
consumes it.

## The approximation — densification

Sampling is exact only for **linear** authored segments: the seat lands on
the line. For a curved shape (slow start/end, fast start/end, bezier) you
cannot split the segment at an arbitrary M and reuse REAPER's fixed-tension
shapes on each half — the first half of an S-curve is not an S-curve. So a
seat inside a curved segment forces that segment to be re-expressed as a
**densified linear polyline** approximating the original curve. Three
disciplines keep it honest:

1. **Densify realisation only.** Authored breakpoints keep their sparse
   cents *and* shape for display / edit / round-trip; the densified
   polyline is derived (`derived='absorber'`), hidden from columns exactly
   as today's seats are. The two-number pb breakpoint — `cents` (display)
   vs wire raw — is what lets the column still show the user's two-point
   smoothstep while the wire carries the approximation. Notes and cc have
   one number and so must park; pb never does.
2. **Fixed logical-ppq grid, not curvature-adaptive.** Adaptive sampling
   moves points between rebuilds → reconcile churn (the canon-ppq / G4
   lesson). A fixed grid keeps derived ppqs stable → churn-free.
3. **Densify only a curved segment that actually contains a seat.** A
   curved authored segment with no interior detune onset rides REAPER's
   native shape untouched — its wire events *are* the authored events.
   Densification is triggered by interior structure, never by curvature
   alone.

## Grid spacing and curve evaluation — reuse what we already have

Both halves are resolved (VERIFYs cleared):

- **Curve value — `mm:interpolate`.** mm events already carry `tension`
  (bezier only) and `curveSample(shape, tension, t)` (`midiManager.lua:129`)
  evaluates every shape. It is exposed as `mm:interpolate(A, B, ppq)`
  (`midiManager.lua:1097`; forwarded `tm:interpolate`), already driving
  view ghosts. `streamValue` reuses it — see Step 1.1. No mm projection
  change, no `MIDI_GetCCShape`.
- **Grid spacing — the item's `CCINTERP`.** REAPER's MIDI item properties
  carry a "CC envelope interpolation resolution" (wire ppq, default 32):
  the canonical density at which the host itself linearizes CC for that
  take. It lives in the item RPPXML chunk — read it with `GetItemStateChunk`
  + a `CCINTERP%s+(%d+)` match, the same chunk read mm already does for
  `POOLEDEVTS` (`midiManager.lua:32`) — `CCINTERP` sits directly above
  `POOLEDEVTS`, so one chunk read yields both. Cache it and expose
  `mm:ccInterp()` (fallback 32). The grid step is that many wire ticks between the two
  authored endpoints' ppqs. `CCINTERP` is realisation-ticks, yet the grid
  stays churn-free: it is deterministic from the (stable) authored endpoint
  ppqs — discipline 2's real requirement (fixed, not curvature-adaptive).

## Step 1 — authored pbs, no generators

Scope: make the absorber value-aware and densify curved segments under a
seat. Entirely within `rebuildPbs`; nothing above the manager moves.

1. **`streamValue` via `mm:interpolate`.** Interpolated cents at any ppq is
   `mm:interpolate(A, B, ppq, 'cents')` over the bounding authored pbs —
   `curveSample` is value-agnostic, so it honours linear / step / curved
   alike. The only mm change: add an optional `field` param defaulting to
   `'val'` (today's `.val` callers — view ghosts — are unaffected).
   Interpolate `cents`, **not** `val`: detune is added per-seat and must
   step at the onset, not blend across the segment.
2. **Grow `needed`.** Today `needed` = detune jumps. Add: for every
   authored segment that is *curved* **and** contains a detune onset, the
   fixed-grid sample ppqs across that segment (step = the item's `CCINTERP`,
   § Grid spacing). Detune onsets stay in
   `needed`; grid points join them. Linear segments add no grid points.
3. **Value the seats.** Each derived seat's value becomes
   `centsToRaw(streamValue(ppq) + detuneAt(ppq))`, replacing the `cents=0`
   at 2078 / 2081–2082 / 2085. A linear-segment seat needs no grid — one valued
   seat at the onset suffices.
4. **Preserve the detune step.** A detune jump must *step*, not ramp.
   Today seats are square/step-shaped, which holds flat after the seat —
   fine for a lone detune injector, wrong mid-curve. So densified seats go
   **linear**, and the step is made with a **dual seat at the onset**: a
   just-before point carrying `streamValue(onset) + oldDetune` and an
   at-onset point carrying `streamValue(onset) + newDetune`. The curve
   rides through both; detune jumps between them. (Linear-segment case: the
   dual point *is* the whole fix — no grid.)
   *Hide rule — a bodge this work removes.* The column-hide test
   `pb.derived and (shape == nil or shape == 'step')` (2126) surfaces a
   *shaped* derived seat on purpose: it was the cope for *attempting* to
   interpolate through an absorber — the seat became visible so the curve
   dead-ended at it instead of riding through. That is the exact failure
   Step 1 fixes; once seats carry the value through, a derived seat never
   needs to be visible. Change it to `hidden = pb.derived` (derived ⇒
   always hidden); the shape conditional *is* the symptom-patch we delete.
5. **Reconcile over the denser set.** The existing
   realAt / availAbsorbers / restamp / move / create / delete matching
   generalizes to the grown `needed`; keep keys on the stable grid ppqs so
   a steady rebuild does not churn.

Authored breakpoints, columns, the view surface, and the round-trip are
untouched — only the derived (hidden) wire stream changes.

## Step 2 — generator / replace curve (landed)

`streamValue` returns the generator's pb output inside a replace window and
the carrier is dropped: the curve rides the base lane through these same
seats, so `centsToRaw(curve(ppq) + detune)` seats the replace stream with no
add-bank slot. Retired one carrier per replace region and unified pb replace
with the value-aware-seat model. Landed in `trackerManager`'s `rebuildFx`
(producer split) + `rebuildPbs` (curve ingest + seats). See `design/note-macros-v2.md`
§ Continuous pb replace.

## Files

- `trackerManager.lua` — `rebuildPbs`: `streamValue` evaluator, grown
  `needed`, valued seats, dual-point step, reconcile over the denser set.
- `midiManager.lua` — add the optional `field` param to `mm:interpolate`
  so `streamValue` can interpolate `cents`; expose `mm:ccInterp()`, reading
  `CCINTERP` from the item chunk alongside the existing `POOLEDEVTS` read,
  cached, default 32. Tension already projected; no `MIDI_GetCCShape` work.
- `docs/tuning.md` § Absorber reconciliation — value-aware seats +
  densification.
- `tests/specs/` (`tm_*`) — pins below.

## Tests

- Authored **linear** glide across a detune onset → seat carries the
  interpolated value, not detune-only; wire is a straight line endpoint to
  endpoint plus the detune step.
- Authored **curved** glide across a detune onset → densified; endpoints
  exact, interior monotone-tracking the shape, no notch at the onset.
- **Detune step preserved** — the dual point steps detune without smearing
  it across the preceding grid cell.
- **Churn-free** — flush → rebuild → flush over a densified channel emits
  no spurious pb writes (stable grid keys).
- Authored curved segment with **no** interior onset → untouched (rides
  native shape, no derived seats inserted).

## Alternatives weighed

- *Per-seat value carry, no densification (linear-only).* Fixes linear
  glides; a curved segment gets one valued mid-point and stays kinked.
  Rejected — leaves the curved case visibly wrong, and densification is
  cheap and bounded.
- *Curvature-adaptive sampling.* Fewer points, but the points move between
  rebuilds → churn. Rejected for the fixed grid.
- *Let REAPER interpolate.* It only interpolates between adjacent CC events
  and won't carry our detune through. Not applicable.
