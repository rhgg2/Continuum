# fx patterns — note/curve params via a checkout tracker

> opened: 2026-07-08 · closed: 2026-07-27 · status: built; P1–P4 landed,
> Mini undo dropped. What is true now is `docs/patternEditor.md`.
>
> Closed design doc. Companion to `design/note-macros-v2.md` (the chain
> surface): generator params whose **value is a note pattern or a curve**
> — an ostinato source, an arbitrary-shape LFO — reusable by copy
> through a project library, edited in a modal hosting a **second
> tracker stack**. The
> guiding rule throughout: **slim the surface, never the engine**. The
> mini stack is a full mm/tm/tv; scoping lives in bindings, column
> visibility, and a commit whitelist.



## The idea

A generator kind can declare a param of type `pattern` (notes) or
`curve`. The param's stored value is the **body itself**, inline on
the fx entry (§ P3.5); a project-scoped library shelf lets bodies be
copied out for reuse and back (§ P4). Editing opens a modal that binds a second,
fully real tracker stack to a **checkout take** on the scratch track:
the take is an editing surface only, an interface to the persistence
medium. The persisted form is a slimmed authored-intent record; commit
reads the take back through tm and strips realisation.

Both kinds are tracker-backed. A notes pattern edits as a single note
column; a curve edits as a cc/pb column, which buys the **bimodal**
surface for free — grid cells plus the lane strip's curve editor.

## Data model

The body lives inline on the fx entry; the project-scoped `fxPatterns`
ds key shelves named copies of the same shape (§ P4):

```lua
body = {
  kind      = 'notes' | 'curve',
  lengthPpq = number,            -- loop length, logical frame
  rpb       = number,            -- soft: rows per beat the body is authored at; default 4
  -- notes:
  root      = midiPitch,         -- reference; realisation transposes host − root
  specs     = { { lane=1, ppq, endppq, pitch, vel, detune, delay, sample? }, ... },
  -- curve:
  domain    = 'normalized' | 'cc',                 -- baked: the value space the generator sees
  display   = 'bipolar'|'unipolar' | 'cc7'|'cc14', -- soft: within-domain entry variant
  points    = { { ppq, val, shape, tension? }, ... },   -- val per domain: −1..+1 or 0..127
}

fxPatterns = { [name] = body }   -- ds, project scope: the copy shelf
```

Notes specs are **park-shaped** — the `REALISATION` strip
(`trackerManager.lua` § fxParked) already defines authored-minus-realised,
and new metadata rides along automatically. Whitelisted at commit: no
`fx` field (patterns don't nest generators), no `chan`, `lane` pinned
to 1 for mono kinds (the shape already carries `lane`; the per-kind
`lanes` declaration that unpins it is § P4).

Decisions taken:

- **Pitch is temper steps.** Patterns are authored absolute in the
  current temper around a declared `root`; realisation transposes
  host − root in temper steps (the `stepInterval` precedent). The user
  edits in the temper's terms because that is the only vocabulary the
  grid has.
- **Curves carry a baked `domain` and a soft `display`.** The generator
  is coded against the domain (`normalized` −1..+1 / `cc` 0..127) and
  never sees the editing substrate. See § Curve signature.

## Curve signature

One baked axis, one soft axis.

**Domain** (baked, `domain`) is the value space the generator is coded
against and the only thing it sees: `normalized` hands it points in
−1..+1, `cc` hands it 0..127. The editing substrate — a pb column for
normalized, a fixed scratch cc (`CURVE_CC`) for cc — is invisible to
both author and generator; the generator owns the real destination.

**Display** (soft, `display`) is a within-domain entry variant, user-
toggleable, that the generator never sees: normalized → `bipolar`
(−1..+1) | `unipolar` (0..1); cc → `cc7` | `cc14`. Display equals
entry — the cell you read is the cell you edit. (An inferred reading —
"440 Hz" — is a future status-line concern for all cells, not a
display/entry split here.)

Storage is three column flags on the take's `columnDisplay` ds key —
`normalized`, `bipolar`, `14bit` — stamped onto the gridCol at rebuild.
Absent = unset = the pre-existing byte-for-byte column behaviour; the
whole mechanism is purely additive. It is also the machinery a main-
tracker 14-bit cc affordance would reuse — midiManager already reads/
writes 14-bit; only the grid entry side was missing.

Two substrate details worth pinning:

- **Normalized rides pb thousandths.** `centsToRaw` scales cents onto
  the pb wire and clamps at ±8192; pinning the checkout take to
  `pbRange = 10` makes the wire full-scale exactly ±1000, so a
  thousandths value (−1.000..+1.000) round-trips losslessly with no
  engine change and `renderPB` shows thousandths natively.
- **14-bit cc displays as 4 hex digits**, `0000..7FFE`, even last
  digit: the display integer is `val × 256`, and the 14-bit LSB never
  reaches wire bit 0, so the low digit stays even.

## The checkout model

Open: mint a checkout take on the scratch track via
`arrange().mintParkedTake` directly — **not** `tv:newParkedTake`, whose
`selectSlot` would re-point the main tracker. Materialise the body
through production `mm:modify` (the harness `seedThrough` shape; stamped
notes must carry lane/detune/delay or `pickStampedLane` crashes), then
`tm:bindTake`.

Live preview is write-through: on each mini-tm `rebuild`, strip to the
whitelist and hand the body to the commit callback taken at open — in
production `tv:setFxField`, so the host re-realises the owning channel
and nothing else. A `deepEq` against the last-written body guards the
no-op rebuilds (precedent: `persistParked`).

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
  write desyncs the host silently. The one project write (`fxPatterns`,
  the § P4 shelf) goes through the *main* ds. Corollary: `tm:bindTake` gains a
  skip-guard opt — unconditional `restoreGuarded`/`guardTrack` would
  un-guard the host's playing track and stamp the scratch track guarded.
- gm is optional; tv's `pa` dep (and its ccm/facade needs) instantiate
  unconditionally as the harness does.

## Editing surface

Scoping is three boundaries, no engine surgery:

1. **Bindings, not registration.** tv registers its full command set
   against whatever cmgr it is handed; unbound commands are inert. The
   tracker binding table (now `pageBindings.tracker`) is shared data; the
   mini cmgr binds a filtered subset: nav, note entry,
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
per-frame dispatch result. The tracker binding table moves out to
`pageBindings.tracker`. trackerRender constructs one gridPane and delegates; existing
specs pin behaviour.

## P3.5 — the inline pivot

P3 landed with a model change the sections above reflect: the param's
stored value is the **body itself**, not a name into a shared store.
`launchPattern` (trackerRender) deep-clones the entry's body into the
editor; the commit callback writes it back through `tv:setFxField`, so
write-through re-realises exactly the owning channel — targeted
dirtying by construction, and the P2 "dirty all 16" tm arm never fires.

Why inline won: a live name-reference aliases every consumer to every
keystroke and drags in a lifecycle the fx strip has no room for —
rename, delete-while-referenced, dangling names. Inline keeps each fx
instance self-contained (fork-on-write, the library-model precedent);
sharing returns in § P4 as **explicit copies** through the shelf.

## P4 — polish

Decisions taken 2026-07-24; the queue is compiled in
`plan/archive/fx-patterns.md`.

**Library as a copy shelf.** `fxPatterns` (the P2 store) goes live as
a named shelf of bodies, written through the *main* ds. **Save** and
**Load** sit in the editor toolbar, both `chrome.drawPicker`s over the
matching-kind shelf names: Save offers the existing presets for an
explicit overwrite and creates a fresh name through the picker's
`onCreate` hook; Load picks a name — kind-filtered, so a curve param
only offers curves — and copies the body
down onto the checkout, whereupon write-through makes the param track
it. Both directions are copies: no live sharing, a shelf edit
re-realises nothing, and tm's `fxPatterns` `dataChanged` arm plus its
`derivationInputs` entry are deleted rather than extended. Management
stays inside the Load picker (delete only — see below).

**Mini undo — dropped** (deprioritised 2026-07-24, dropped at close
2026-07-27). Undo/redo are root-scope registrations on the *main* cmgr,
unreachable from the modal, and the mini ps never runs `pollUndo`; the
modal shipped that way. Its value never came clear against Esc, which
restores the modal-open snapshot wholesale and so already covers "undo
the edit I just started". The wire, should it ever be wanted: register
fenced undo/redo on the mini cmgr — `continuum.lua`'s `undoFence`
pattern, fenced at open so undo cannot cross into pre-open host edits —
and poll the mini ps while the modal is up so a rewound P_EXT can't
desync the mini ds. A REAPER undo rewrites the checkout take; the mini
tm's rebuild then write-throughs the rewound state, so the param follows
automatically.

**Polyphony is infrastructure, per-kind.** The pattern field
descriptor gains a boolean `poly` (default false/mono; settled
2026-07-24 — a plain flag, not a `'mono'|'poly'` enum). It is a
launch/open parameter, not a body field: it rides the descriptor
(per-kind) and would be lost across a shelf Load if stamped on the
body. Mono is today's behaviour: one visible lane, readback pins
`lane = 1`. Poly binds the lane add/remove commands (`addNoteLane`,
`hideExtraCol`) in the mini editor and readback keeps each spec's
authored lane. `chordStamp` is the first poly kind — it stamps a poly
note pattern (the chord) onto every region member, rebased by whole
temper steps so the pattern's lane-1 note lands on each trigger;
ostinato stays mono. A convolve-with-pattern fx could declare it next.

Save/Load across the poly boundary (settled 2026-07-24): Save is
lane-agnostic (`readbackBody` carries whatever lanes exist; the shelf
stores them verbatim). Load gates like the curve **domain** filter — a
mono param offers only single-lane bodies (`max spec.lane == 1`), so
lanes 2..N are never silently crushed onto lane 1; a poly param offers
every matching-kind body (mono is the lane-1 subset). The gate reads
the body's content, not its editor of origin.

**rpb rides the body.** rowPerBeat currently persists on the checkout
take's tier and dies with it. Store it in the body (soft, like
`display`): open seeds the toolbar ticker from it, readback carries it
through the whitelist. The field is named `rpb` (2026-07-25), matching
the `tm:addEvent` spec field and the RPB commands rather than the cm
key `rowPerBeat`.

Two settlements from the 2026-07-24 shelf promotion: curve loads
filter on **domain** as well as kind — the generator is coded against
the domain, so a `normalized` param is never offered a `cc` body. And
Esc keeps restoring the **modal-open** snapshot even after a Load: a
load replaces the working body, not the cancel target, so cancel
still means "as if never opened".

Shelf management (settled 2026-07-25) is **delete only** — rename is
dropped, since it needs a second entry mode inside a widget nine
callers share, for a name Save can recreate. Delete is a per-row `×`
on the Load picker's rows, fired through a new optional `onDelete`
hook on `chrome.drawPicker`, and it **arms on the first click**, showing
a confirm state, rather than acting at once: unlike an overwrite, which is an
explicit pick from a visible list, the button sits beside the row you
click to load and there is no undo path back to a deleted body.

A further settlement (2026-07-24, Save as picker): Save is a
`chrome.drawPicker` like Load, its items the existing matching-kind
shelf names, so an overwrite is an **explicit pick** from a visible list
and a fresh name is created through a new `onCreate` hook on the picker.
The divergence confirm is **dropped** — it guarded a blind typed
collision that the visible list removes — reversing the "confirm before
overwriting a divergent copy" decision above.

(Isolated preview, once listed here, is dropped: write-through already
auditions the pattern in host context, and there is nowhere sensible
to hear it alone.)

## Risks & accepted quirks

- **Undo interleaving.** Mini edits mint labelled REAPER undo blocks in
  the host's history; after cancel they reference a deleted take. With
  § P4's mini undo dropped there is no fence, and none is needed — undo
  stays unreachable from the modal. The host-history interleaving itself
  stays. Accepted.
- **Orphan checkout.** A crash mid-edit leaves the checkout take on the
  scratch track. Accepted v1 (cheap to sweep at next open).
- **Rebuild chattiness.** Write-through triggers a host rebuild per
  keystroke — same cost as direct host editing, and `setFxField` scopes
  it to the owning channel; the `deepEq` guard trims no-ops.
