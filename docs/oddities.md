# oddities

Where what the code does and what you would expect it to do come apart, and
we have looked and decided — for now — to live with it. The register exists so
that the second person to meet one of these finds out in a minute that it is
known, and reads the reason instead of re-deriving it.

Every entry carries exactly one verdict:

- **gap** — we would close it, and nothing has justified the change yet. The
  entry says what closing it would cost, that being the part which otherwise
  gets rediscovered each time.
- **accepted** — examined and refused. The behaviour is right, or the
  alternative is worse, and the entry says which.
- **withdrawn** — reported, probed, and not there. These stay on the register,
  because an entry that simply vanishes gets reported again.

An entry leaves when the behaviour changes. A closed gap is deleted rather
than struck through, its record living in the commit that closed it.

The reason this is one standing file rather than a section per design doc:
every programme grew a list like this and then took it to `design/archive/`
when it closed, which is where a claim about live behaviour goes to be unread.

## Generators and fx

### A slide into a parked successor arrives late

> **gap** · tm · 2026-08-04

`ctx.nextSameLaneNote` reads lane occupancy as column ∪ parked, so a slide
aimed at a parked note finds the right target — itself the fix for a wider gap
where a parked host got no successor at all and `[trill, slide]` realised the
trill alone. The host's *window* clip does
not: `hostWindowEnd` asks `nextLaneOnset` of the column alone
(`trackerManager.lua:709`), so a host whose authored ceiling runs past the
parked cell glides across the whole tail and arrives after the note it aimed
at. Where the ceiling ends at the successor — the ordinary case — the glide is
exact. Closing it means unioning that clip too, and the clip governs every
kind's window rather than slide's, so it is its own change.

### A member straddling the window edge is parked whole

> **accepted** · tm · 2026-08-04, against a derived-remainder design

Membership is by onset, so a note starting inside a region belongs to it
entire. Realising the uncovered tail would mean a note-on at the window edge:
an attack the author never wrote, standing in for a note the region has
already spoken for. Silence is the honest realisation, and the authored note
loses nothing by it — the parked cell is the whole of it, visible and editable
throughout. The rule reads the same in the other direction: a note whose onset
precedes the window is not a member, and sustains through it.

### A chain added by mouse draws nowhere until the caret reaches it

> **gap** · tv · 2026-08-08

The palette strip resolves its host as the pinned session's or the one under
the caret, and a region minted from a selection sits in an fx column the caret
is not in. So a chain added or loaded by mouse is written but invisible until
the caret moves onto the region. The keyboard door pins the host it mints and
shows it at once, so only the mouse path is affected, and nothing is lost —
the chain is on disk, and one caret move shows it. Closing it means either
pinning on a mouse mint, which changes what Esc reverts, or moving the caret
as a side effect of a picker pick; both are wider than the gesture that
exposed them.

### A chain's claim on a column the channel lacks shows nothing

> **gap** · tv · 2026-08-06

The ghost overlay lands only in columns that already exist
(`docs/trackerView.md` § Ghost sampling), so an lfo on a cc the channel has
never carried leaves no mark on the grid, and a region chain deriving three
voices on a one-lane channel has two thirds of its ghosts with nowhere to
hang. Nothing on the grid then distinguishes a chain that is working from one that is not, and the
fx tab becomes the only place the target is written down — the glyph stack
names a chain's kinds but not what they address, so it narrows the question
without answering it. Adding the column by hand makes the claim visible. Two
closures were priced and neither taken: the claim could add a real column
once, when it is made, in the fx edit's own undo block, at the price of a
document write as a side effect of an fx edit; or the caret-gated set could be
made safe by holding caret and selection by column identity throughout, which
is a piece of work in its own right. One neighbour this would not close: a
note host's derived notes ride the host's own lane by design, so a three-voice
stamp on a *note* shows one ghost of three whatever columns exist — that is
lane sharing, and no column answers it.

### A note's own fx stays suppressed while a region parks it

> **accepted** · tm · 2026-08-04

A region-parked note is off the take, and its own chain does not run while the
region covers it. The spec survives untouched and the chain returns when the
region moves off, so this is a quirk of coverage rather than a loss of data.

### A replace region's parked PAs stay take-side

> **withdrawn** · tm · 2026-08-04, probed in a spike against `tm_fx_region_spec`

A PA parks exactly when its host note parks, and that holds for both host
kinds: a region-parked chord's PAs leave the take, and so do a self-parked
trill host's. Nor is the symptom reachable from the other side — a note whose
onset precedes the window is not parked, and a replace region's members *are*
its parked cells, so it derives nothing to sound against. What remains is
narrower and inert: a PA inside the window but past its host cell's end stays
take-side, on a pitch where no derived tile reaches it.

## Pattern editor

### A mini-editor edit leaves undo points in the host's history

> **accepted** · patternEditor · 2026-07-27

The mini editor binds its checkout take to the same tm and command machinery
the tracker uses, so each edit inside the modal mints its own labelled REAPER
undo block in the project's history. After a cancel, those blocks name a take
that no longer exists. No fence guards them and none is needed: undo is
unreachable from inside the modal, so the blocks are met only by winding the
host's history back past the whole editing session.

### A crash mid-edit leaves the checkout take on the scratch track

> **accepted** · patternEditor · 2026-07-27

Closing the modal sweeps the checkout item and its pool metadata
(`patternEditor.lua:289`), and a second open is guarded while one is live. But
nothing sweeps at open, so an item orphaned by a crash survives into the next
session. The leak is inert — an empty item on a hidden track — and the fix,
a sweep of the scratch track when the editor opens, stays unbuilt for want of
a reason to write it.

### A keystroke in the mini editor costs a host rebuild

> **accepted** · patternEditor · 2026-07-27

Write-through commits on every mini rebuild, so editing a pattern is as chatty
as editing the host directly — which is precisely the cost it is measured
against. `setFxField` scopes each rebuild to the owning channel, and a
`deepEq` against the last committed body drops the no-op writes.

## Tuning

### The octave field's budget ignores the `octaveStep` bump

> **gap** · tuning · 2026-08-10

The field is sized from the octave numbers at the two ends of the addressable
range, and `stepToParts` can render one higher than the top of it: a temper
whose C-tail bumps at a step sitting just under the ceiling reads an octave the
budget did not reserve for. No preset does — the bump needs a residual near the
top of the period, which at the topmost period-index is already out of range —
and both ways to close it cost more than the gap. An unconditional `+1` widens
every preset's cell by a column, and scanning the top period's steps puts a
snap inside a width computation.
