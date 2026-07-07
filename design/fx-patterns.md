# fx patterns — note/curve params via a checkout tracker

> Working design doc. Companion to `design/note-macros-v2.md` (the chain
> surface): generator params whose **value is a note pattern or a curve**
> — an ostinato source, an arbitrary-shape LFO — reusable across fx
> instances, edited in a modal hosting a **second tracker stack**. The
> guiding rule throughout: **slim the surface, never the engine**. The
> mini stack is a full mm/tm/tv; scoping lives in bindings, column
> visibility, and a commit whitelist.

## Status at a glance

**Open**
- [ ] P1 — gridPane extraction: grid core + lane strip out of trackerRender; binding table becomes shared data
- [ ] P2 — pattern store: `fxPatterns` ds key, generator param types, tm `dataChanged` branch
- [ ] P3 — patternEditor: checkout stack + modal, both kinds, live preview
- [ ] P4 — polish: pattern management, isolated preview, mini undo, targeted dirtying, polyphony

## The idea

A generator kind can declare a param of type `pattern` (notes) or
`curve`. The param's stored value is a **name** into a project-scoped
pattern library — the same reference model swings use, so many fx
instances share one body. Editing opens a modal that binds a second,
fully real tracker stack to a **checkout take** on the scratch track:
the take is an editing surface only, an interface to the persistence
medium. The persisted form is a slimmed authored-intent record; commit
reads the take back through tm and strips realisation.

Both kinds are tracker-backed. A notes pattern edits as a single note
column; a curve edits as a cc/pb column, which buys the **bimodal**
surface for free — grid cells plus the lane strip's curve editor.

## Data model

New project-scoped ds registry key:

```lua
fxPatterns = { [name] = {
  kind      = 'notes' | 'curve',
  lengthPpq = number,            -- loop length, logical frame
  -- notes:
  root      = midiPitch,         -- reference; realisation transposes host − root
  specs     = { { lane=1, ppqL, endppqL, pitch, vel, detune, delay, sample? }, ... },
  -- curve:
  points    = { { ppq, val, shape, tension? }, ... },   -- val bipolar −1..+1
} }
```

Notes specs are **park-shaped** — the `REALISATION` strip
(`trackerManager.lua` § fxParked) already defines authored-minus-realised,
and new metadata rides along automatically. Whitelisted at commit: no
`fx` field (patterns don't nest generators), no `chan`, `lane` fixed 1
(monophonic v1; polyphony is purely additive later since the shape
already carries `lane`).

Decisions taken:

- **Pitch is temper steps.** Patterns are authored absolute in the
  current temper around a declared `root`; realisation transposes
  host − root in temper steps (the `stepInterval` precedent). The user
  edits in the temper's terms because that is the only vocabulary the
  grid has.
- **Curves are normalized bipolar −1..+1** with a generator-side depth
  param. For editing, values scale onto the checkout column's native
  range (cc 7-bit / pb 14-bit) and normalize back at commit, so the
  persisted form is resolution-agnostic.

## The checkout model

Open: mint a checkout take on the scratch track via
`arrange().mintParkedTake` directly — **not** `tv:newParkedTake`, whose
`selectSlot` would re-point the main tracker. Materialise the body
through production `mm:modify` (the harness `seedThrough` shape; stamped
notes must carry lane/detune/delay or `pickStampedLane` crashes), then
`tm:bindTake`.

Live preview is write-through: on each mini-tm `rebuild`, strip to the
whitelist and `ds:assign('fxPatterns', …)` **through the main ds** —
host tm's `dataChanged` re-realises every consumer. Two prerequisites
found in review:

- tm's `dataChanged` handler dispatches on an explicit name list with no
  else branch; it needs an `fxPatterns` arm (v1 dirties all 16 channels;
  pattern→consumer targeted dirtying is P4).
- `ds:assign` fires even for identical values — the write site guards
  with `deepEq` (precedent: `persistParked`).

Cancel: write-through means Esc lands after the store was already
written, so the editor **snapshots the body at open** and Esc restores
it with one write. Enter just closes (the store is already current).
Close either way: delete the checkout item **and `eventMeta:dropPool`**
— skipping slot registration forfeits deleteSlot's keeper-removal, so
the pool's metadata blobs would leak forever.

## The mini stack

Owned and constructed by **trackerPage** (the controller owns stacks;
trackerRender stays render-only and receives an open-editor handle for
the fx strip's param row). Recipe follows `tests/harness.lua` `mk`, the
canonical parallel-stack shape:

- **Own ps+cm+ds trio + eventMeta.** cm/ds context-key through
  pextStore's single bound context (ds drops take/track caches on
  `contextChanged`), so sharing the page's ps would clobber the host
  bind. Two ps instances over one project ext-state are race-free —
  reads are uncached.
- **Hard rule: the mini stack never writes project/global tiers.**
  Per-instance project/global caches are never cross-invalidated; a mini
  write desyncs the host silently. The one project write (`fxPatterns`)
  goes through the *main* ds. Corollary: `tm:bindTake` gains a
  skip-guard opt — unconditional `restoreGuarded`/`guardTrack` would
  un-guard the host's playing track and stamp the scratch track guarded.
- gm is optional; tv's `pa` dep (and its ccm/facade needs) instantiate
  unconditionally as the harness does.

## Editing surface

Scoping is three boundaries, no engine surgery:

1. **Bindings, not registration.** tv registers its full command set
   against whatever cmgr it is handed; unbound commands are inert. The
   tracker binding table (today inline in trackerRender) becomes shared
   data in P1; the mini cmgr binds a filtered subset: nav, note entry,
   octave, delete, selection + interpolate/transpose/duplicate,
   rowPerBeat zoom, Esc/Enter (cancel/commit). Not bound: fx strip,
   groups, add/remove column, take lifecycle, swing/temper, palette,
   page nav, mute. `loadOverrides` runs on the mini cmgr so user rebinds
   apply. **Undo/redo dropped from v1** — root-scope registrations live
   on the main cmgr and the mini ps undo watcher is unpolled; wiring it
   is P4.
2. **View, not model.** One visible column (`col.x == nil` gating):
   the note column for `kind='notes'`, the cc/pb column + lane strip for
   `kind='curve'`. Note-cell sub-parts (detune, delay, vel, sample) stay
   — they are per-note intent and ride the spec.
3. **Whitelist at commit.** Whatever leaks into the checkout take,
   persistence keeps only whitelisted fields. Bindings keep the UI
   honest; the strip is the guarantee.

## Input routing

Coordinator's `dispatchKeys` + `handlePrefixCapture` extract to a shared
helper (verified: nothing else in the repo does modal-hosted dispatch).
The modal render pushes the mini cmgr's `tracker` scope and runs the
walk against it each frame, feeding the result to gridPane —
`handleKeys` consumes `commandHeld` from it, so the dispatch result is a
required gridPane input, not an optional gate. Host-side suppression is
already in place: `tr:focusState` suppresses main dispatch while a modal
is open, and grid note entry self-gates.

## P1 — the gridPane extraction

Stands alone as a trackerRender diet (~2469 loc today). Moves into a
`gridPane` factory: column layout, the printer, cell renderers, the
`drawTracker` body, mouse hit-testing/handling, edit-key note entry —
plus the **lane strip**, whose layout rows and gesture arbitration
(`laneConsumed`) are grid-coupled and whose curve editor the curve kind
needs. Host interface is exactly two members: one `inputAllowed()`
predicate (folding modal/picker/palette/strip-focus gates) and the
per-frame dispatch result. The tracker binding table moves out as shared
data. trackerRender constructs one gridPane and delegates; existing
specs pin behaviour.

## Risks & accepted quirks

- **Undo interleaving.** Mini edits mint labelled REAPER undo blocks in
  the host's history; after cancel they reference a deleted take.
  Accepted v1.
- **Orphan checkout.** A crash mid-edit leaves the checkout take on the
  scratch track. Accepted v1 (cheap to sweep at next open).
- **Rebuild chattiness.** Write-through triggers a host rebuild per
  keystroke — same cost as direct host editing; `deepEq` guard trims
  no-ops, targeted dirtying is P4.

## Open details

- Curve checkout column: cc (7-bit) vs pb (14-bit) — possibly per-param,
  from the generator's declared destination.
- If tracker selection turns out to be region-overlay-only, the overlay
  wiring joins P3 as a measured add.
- rowPerBeat zoom persists on the checkout take's tier and dies with it;
  per-pattern persistence (in the body) is a P4 nicety.
