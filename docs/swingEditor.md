# swingEditor

A floating window for editing a swing composite — a list of factors,
each with an atom (id / classic / pocket / lilt / shuffle / tilt), a
shift in QN, and a period. Owned by trackerPage; opened by the
`openSwingEditor` command, drawn each frame by `tp:renderFloating`.

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
short-circuits on equality and then fires both
`vm:setSwingComposite` and `vm:reswingPreset`. Because it reads the
stored composite as the "old" side of the delta, per-frame
slider-drag calls chain into a correct sequence of old→new
transformations as the slider moves.

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

## Grid model

The preview strip shows one period of swing. Cells are unswung
subdivisions (`rpb` per QN); dots land at the swung image of each
subdivision. Cells provide the rhythmic frame; dots show where the
swing actually puts the onsets — the visual contrast is the point.

`shadeMeter` paints bar/beat backgrounds. The composite preview uses
it (the composite period is rounded up to a whole number of bars so
the meter actually means something); per-factor previews leave it
off because their period rarely aligns to bars and the shading would
lie.

Three dot sizes — bar/midBar > beat > offbeat — let the meter read
at a glance. `midBar` is treated as a beat for shading but as a bar
for dot sizing; the asymmetry is deliberate.
