# trackerView: the grid is the interface

> opened: 2026-08-08 · status: review findings — nothing proposed
>
> `trackerView.lua` is 4246 lines, the second outlier after tm. This doc
> records what a five-cluster review found, and one measurement that
> reading could not settle. It proposes nothing; the seams are badged so
> a later design can pick one up.
>
> Prior art: `design/tracker-manager-split.md`, whose test for tenancy
> this review borrowed, applied here, and watched fail.

## The problem

**1** tv is 4246 lines against tm's 5305, and 83 of the last 400 Lua
commits touch it. Second on both axes, with a steep cliff below it to
`trackerRender.lua` at 1550.

**2** The tempting diagnosis is the one that worked next door.
`design/tracker-manager-split.md` § The problem argues that tm is long
because it holds several tenants rather than because it is tangled, and
offers a test: every large section already exports exactly one name.
Apply that test to tv and it fails four times in five. The editing block
at 741–1293 exports eleven names; the mirror bridge exports fifteen, to
four different consumers.

**3** The failure is not tangle either, and saying why is the point of
this document. Four of the five clusters reported the same shape
independently and in nearly the same words: **narrow out, wide in.**
Each exports few names. Each would need a dozen bindings injected before
it could stand alone.

## The grid is the interface

**1** Ask what actually joins the clusters. It is not calls. `grid` is
declared at 139, published as a live handle at 147, mutated in place by
rebuild (3804–3807), and handed to `editCursor` (4123) and `clipboard`
(4133). Every cluster reads `grid.cols` straight off the upvalue.

**2** So the coupling travels by mutation rather than by call — which is
the qualification tracker-manager-split raises about dirt, arriving here
as the main event. tm's `rebuildPipeline` hands each stage its inputs as
parameters off one head snapshot. `tv:rebuild` takes one boolean across
291 lines, and every phase communicates by writing `grid`, `ctx` and the
file-level scalars.

**3** The criterion is worth stating as a criterion: a tenant is behind
a door when its inputs arrive as arguments. tv has one door, and behind
it no rooms. This is why every extraction estimate came back wide — there
is nothing to cut that does not also cut `grid`. **Strong**

## What the cache does not serve

**1** Rebuild carries a clean column's built cells across rebuilds, keyed
by the identity of its events table (3798–3802, 3960). The comment at
3796 explains that mechanism and is accurate about what it claims.

**2** What it does not say is which columns can never satisfy it. A
column whose content is unioned back from parked material builds a fresh
`events` table on every rebuild (3884, 3898, 3917), and an fx column
builds a fresh `fxCells` (3925, 3936). Table identity therefore changes
every time, and the lookup at 3960 cannot hit.

**3** Reading suggests that; measurement settles it. Instrumented in a
spike across `tv_fx_region_spec`'s 75 tests: parked note columns 29
misses and no hits, parked cc 7 and none, parked pb 2 and none, fx
columns 115 and none. Plain note columns hit 2326 times against 69
misses. The exclusion is total, and no line in the file states it.
**Strong**

**4** Whether it is a defect turns on a judgement not made here. Parked
and fx columns are precisely the ones whose contents were just
recomputed, so a miss may well be correct. The finding is that the cost
is unstated, not that it is wrong.

## The seam found from both sides

**1** `fxRegions` has two writers. The region-window code writes it at
1480, 1560 and 1632; the note-FX cluster writes it at 2359, 2421 and
2441, 850 lines away. They are joined by two helpers defined with the
first and reached by the second — `rewriteRegion` (1470, used at 2429
and 2523) and `cursorRegionBefore` (1486, used at 2428).

**2** One doc key with two owners is the shape this project reads as
evidence of a misplaced owner rather than a shortcut. Two reviewers
reached it independently from opposite ends of the file, which is the
strongest corroboration the review produced. **Strong**

**3** Worth separating from the finding: tv writing `ds:assign('fxRegions')`
with no manager in between is deliberate, and declared at 2519–2521 as a
document-data write routing `ds:assign → dataChanged → rebuild`. The
split of that write across two clusters is the finding. The route itself
is not.

## The bridge that is half a bridge

**1** `groupBridge` (4098–4120) exists so `editCursor` reaches group
geometry through one surface. Seven of its nine fields are one-line
forwards to `tv:` methods.

**2** The section it wraps is not all bridge. `selectionAsRect` (3087),
`cursorAnchor` (3169) and `streamRefAt` (3178) are grid↔logical
translation, which is what a bridge is for. `movePreview` (3232) is
render geometry. `ghostOverlay` (3279) is not mirror-related at all; it
shares the section because it also calls `colFor`. `clearRegionAt` (3148)
and `clearMoveGap` (3155) execute gm's contract obligation on the view
side. **Worth exploring**

**3** The division between the two mediation surfaces is by consumer
rather than by concern: editCursor sees the wrapper, gridPane calls `tv:`
directly. That is a real principle, and it is written down nowhere.
**Worth exploring**

## Claims the review withdrew

**1** It was put to me that the comment at 4096 is defeated by its own
first field, `gm = gm` at 4099. It is not. 4096 says ec never touches gm
*geometry* or tm directly, and geometry is genuinely confined to the
wrapper (4108, 4114), as tm is to `commit` (4119). The overstated claim
is on the other side: `editCursor.lua:306` says "ec never touches gm
directly" while `gmgr()` at 307 hands it the manager and
`newFromSelection` calls `gm:mark` through it at 534. The boundary is
real; the two comments state it at different strengths.

**2** It was reported that tm corroborates the direct `fxRegions` write
through `tvOnlyKeys` at `trackerManager.lua:5113`. It does not. That
table names `defaultSwing` and `fxPatches`, and governs which *config*
keys skip the configChanged rebuild; it says nothing about document
data. The tv-side declaration at 2519 stands on its own.

**3** The nine `setFx*` methods were expected to be one read-modify-write
spelled nine times. They are not. Every verb routes through `noteFx` and
`setNoteFx`, host dispatch exists at exactly one line (2499), and the
residue is one to three lines of array copy performing four genuinely
different edits.

## Smaller findings

**1** `tv:editEvent` is dispatch-shaped from outside, but its 207 lines
are five near-identical `util.setDigit` formulas differing in radix, cap
and carry (939, 962, 981, 1019, 1039). The length is duplication, not
branching. **Worth exploring**

**2** `nudgeVel`, `nudgeDelay` and `nudgeValue` vary by about three lines
each; `nudgePitch` genuinely differs, doing a temperament transpose and
no scalar step at all. `quantizeScope` and `quantizeKeepRealisedScope`
share a traversal; `scaleScope` only rhymes, 45 of its 71 lines being
unique. Any unification here has to state its exception rather than bury
it. **Worth exploring**

**3** `rebuilding` (3736) is set at 3768 and cleared at 4055 with nothing
between them protecting it. A throw inside the pipeline latches the
guard, and every later rebuild returns at 3766 in silence. A latent
defect rather than an architectural finding. **Worth exploring**

**4** The projection epoch takes the temperament by *name* (3954) while
`ctx` takes the resolved table (3812, 3950), so editing a temperament
without renaming it leaves the signature equal. Nothing carried depends
on temper today: cells hold event references, `offGrid` and `tails` come
from ppq arithmetic, and `interpolateValues` (1443) reads only ctx row
math and `tm:interpolate`. The inconsistency is unreachable — a trap laid
for whoever first caches something pitch-shaped. **Speculative**

**5** The `---------- STATE` banner at 126 spans two tenants. The state
beneath it is rebuild's, and selection, sitting under the same heading,
owns nothing at all — it is a pure projection over `cm`. **Speculative**

## What is not proposed

**1** None of this is a plan. The badges mark what a later design could
take up; the review's own view is that the `grid` finding is prior to the
rest, since every extraction estimate in this file is an estimate about
`grid`.

**2** The chain-surface work is in flight over the note-FX cluster, and
findings there were withheld deliberately. `saveFxPatch`'s write-only
catalogue is mid-fix under phase 3 and is not a finding.
