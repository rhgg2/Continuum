# fx dest + unit domains — plan

> No design doc: this programme was designed in conversation
> (2026-07-25) and this file is the record. Decisions below are
> settled; if one needs reopening, do it here and say so.
> Complete, closed 2026-07-26 — all three commits landed 2026-07-25.

## The problem

`dest` is kind metadata — `generators.kinds[kind].dest` is
`'note' | 'pb' | <ccNumber>` — and for continuous kinds it's advisory
with no way to change it. Two consequences:

- You can't point a modulator at a different controller.
- `vibrato` and `autopan` are literally the same function. `autopan`
  is `vibrato` with `onset = 0`: same anchor breakpoint, same
  `startL + period/4 + k·period/2` extrema walk, same terminal
  re-centre, and `vibrato`'s `gain` evaluates to 1 when `onset` is 0.
  Identical output, two registry entries.

Whether a cc↔pb swap is coherent turns out to be a property of the
generator, not of dest. Relative generators (signed delta around rest
— the merged sine) swap cleanly, since the fold sums the delta onto
whatever base the target has. Absolute generators (`lfo`, whose
`centre = 64` is cc mid-scale) need per-domain defaults, not just a
retarget. `slide` is pb-bound by meaning: `target = 'next'` is the
interval to the next same-lane note, which has no cc reading.

`lfo` is the precedent for the whole design — its curve body is
already normalized ±1 and mapped by `centre + scale × norm`. The only
thing wrong with it is that the mapping is hardcoded to cc.

## Decisions

**D1 — `dest` becomes a per-entry param, seeded from the kind.**
`fxSeed` stamps it; every read goes through
`generators.destOf(params)` returning `params.dest or
kinds[params.kind].dest`. The registry keeps `dest` as both the seed
and the note-vs-continuous class marker. The fallback also keeps the
existing spec fixtures green (they register kinds with a registry
`dest` and entries with no `dest` param).

**D2 — each kind declares which dests it can serve.** One declaration
answers three questions — does a dest row appear, what's in the
picker, is a swap coherent:

- `sine` → `'any'` (pb + CC 0..127)
- `lfo` → `'cc'` (128 options, so still a row)
- `slide` → `'pb'` (one option ⇒ no row, as today)
- note kinds → no declaration, no row

**D3 — the dest row is synthesised in one place.**
`generators.fieldsFor(entry)` returns the dest row (when there's a
choice) followed by the kind's own fields; `stripColumns` in
trackerRender calls that instead of reading `.fields` directly, and
keeps its existing `fd.when` filtering. Not repeated per registry
entry.

**D4 — the widget is a `chrome.drawPicker` typeahead**, new
`widget = 'dest'`, picker kind `'fxDest_' .. index`. Items: Pitch Bend
+ CC 0..127. **Bare `CC 74` labels** — there's no CC-name table in the
repo and no second consumer for one. In `adjustRow`, Left/Right opens
the picker (as `pattern` does) rather than stepping.

**D5 — merge vibrato and autopan into `sine`.** Key `sine`, label
`Sine`; `dest` defaults `pb`; fields `dest, period, depth, onset`.
Auto-pan becomes "Sine → CC 10" and gains a ramp-in for free. Delete
`autopan`. Relabel `lfo` to `Curve LFO` so the two read as siblings
(key stays `lfo`). Pre-beta, so no compat guard — but existing
`kind='autopan'` entries in live projects stop resolving.

One merged kind carries one `frac`, and it is vibrato's `0.15`:
auto-pan's old `0.5` would read as 100 cents on the merged kind's own
dest. So a sine retargeted to CC 10 defaults to 9 steps, not 32 —
seeding at a dest and retargeting to it now agree, which is the point
of D7, and the cost is that auto-pan's out-of-the-box motion is a
quarter of what it was.

**D6 — dest profiles are first-class, and generator bodies stay
unit-naive.** *(revised 2026-07-25: the table was per-domain and is
now per-dest — see D11 for why. `range` and `fullScale` are gone, and
`level` never arrives at all — see D13.)*

```lua
--shape: destProfile = { unit, rest, bipolar, magScale }
-- generators.destProfile(dest) -> profile      (dest = 'pb' | <ccNumber>)
--   pb -> { unit = 'cents', rest = 0, bipolar = true, magScale = PB_REFERENCE }
--   cc -> rest     = generators.ccDefaultRest[dest] or 0
--         bipolar  = rest > 0 and rest < 127
--         magScale = bipolar and math.min(rest, 127 - rest) or math.max(rest, 127 - rest)
```

Profile knowledge lands in exactly three places: field range/label
resolution for the strip (`generators.fieldRange(fd, dest)`), value
rescaling on retarget (D8), and the fold's rest seed. That last is a
consolidation — `trackerManager` reaches for `generators.ccDefaultRest`
and a `rest` override in *two* places, the fold (:3046) and the cc
emission base (:3267); both move behind
`generators.restFor(dest, override)`. `sine`'s body doesn't change at
all: it still emits `sign * gain * depth`, because `depth` is already
in the target's units by the time the body sees it.

**D7 — fields declare a quantity, not hard numbers.**

- `quantity = 'magnitude'` — a span away from rest (`sine.depth`,
  `lfo.scale`, `lfo.offset`), optionally `signed` (D13)
- no `quantity` — fixed-unit, behaves exactly as today
  (`slide.cents`, everything note-dest)

*(revised 2026-07-25: there was a third, `quantity = 'level'` — an
absolute position in the domain, `lfo.centre` → 64 on cc, 0 on pb.
D13 removes it, and with it the second per-dest reference it needed.)*

Defaults arrive as a fraction of full scale (`frac = 0.15` → 30 cents
on pb, ~9 steps on cc), so one declaration reads correctly on every
target. This is the surface a user-scripted generator gets for free:
`dests = 'any'` plus `quantity = 'magnitude'` is correct everywhere
without ever learning what pb is.

**D8 — retarget rescales by proportion of full scale.** Identity
within a domain (CC 10 → CC 1 must never disturb `depth`);
proportional across domains (30 of 200 cents → 9 of 63 steps). Not
reseed-to-default.

**D9 — pb's `range` and `fullScale` are different numbers with
different jobs.** `range` is `±ctx.pbRangeCents`, the honest wire
limit, used for clamping. `fullScale` is a fixed musical reference —
`PB_REFERENCE = 200` cents, a whole tone — used only for defaults and
rescaling. Tying scaling to the take's bend range would make a
retargeted cc depth of 63 into a 1200-cent vibrato on a 12-semitone
take, and would mean the same stage sounded different in two takes.
`PB_REFERENCE` starts as a module constant; promote to config only if
it proves to want to be per-take.

**D10 — no per-domain min/max on `depth` beyond what D6/D7 give.**
Over-wide values flatten at the rails rather than erroring: cc
emission clamps to 0..127 at the seat.

**D11 — polarity is a property of the dest, and `ccDefaultRest`
already encodes it (settled 2026-07-25).** A controller resting
mid-scale is bipolar; one resting at a rail is unipolar. That single
fact answers the 63-or-127 question *and* the curve editor's
unipolar/bipolar axis, which is why it can't live on the domain — on
cc, "it depends".

| dest | rest | polarity | `magScale` |
|---|---|---|---|
| pb | 0 | bipolar | 200 (`PB_REFERENCE`) |
| cc 10, 8, 71–79 | 64 | bipolar | 63 (the symmetric swing) |
| cc 1, and most | 0 | unipolar | 127 (the whole run from the rail) |
| cc 11 (expression) | 127 | unipolar, inverted | 127 |

Three riders:

- **Polarity derives from the controller default, never from a `rest`
  override.** `region.fx.rest` can sit anywhere (a spec pins 100 on
  CC 10); if polarity read it, that override would silently move
  `magScale` to 27 and change how every later retarget rescales. The
  override steers the fold seed and nothing else.
- **This supersedes D8's worked identity example.** CC 10 → CC 1 is
  no longer an identity, because those dests now have genuinely
  different references: a pan depth of 32 becomes 65 on the mod
  wheel — the same proportion of available swing. Identity survives
  where the reference matches (CC 10 → CC 8), which is D8's principle
  with its corollary corrected.
- **A bipolar generator on a unipolar dest clips**, and that's
  accepted (D10): `sine` on CC 1 spends the bottom half of each cycle
  on the rail. Teaching the fold to ride the delta upward is real
  machinery and belongs with commit 2, if anywhere.

**D12 — seeding, retarget and rest, one line each (settled
2026-07-25).**

- `generators.seed(kind)` stamps `kind`, `dest` and the resolved
  defaults; `trackerRender`'s `fxSeed` (:874) becomes a call to it.
- A quantity field's default arrives as `frac` **on the field
  descriptor**, next to `quantity` (same thought: how to read the
  number, and where it starts in that reading). `defaults` keeps the
  fixed-unit params.
- `generators.retarget(entry, dest) -> entry` is pure and
  identity-guarded on equal `magScale`, not on arithmetic. The picker
  applies it through the existing `tv:replaceFxStage`; the undo point
  reads "Swap FX stage", which is honest — it is a stage rewrite.
- `generators.restFor(dest, override)` takes a **scalar** override,
  not the `fx` table, so the fold site (which holds `producer.fx.rest`)
  and the emission site (which holds `firstRestOverride(recs)`) read
  identically.

**D13 — there is no `level` quantity; `lfo.centre` becomes `offset`, a
signed magnitude from rest (settled 2026-07-25).** The fold has two
contracts, not one: `replace` takes a stage's curve as the channel's
absolute position, `augment` lays down the dest's rest and sums the
delta onto it (`trackerManager.lua:3041-3048`). So mode and quantity
are the same question at two scales — `replace` states a position,
`augment` states a displacement — and a kind's fields should agree with
its mode. `lfo` is `augment` carrying a positional `centre`, and that
disagreement *is* the CC-10 bug: rest 64 + centre 64 pins the curve to
the top rail. It has been reachable since 1a opened the Dest row.

Flipping `lfo` to `replace` fixes the arithmetic and costs too much: a
replace stage on pb flattens detune inside its window, a coexistence
`tm_fx_region_spec` pins at "curve 30c + detune 25c". So the mode
stays and the positional param goes instead. `offset` is a signed
magnitude, default 0, meaning "displace the whole cycle this far from
rest" — an affordance so a baseline needn't be authored as a single CC
value by hand. What follows:

- `level` never gets built, so D7 drops to two quantities.
- `destProfile` stays exactly as 1a shipped it. A level would have
  needed a *second* per-dest reference — the 0..127 rails, distinct
  from swing, since pan's swing is 63 while its travel spans 127 — and
  that reference now goes undefined.
- A magnitude may be `signed`, which `offset` and `scale` both are;
  bounds become `-magScale .. magScale`. A negative scale mirrors the
  curve, which was already `lfo.scale`'s `min = -127`.
- A dest resting at a rail clips half the cycle at offset 0. That is
  D11's third rider, already accepted for `sine`.

**D14 — the curve editor's polarity belongs to the kind, not the dest
(settled 2026-07-25).** A curve is drawn around its own zero, and for
`lfo` that zero sits at `rest + offset` — wherever the user put it. A
mod-wheel LFO with offset 64 needs a pen that goes below the line even
though CC 1 is unipolar, and `generators_spec` pins exactly that (norm
−1 → the low value). So `destProfile(...).bipolar` answers only "how
far can this controller move from rest, and symmetrically?", never
"may the authored shape go negative". `curveDisplay`'s unipolar branch
stays unreached; it would be earned by a kind whose curve is an
envelope *from* rest, and no such kind exists. `generators.lua:395`'s
hardcoded `display = 'bipolar'` stands.

## Commits

1a. **dest becomes a param** — the mechanism, production-only. See
   § Commit 1a.
1b. **The merge.** `sine` = vibrato ∪ autopan (`dests = 'any'`,
   fields `dest, period, depth, onset`), `autopan` deleted, `lfo`
   relabelled `Curve LFO`, `gridPane`'s `FX_GLYPH` key, and the
   ~100-line `kind='vibrato'|'autopan'` sweep across 14 spec/fixture
   files (plus `tm_vibrato_spec` → `tm_sine_spec` and its
   `tests/run.lua` entry). Split from 1a so a bisect over a mechanical
   rename doesn't drag the design change with it.
2. **`lfo` off CC 1.** `centre` → `offset` (signed magnitude),
   `scale` gains `quantity = 'magnitude'` + `signed`, `lfo.dests`
   opens to `'any'`, and the body's `0..127` clamp goes. Costs nothing
   in the pattern editor — the normalized body substrate is already
   dest-blind — and nothing on CC 1 either, where rest 0 makes the old
   absolute reading and the new displacement reading coincide.

## Landed

- 2026-07-25 gen: lfo takes any dest, centre becoming a signed offset
  (commit 2, brief below). The programme's three commits are all in;
  `plan/CURRENT` names no live plan, so there is nothing queued behind
  this one.
- 2026-07-25 gen: merge vibrato and autopan into one dest-blind sine
  kind (commit 1b). Commit 2 then reopened D6/D7 in conversation before
  any of it was written: `level` is gone (D13), and the curve's
  polarity turns out not to be the dest's (D14). Brief below.
- 2026-07-25 gen: dest becomes a per-entry param with domain profiles
  (commit 1a, brief below).

## Commit 2: `lfo` off CC 1 (landed)

**What and why.** `lfo` is the last kind whose numbers only make sense
on one dest: `centre` reads as an absolute cc position, and the augment
fold then sums it onto the dest's rest, which is coherent only because
CC 1 rests at 0. `centre` becomes `offset`, a signed displacement from
rest (D13), and `dests` opens to `'any'`. On CC 1 nothing changes
numerically, so the commit is a rename plus the removal of a clamp,
with pb and the bipolar CCs arriving as the observable.

**Registry (`generators.lua:392-401`).** `mode` and `label` unchanged.

- `dests = 'any'`.
- `defaults` keeps `period` and `pattern`, loses `centre` and `scale`.
- `offset` — `quantity = 'magnitude'`, `signed = true`, `frac = 0`,
  label `Offset`. Zero needs no reference, so `frac = 0` resolves to 0
  on every dest while keeping the declaration next to `quantity`
  (`seed`'s `if fd.frac` is Lua-truthy on 0).
- `scale` — `quantity = 'magnitude'`, `signed = true`, `frac = 0.5`:
  64 on CC 1 (today's 63, within a rounding step), 100 cents on pb,
  32 on CC 10.

**Body (`generators.lua:259-287`).** `offset` and `amp` replace
`centre` and `amp`; `ccVal` becomes a dest-blind
`val(norm) -> util.round(offset + amp * norm)`. The `0..127` clamp
goes — it is dest knowledge inside a body that holds none, and the cc
seat already clamps (`trackerManager.lua:3277`). Both `--contract:`
lines above it get rewritten: they name cc, centre and the clamp.

**`generators.fieldRange` (`:456`).** A signed magnitude spans both
ways — `local mag = destProfile(dest).magScale; return fd.signed and
-mag or 0, mag`. `seed` and `retarget` need no change: `seed` reads the
second return, and `retarget` already rescales every magnitude field,
carrying sign through unharmed.

**`--shape: field` (`:14`)** gains `signed?`.

**Fixtures — a key rename, same values.** `glasswork.lua:59` and
`glasswork_dense.lua:34` carry `centre=60, scale=52` on CC 1; both
become `offset=60, scale=52` and emit 8..112 exactly as now.
`tm_fx_tension_spec.lua:80`'s `centre = 0, scale = 0` becomes
`offset = 0`, still a contribution of exactly zero (its header comment
at `:4` says "scale-0 lfo", which stays true).

**Red first,** all in `tests/specs/generators_spec.lua` (`:401-443`):

1. `lfo` on pb emits cents: offset 0, scale 100, triangle → ±100 at
   the extrema. Red today — the body clamps to 0..127.
2. The clamp case at `:425` inverts: offset 64, scale 100 emits −36 at
   norm −1 instead of clamping to 0. Retitled to pin that the body
   does *not* clamp.
3. `fieldRange` on a signed magnitude returns `-magScale, magScale`.
4. `retarget` carries `scale` pb → CC 10 as 100 → 32, and sign
   survives: −100 → −32.

The existing tiling case at `:404` isn't red; under the rename it
keeps its 1..127 and stands as the proof that CC 1 is unaffected.

**Done looks like.** Suite green. In REAPER a Curve LFO's strip reads
Dest / Curve / Period / Offset / Scale; retargeted to CC 10 the pan
wobbles symmetrically about 64 instead of pinning at the top rail, and
retargeted to pb it gives curve-shaped pitch modulation that coexists
with detune.

**The open choice, settled `'pb'`.** A fresh `lfo` now starts bipolar at
rest with nothing clipped. Three sites needed an explicit `dest = 1`,
not two: both glasswork fixtures and `tm_fx_tension_spec.lua:80`, which
leaned on the registry fallback to reach CC 1 and is *about* cc-base
tension, so it has to name the dest it means.

**One rounding artefact.** `util.round` is floor-half-up, so a signed
magnitude landing on an exact half rescales asymmetrically: scale 100
pb → CC 10 gives 32, but −100 gives −31. Pinned as −31 rather than
teaching `retarget` to round by absolute value — it is half a cc step,
and a symmetric-rounding helper would be a repo-wide call, not a local
one.

**Not in 2.** No mode change (D13 rules `replace` out on pb's
account). No `level` quantity, no domain rails, no `destProfile`
change. No `display` derivation (D14).

## Commit 1a: dest becomes a param (landed)

**What and why.** `dest` moves from kind metadata to a per-entry
param so a continuous stage can be pointed at a different controller,
and the domain knowledge that makes a swap coherent lands in one
place. Nothing is merged or renamed here: `autopan` grows a Dest row
and retargets, and that is the whole commit's observable.

**Added to `generators` (all pure):**

```lua
local PB_REFERENCE = 200   -- cents, a whole tone: fixed musical reference, not the take's bend range (D9)

generators.destOf(params)          -> 'note' | 'pb' | <cc>   -- params.dest or kinds[params.kind].dest
generators.destProfile(dest)       -> { unit, rest, bipolar, magScale }      -- D11
generators.restFor(dest, override) -> num                    -- override or profile.rest
generators.destsFor(kind)          -> { 'pb', 0, 1, ... }    -- from kinds[kind].dests; <2 entries = no row
generators.fieldRange(fd, dest)    -> min, max               -- magnitude: 0, magScale; else fd.min, fd.max
generators.fieldsFor(entry)        -> { fd, ... }            -- dest row (when there's a choice) then the kind's
generators.seed(kind)              -> entry                  -- kind + dest + resolved defaults (D12)
generators.retarget(entry, dest)   -> entry                  -- proportional rescale (D8/D11)
```

**Registry changes (1a only).** `dests` on the continuous kinds:
`vibrato = 'pb'`, `slide = 'pb'`, `autopan = 'cc'`, `lfo = 'cc'`;
note kinds declare nothing. `vibrato.depth` and `autopan.depth` gain
`quantity = 'magnitude'` and lose their literal default and min/max:

- vibrato `frac = 0.15` → 0.15 × 200 = **30** (today's default), range
  0..200 (today's min/max)
- autopan `frac = 0.5` → 0.5 × 63 = 31.5 → **32** (today's default),
  range 0..63 (today's min/max)

Both reproduce today's numbers exactly, and that equivalence is the
sanity check that `magScale` is the right reference.

**The synthesised dest row** (D3/D4), prepended by `fieldsFor`:

```lua
{ field = 'dest', label = 'Dest', widget = 'dest' }
```

Picker kind `'fxDest_' .. index`; items `Pitch Bend` (key `'pb'`,
group 1) then `CC 0` … `CC 127` (key the number, group 2), bare
labels (D4).

**Call sites** (verified against HEAD, 2026-07-25):

- `generators.lua:445` `parksNotes`, `:456` `continuousTargets`,
  `:466` `chainDestType`, `:489-490` `parkWindows` — every `meta.dest`
  becomes `destOf(params)`.
- `trackerManager.lua:3037-3053` `foldContinuous` — takes the resolved
  dest (`foldContinuous(dest, mode, out)`); its rest seed at `:3046`
  becomes `generators.restFor(dest, producer.fx.rest)`.
- `trackerManager.lua:3055-3070` — the stage loop resolves
  `local dest = generators.destOf(params)` once and branches on it.
- `trackerManager.lua:3267` —
  `firstRestOverride(recs) or generators.ccDefaultRest[cc] or 0`
  becomes `generators.restFor(cc, firstRestOverride(recs))`.
- `trackerRender.lua:874` `fxSeed` → `generators.seed`.
- `trackerRender.lua:994-1007` `stripColumns` — iterate
  `generators.fieldsFor(entry)`, keeping the `fd.when` filter.
- `trackerRender.lua:923-942` `adjustRow` — a `dest` branch opening
  the picker (mirrors how `pattern` arrows into its editor); the
  numeric branch clamps via `generators.fieldRange`.
- `trackerRender.lua:946-967` `fxFieldWidget` — a `dest` branch
  drawing `chrome.drawPicker{ kind = 'fxDest_' .. index, width = width, … }`
  with `onPick = function(d) tv:replaceFxStage(host, index, generators.retarget(entry, d)) end`;
  the stepper's bounds likewise via `fieldRange`.

**Red first.** In `tests/specs/generators_spec.lua` (pure, no
harness — it already registers fixture kinds inline, e.g. `:139`):

1. `destOf` falls back to the registry dest; a `dest` param overrides
   it.
2. `fieldsFor` prepends a Dest row for `autopan` (`dests='cc'`), and
   omits it for `retrig` (no declaration) and `slide` (`dests='pb'`,
   one option) — D2/D3.
3. `retarget` between dests of equal reference is value-identity:
   CC 10 → CC 8 leaves `depth = 32`.
4. `retarget` rescales by proportion of `magScale`: pb `depth = 30` →
   CC 10 gives 9; CC 10 `depth = 32` → CC 1 gives 65 (D11's corrected
   corollary).
5. `parkWindows` follows the param: an entry with `dest = 74` over a
   pb-registry kind yields a cc-74 window, not a pb one.

In `tests/specs/tm_fx_region_spec.lua` — the one that leans hardest
on existing machinery (the `prevWindows` window-diff reconcile), so
the one that most needs pinning; helpers `injectRegion` and
`ccFillAt` are already in the file (see the CC-rest cases ~`:1580-1615`):

6. **Retarget restores and re-parks.** A region `autopan` on CC 10,
   rebuilt; then its entry rewritten with `dest = 1`. CC 10's base
   automation comes back over the window and CC 1 parks in its place.

**Done looks like.** Suite green. `map_query kind='reads' query='dest'`
shows no `kinds[...].dest` read left outside `destOf`. In REAPER: an
`autopan` stage's strip reads Dest / Period / Depth, ←/→ on Dest opens
a 129-item typeahead, and picking `CC 1` restores the pan automation,
seats a mod-wheel stream, and steps Depth 32 → 65.

**Not in 1a.** No kind renamed or deleted, no fixture touched,
`gridPane`'s `FX_GLYPH` untouched — all of that is 1b.

## Site inventory (gathered 2026-07-25, re-verified against HEAD the
same day)

Five reads of `kinds[...].dest`, all of which become `destOf`:

- `generators.parksNotes` — does this chain park its chord
- `generators.continuousTargets` — the pb/cc target set
- `generators.chainDestType` — replace vs augment per target
- `generators.parkWindows` — a cc window per cc target, pb per pb
- `trackerManager.lua:3055-3070` — the fold: note branch vs
  `foldContinuous(meta, out)`, which keys the stream on `meta.dest`

Nothing else in the repo reads it (`gridPane`'s `destSrc` is the drag
preview, unrelated; `trackerView:2798`'s `destDescriptor` is routing).

Supporting facts:

- `tv:setFxField` (trackerView.lua:2515) is fully generic, and fx
  entries persist as plain tables (`fxMeta` / `fxRegions`), so a new
  param needs no plumbing at either end.
- cc emission clamps to 0..127 at the seat
  (`trackerManager.lua:3277`).
- The strip already hosts `chrome.drawPicker` rows (kind-swap header,
  add row) — a dest row will look native.
- `patternEditor` curve bodies already carry `domain = 'normalized' |
  'cc'`; normalized points are ±1, edited as pb thousandths
  (patternEditor.lua:125-148).
- `ccDefaultRest` has **two** consumers, not one: the fold
  (`trackerManager.lua:3046`) and the cc emission base (`:3267`,
  behind `firstRestOverride`). Both move behind `restFor` (D12).
- Spec fixtures registering kinds with a literal `dest`: ~40 of them
  across `tm_fx_region_spec`, `tv_fx_region_spec`, `vm_fx_ui_spec`
  and `generators_spec:139`. All stay green on D1's registry
  fallback, which is why that fallback is load-bearing rather than
  cosmetic.
- The unipolar/bipolar curve axis is already wired and merely never
  driven: `patternEditor.lua:135` sets
  `bipolar = body.display ~= 'unipolar'`, and `trackerView` honours it
  at `:853` / `:1025` (refuse a `-` sign) and `:2193` (bound
  `-1000..1000` vs `0..1000`). Nothing ever produces `'unipolar'` —
  `generators.lua:419` hardcodes `display = 'bipolar'` on `lfo`'s
  body. Commit 2 derives it from the dest instead (D11).
- Rename blast radius for 1b: `vibrato`/`autopan` appear in 16 Lua
  files (~100 lines) — both `glasswork` fixtures, `tm_vibrato_spec`
  (file name + `tests/run.lua` entry), seven other tm specs,
  `vm_fx_ui_spec`, `tv_fx_region_spec`, and `gridPane.lua:166`'s
  `FX_GLYPH`.

## Not doing

- CC name table (bare numbers, D4).
- Per-field `perDest` data blocks — the rejected alternative A; D6/D7
  is the same job done once.
- Fully normalized params with display-time conversion — rejected
  alternative C: it forces every body through the domain and makes the
  UI say "depth 15%".
- A `level` quantity, and the domain rails it would have needed as a
  second per-dest reference (D13).
- Driving `curveDisplay`'s unipolar branch from the dest (D14); it
  waits on a kind whose curve is an envelope from rest.
