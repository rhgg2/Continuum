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
on the affected channels, and the next `tm:rebuild`'s stale-swing reseat
rederives raw from each event's ppqL under the new composite. Because
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

The band sits below a `preview` palette header (`chrome.paletteHeader`,
run in the plain chrome style state so its divider aligns with the
library palette's across the pane gap): strips centred horizontally,
top-aligned, each framed by a 1px `swing.previewBorder`. Below it a
matching `factors` header sits over the rows; its divider doubles as a
draggable splitter (relative drag, anchored at grab) that sets
`state.previewH`, trading height with the factor list. Both headers and
the band stay live even with no swing selected — only the factor rows
grey out.
`state.previewH` re-fits to the band's content on open and on a rows/qn
change (capped to keep the factor list visible); a manual drag
overrides until rows/qn changes again.

## Library tiers

Swings live across two cm tiers — `project` and `global` (the shared
library) — with the factory catalogue behind them as a seed source, not a
resolution tier. The mechanics are the general library model: project-over-
library resolution, factory-as-seed, the edit-at-project invariant, and the
shared publish / revert / tidy / import verbs all live in `library.lua`; see
`docs/library.md`. What's swing-specific:

- The synthetic floor is `identity` — the unstored, undeletable `{}` ≡ no
  swing (`12EDO` plays the same role for tempers).
- Copy-on-use runs through `lib.localize`: picking a swing for a take or
  channel (`setSwingSlot` / `setColSwingSlot`) copies its composite into the
  project tier if absent, before the name is written into the take map, so a
  project stays self-contained. `temperEditor` mirrors this for tempers.
- Every editing gesture forks a library selection to project before writing
  (`swingWrite` → `lib.forkToProject`), so browsing a library swing and
  nudging a slider never mutates the library.

## Bind-time seeding

A take's swing map seeds from `defaultSwing` (`tv:seedSharedSlots`) the
first time it binds. The read is `cm:get` — the full-tier merge — so an
unset default floors to the schema's `{ global = 'identity' }` rather
than `nil`. That floor fixes a recurring bug: picking a swing on one
take stamps `defaultSwing` at the project and track tiers, and a
*different* take that was never given a swing would, on its next bind,
inherit that value — silently changing (and mis-timing) a take the user
left at Off. Materialising the floor on first bind makes the map
non-`nil`, so the `no-op once set` guard blocks every later re-seed: an
explicit Off sticks.
