# swingEditor

A pane on the library workbench (see `docs/editorPage.md`) for editing
a swing composite — a list of factors, each with an atom (id / classic
/ pocket / lilt / shuffle / tilt), a shift in QN, and a period. Owned
by editorPage; opened via the `editSwing` command or the tracker's
swing `edit` button, drawn by editorRender.

## State authority

The composite lives in cm (`cm:get('swings')[name]`). The editor
caches nothing about it — every frame, `swingRead()` fetches fresh.
This is the simplest correctness story when the composite can change
from outside (other commands, undo, replay). The editor's own state
is only window chrome and gesture-transient: name, snapshot for
Reset, rpb, Wild flag, last-known size.

## Single-path writes

Every primitive (patch, add, remove, move, slider drag, atom swap,
period change, Reset) routes through `swingWrite`. `swingWrite`
short-circuits on equality and then fires `tv:setSwingComposite`;
cm's resulting `configChanged` broadcast drives `tm:markSwingStale`
on the affected channels, and the next `tm:rebuild`'s step 4.7
reseats raw from each event's ppqL under the new composite. Because
`swingWrite` reads the stored composite as the "old" side of the
delta, per-frame slider-drag calls chain into a correct sequence of
old→new transformations as the slider moves.

## Snapshot

Captured at `open()` from the cm composite. Never mutated. Reset
writes a `deepClone` of it through `swingWrite`. The dirty check
compares the live composite to the snapshot via `compositesEqual`,
which equates `{1,2}` and `{2,4}` — equality is on the QN value, not
the literal table.

## Caps and Wild

Each atom has a mathematical |shift| max past which the swing shape
loses monotonicity (`atomMeta.range`). The editor calls this max
`hard` (in QN: `T_tile · range`). For everyday use it imposes a
soft cap, `min(SWING_SOFT_QN, hard)`, so musically excessive shifts
take a deliberate Wild click to unlock. `cap == 0` (the identity
atom) freezes the slider altogether. Shift is atom-independent QN,
so atom swap preserves it and only re-clamps.

## Tile-QN combo

The user-period of a factor is what gets stored. The atom-combo,
however, speaks tile-QN (= user-period × pulsesPerCycle), because
atoms with `pulsesPerCycle = 2` (pocket, lilt) have a longer real
repeat than their user-period. Surfacing tile-QN in the dropdown
matches what the user perceives. `periodOverPPC` divides on write
to keep storage in user-period.

## Preview band

The preview is a row of **vertical strips**, each styled like the
tracker grid (same char-cell metrics, bar/beat row fills, 1px non-AA
dividers on the offbeat rows). Time runs top-to-bottom. Each
subdivision's blob is migrated down to its realised onset, so the blob
visibly slides off its grid row by the swing amount — the grid is the
unswung frame, the blob is where the note actually plays.

Layout reads as composition: the composite strip on the left, then —
when there is more than one factor — `=` and the factor strips in
compositional order `fn ∘ … ∘ f1`. `f1` is applied first
(`applyFactors` walks the array forward), so it sits rightmost, nearest
the source.

Every strip shares one height: the smallest whole number of bars that
covers the *composite's* natural period (`compositePeriodQN`, rounded
up so the meter shading means something). Because that rounds past the
period, the tail rows repeat — blobs past a strip's **own** natural
period draw in the `ghost` colour (the interpolated-note colour), so
each strip shows its own repeat point within the shared frame.

Three dot sizes — bar/midBar > beat > offbeat — let the meter read at a
glance. `midBar` (the bar midpoint when it lands on a beat — true in
4/4, 6/8; false in 3/4) shades as a beat but sizes as a bar; the
asymmetry is deliberate.

## Library tiers & seeding

Swings resolve across three cm tiers, plus a synthetic floor:

- **defaults** — the built-in preset catalogue (`classic-*`, `delay-*`)
  and `identity`, the unstored, undeletable floor (a bare `{}` ≡ no swing).
- **global** — the user's personal library. Lazily seeded from the
  catalogue (minus `identity`) the first time it is *read* — by the
  editor's tree palette or a tracker picker (`cm:seedGlobalFromDefault`).
  No startup seeding, no flag; an empty global library is the only signal.
- **project** — every swing the project actually references. A project
  is self-contained: realisation resolves names here (plus the identity
  floor) and never leans on the global library or the catalogue.

Project self-containment is held by **copy-on-assign**: picking a swing
for a take or channel (`setSwingSlot` / `setColSwingSlot` → `localizeSwing`)
copies its composite into the project tier if absent, before writing the
name into the take map. `identity` is never localized. `temperEditor`
mirrors this for tempers (`pickTemper`, with `12EDO` as the floor).
