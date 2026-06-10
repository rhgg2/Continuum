# cv (working design)

> Working design doc, not yet built. Tracks the modulation/CV page as
> the form develops; will be split into `docs/` once stable. Sibling of
> `design/archive/wiring.md` — read that first; this doc leans on its
> vocabulary (user graph, targetTracks/allocate boundary, snapshot/diff/
> applier, live recompile, merge CU) and only states the deltas.

Cross-cutting reference for the **cv page**: a node graph, parallel to
wiring, whose subject is modulation rather than audio routing. Also
carries the **simple layer** — direct parameter automation with no
graph — which lands first and degenerates cleanly into cv. The
fourth page rung. Where wiring composes the audio/MIDI signal path, cv
composes a **control-voltage graph** — sources of modulation flow
through signal processors and land on parameters.

The two pages share a backend: both compile a user-drawn graph down to
the *same* REAPER audio/MIDI topology (FX on tracks, sends, pin maps).
The point of cv's design is to name what it shares with wiring, what it
replaces, and the refactor that makes the sharing honest.

## CV is audio

The load-bearing decision: **CV is an audio-rate signal.** A modulation
value is a sample stream, processed by JSFX exactly as audio is, and it
only narrows to block rate at the very last hop, where it reaches a
parameter. There is no separate "control rate" and no discrimination
between audio-rate and block-rate sources — an audio follower and a
slow LFO are the same kind of wire.

Everything lives in **one central processing graph** — a single host
where sources feed in, processors transform, and adapters fan out. One
graph is one coherent PDC/ordering domain for REAPER (no cross-track
send-ordering hazards), and it makes "the signal swirls around until it
pops out at a sink" literally true.

**No REAPER automation envelopes appear anywhere.** The only native
mechanism cv touches is parameter-modulation *linking* (`plink`), which
is distinct from the envelope/automation system. This is a hard
constraint, not an incidental choice.

## Sources, processors, sinks

Three node kinds, replacing wiring's `source | fx | master`:

- **`cvSource`** — an origin of modulation, rendered as a labelled wire
  stub (the wiring source-palette affordance). Backed by one of:
  authored data (below), a live audio input, or live MIDI. The graph
  doesn't care which — a source is a labelled CV output.
- **`processor`** — a JSFX that transforms or generates CV: LFO, slew
  limiter, low-pass gate, sample-and-hold, math/scaling. A generator
  like an LFO is a processor with no CV input.
- **`paramSink`** — a terminal that binds a CV wire to a target
  parameter. Replaces wiring's singleton `master`; a cv graph has
  *many* sinks. A sink variant, `ccSink`, writes 14-bit CC into a lane
  instead of linking a parameter (CC is a target as well as a source).

### Authored sources: location is origin, wiring is destination

Authored modulation is **14-bit CC in a MIDI take**, converted to
audio-rate CV by a **take FX** (a JSFX converter on the item). Take FX,
not track FX: a CV track can play several automation takes at once, and
each take carries its own converter.

Authored data has two homes, chosen by *lifetime*:

- **performance-bound** — part of a clip's performance, lives and dies
  with it, moves and duplicates with it. Home: a parallel take on the
  source's child track. (The per-take filter sweep authored alongside
  the notes.)
- **standing** — positioned in arrangement time independent of any
  clip. Home: free items on a dedicated CV track. (A swell across a
  section, regardless of which clips play.)

The rule that dissolves the "where does the data live" question:

> **Data location encodes origin and lifetime. Graph wiring encodes
> destination.**

These are different axes. Once a graph sits between source and target,
the origin and the destination are decoupled by construction — one
source fans out through processors to many sinks. So nothing about
*where the take lives* says *what it modulates*; that is read in the cv
graph. The spatial "automation sits next to its target" cue is not lost,
it moves into the graph view — which is the canonical place to read
what-drives-what anyway.

### Sinks: adapter + plink, never ACS, never envelopes

A `paramSink` reaches its target parameter through a **CV→slider
adapter JSFX** plus REAPER's native parameter link: the adapter reads
the CV channel and exposes its value as a slider, and the target
parameter is linked to that slider via
`TrackFX_SetNamedConfigParm(track, fx, "param.X.plink.{active,scale,
offset,effect,param}", ...)`. The link is linear and exact.

Two REAPER facts shape this:

- **Not ACS.** `param.X.acs.*` (audio control signal) is tempting —
  drive a parameter straight from sidechain audio, no adapter. But ACS
  is an *envelope follower* (attack/release/dblo/dbhi); it reads audio
  as a loudness envelope, not a bipolar CV value, so it mangles CV. The
  adapter + `plink` path is correct; ACS is the wrong tool.
- **plink is (assumed) same-track-only.** `param.X.plink.effect` is an
  FX index, and REAPER's link-source picker only offers same-chain FX.
  If that holds, the adapter must live **on the destination track**, so
  the graph's output stage is necessarily per-destination-track: CV is
  routed (as audio) to each target track, where a local adapter links
  the local parameter. The processing graph stays central and fans out
  to these adapters via sends. **This assumption gates the topology and
  is the first thing the spike verifies** (see below).

## The simple layer: direct parameter automation

cv's graph is overkill for "this column drives that cutoff". The
simple layer covers **same-track, performance-bound** parameter
automation with no graph, no routing, and no audio-rate CV — and it
lands before any cv code exists.

**Model.** Automation is authored as CC events inline in the
performance take — same grid as the notes, so swing, copy/paste, and
pooling come free, and the data is performance-bound by construction.
A fixed utility JSFX at the head of the track's chain (the **cc
feed**) consumes the designated lanes — strips them from the MIDI
stream — and exposes each as a slider; each binding is an ordinary
same-track plink from that slider to the target parameter.

**Why stripped, why not plink-from-MIDI.** Inline CC flows into the
instrument and every MIDI receiver on the channel, and which lanes a
given synth responds to is unknowable from outside. Stripping
dissolves the collision instead of managing it: a lane that never
reaches a receiver is free by definition, so allocation is purely
internal (14-bit pairs included). It also avoids the underdocumented
`plink.midi_*` path — slider→param plink is the exact mechanism the
cv sinks already bank on.

**Degenerate cv.** The cc feed is cv's converter + adapter fused into
one same-track FX, minus the audio-rate leg. Promoting a binding to
the cv graph replaces "strip to slider" with "strip to CV channel";
the authored data does not move. Standing and cross-track automation
are out of scope here — they are cv's.

**Binding shape** (cm take tier, sibling of `extraColumns`):

```lua
paramAutomation = {
  [chan] = {
    [lane] = {
      fxGuid = '{...}',  -- target FX; resolved to plink.effect index at apply
      param  = number,   -- target parameter index
      scale  = number,
      offset = number,
      label  = 'Cutoff', -- column header
    },
  },
}
```

**Applier.** A small idempotent driver — no graph, no realizer: on
take bind and on binding change, ensure the cc feed sits at chain
head, assign feed sliders, resolve `fxGuid` → FX index, and write the
plink config parms. When the shared realizer later grows
`setParamLink`, this folds into the same op so one code path writes
links.

**Tracker view.** The gesture is parameter-first: an "automate
parameter" command opens a picker over the track's FX chain
parameters; the manager allocates an internal lane, adds a CC column
(existing extraColumns machinery, unchanged), and writes the binding.
The column header shows the parameter label, never the lane number.

**Arrange view.** Nothing. Inline data moves, duplicates, and dies
with the clip — performance-bound semantics fall out of the data
location.

## Relationship to wiring: the shared realizer

cv and wiring are the same machine above a seam, and different machines
below it. The seam is the **`targetTracks`** shape.

**Below the seam — the shared realizer (graph-agnostic).** `allocate`
(live-range channel/pin/bus allocation, plus the merge CU for fan-in —
CV summing *is* audio summing) and the `snapshot → diff → applyOps`
engine over a graph-agnostic op vocabulary (`setFXChain` / `setSends` /
`setPinMaps` / `pushParams`, plus a **new `setParamLink` op** for
`plink`), with guid-bridging, Undo discipline, scratch, and the
live-recompile loop. This layer knows nothing of masters or modulation;
it realizes a set of per-track FX-chain + send + pin-map + param +
link specs into REAPER, idempotently.

**Above the seam — the graph-specific compiler.** `validate` plus
`userGraph → targetTracks`. Wiring keeps its master-minimization and
`ext_midi_bus` weirdness up here. cv gets its own compiler: the
`cvSource | processor | paramSink` taxonomy, CC-take sources, and a
plink terminal (adapter per destination track).

**Cleanup hypothesis (test during the refactor, don't pre-commit):**
wiring's `masterFeed`/`mainSend` and cv's plink are both just "what
happens at a leaf." If master-feed reduces to an ordinary out-wire into
the master's input pair, much of wiring's terminal special-casing
dissolves — which is why extracting the realizer pays for itself in
wiring regardless of cv.

## Feedback

Deferred. The graph is acyclic for now, reusing DAG's acyclicity and
cycle-prevention (`ancestors`/`descendants`). "An out wired to an in
behind the scenes" — a real modulation feedback loop — is a later
addition, most plausibly via REAPER-7 FX containers
(`container_nch_feedback`), which give internal feedback channels
without breaking PDC. Not in the first build.

## Implementation plan

### Anchor decisions

- **Same backend as wiring.** cv does not invent a realization path; it
  shares wiring's, via the extracted realizer. The cv compiler's only
  job is `userGraph → targetTracks`.
- **Reconcile authority, live recompile.** Inherited from wiring: the
  user graph is the source of truth for what we own; every gesture
  recompiles, diffs against a REAPER snapshot, and applies a minimal op
  list inside one `Undo_BeginBlock`. Foreign tracks/FX untouched.
- **CV is audio; one central graph; plink sinks; no envelopes.** The
  model sections above. These don't recur as questions inside the
  stages.

### Phases (strict order)

1. **Spike — verify the REAPER unknowns before committing any
   architecture.** Hand-build a one-track chain: a 14-bit-CC MIDI item
   → converter take FX (CC → audio CV) → send → a processor JSFX →
   send → adapter slider → `plink` → a real parameter. Confirm:
   - `plink` is same-track-only (decides per-destination adapters);
   - the live chain works end to end at acceptable block-rate latency.
   Plus the simple layer's unknowns, on the same bench:
   - slider plink keying: `plink.effect` is an index — does the link
     survive FX reordering, or does the applier re-point via guid?
   - CC shape curves reach a JSFX as a usefully dense event stream
     during playback, not just at authored points;
   - a head-of-chain JSFX stripping lanes leaves the rest of the
     stream intact (bank select, NRPN neighbours, running status).
   If any fails, the architecture shifts. Cheapest possible learning;
   no code architecture is committed until it passes.

   **Results (2026-06-10; `tests/spike_cv.lua` + `cv/*.jsfx`) — all
   green, architecture stands:**
   - same-track-only confirmed at API-shape level: `param.X.plink.*`
     has no track addressing (`effect` = same-chain index, −100 =
     MIDI). Per-destination adapters stand.
   - both legs live and responsive by ear: inline (feed slider →
     plink) and cv (CC take FX → send → adapter → plink). A plink
     source *later* in the chain than its target works. (Processor
     leg omitted — JSFX-processes-audio is not an unknown.)
   - a JSFX slider assigned in `@block` is a valid plink source; no
     `slider_automate` needed.
   - strip: designated lane fully consumed; bank select, other CC,
     and notes pass untouched.
   - density: REAPER renders interpolated CC between shaped points at
     ~25 ms grain; constant-value spans emit nothing (plink holds the
     last value).
   - reorder: REAPER's plink remap is unreliable — it followed one
     move, then read stale after the reverse, leaving the link
     pointing at the wrong FX. Treat `plink.effect` as index-keyed:
     store bindings by FX GUID and re-point on every reconcile.

2. **Simple layer.** The cc feed JSFX, the `paramAutomation` binding
   store, the applier, and the tracker "automate parameter" gesture.
   No realizer dependency — lands before the wiring refactor and
   ships user value while the refactor is in flight.

3. **Wiring refactor toward the shared realizer.** Extract the realizer
   beneath the `targetTracks` seam; lift master/source/`ext_midi_bus`
   specifics into a wiring-only compiler; add `setParamLink` to the
   shared op vocabulary. Wiring behaviour is unchanged and its specs
   stay green — this is pure concern-separation, and it is the bulk of
   the risk, so it lands and is verified before any cv code exists.

4. **Build the cv page on the realizer.** `cvManager` / `cvView` /
   `cvPage` plus the cv compiler. Node taxonomy, plink sinks
   (per-destination adapters), CC-take sources with the two homes, and
   the central graph host.

### Module layout

- **cv compiler** (in or beside `DAG`, per the refactor's seam) —
  pure: `validate` + `userGraph → targetTracks` for the cv taxonomy and
  the plink terminal. No REAPER, no cm, no ImGui.
- **`cvManager.lua`** — persistence (cm project tier), the cv compiler's
  driver, and the cv-specific source binding (CC takes + converters on
  child/CV tracks). Owns the cv user-graph instance, fires hooks, and
  drives the shared realizer's diff/apply. Mirrors `wiringManager`.
- **`cvView.lua`** — node/edge layout, hit-testing, wire-menu state,
  in-memory cursor/selection. Mirrors `wiringView`.
- **`cvPage.lua`** — coordinator citizen exposing the standard page
  surface, registered in `continuum.lua`. Project-wide like wiring;
  `bind` is a no-op.

### User-graph schema (sketch — settles during the build)

```lua
{
  nodes = {
    [nodeId] = {
      kind = 'cvSource' | 'processor' | 'paramSink',
      pos  = { x = number, y = number },

      -- cvSource: a labelled modulation origin
      source = {
        backing = 'authoredCC' | 'liveAudio' | 'liveMidi',
        home    = 'performance' | 'standing',  -- authoredCC only
        -- performance: bound to a source take's child track;
        -- standing: an item on a dedicated CV track.
        trackGuid = '{...}',                   -- where the CC take lives
        label     = '...',                     -- wire-stub label
      },

      -- processor: a CV JSFX (LFO, slew, LPG, S&H, math)
      fxIdent   = '...',
      fxDisplay = 'LFO',

      -- paramSink: bind a CV wire to a target parameter
      sink = {
        kind        = 'param' | 'cc',
        targetGuid  = '{...}',   -- destination track GUID (adapter host)
        targetFx    = '...',     -- FX whose param is linked (param sink)
        targetParam = number,    -- parameter index (param sink)
        ccLane      = number,    -- 14-bit CC lane (cc sink)
        scale       = number,    -- plink scale
        offset      = number,    -- plink offset
      },
    },
  },
  edges = {                      -- CV wires (audio-rate)
    { from = nodeId, fromPort = nil | portIdx,
      to   = nodeId, toPort   = nil | portIdx,
      ops  = { gain = number? } },   -- gain reuses wiring's wire operator
  },
  _nextId = number,
}
```

Synthesised nodes (minted at the targetTracks/allocate boundary, like
wiring's CUs): the **merge CU** for CV fan-in (reused wholesale — CV
summing is audio summing) and the **adapter** (CV→slider) hosted on each
destination track, carrying the `plink` source slider.

### Open questions / risks

- **Exact seam shape** — the `targetTracks` carve is the intended seam,
  but the precise division (does `allocate` move below it untouched? does
  master-feed normalize to an out-wire?) settles while doing the wiring
  refactor, informed by what the spike validated.
- **CC sink mechanics** — writing 14-bit CC back into a lane from a graph
  terminal is sketched but not designed; lowest-priority sink.
- **Simple-layer resolution** — source stream is ~25 ms grain at 7-bit
  (spike); judge zipper at the parameter by ear on slow sweeps.
  Internal lanes are free, so escalating to 14-bit MSB/LSB pairs is
  cheap if it's audible.
- **Internal lane allocation** — designated lanes must dodge lanes the
  user authors deliberately for external receivers (plain CC columns in
  the same take); the binding map is the registry.
- **Promote-to-CV mechanics** — the gesture that lifts a binding into a
  source→sink node pair on the cv page; data stays put, only the
  realization changes.
