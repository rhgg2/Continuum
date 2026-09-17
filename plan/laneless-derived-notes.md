# Laneless derived notes — plan

> source: `design/laneless-derived-notes.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The base voice** (§ The base voice) — `baseVoice` on the
   derived record, set by the generator; the lane-1 union becomes a
   base-voice door the absorber walk and `index.detuneAt` share. — landed
   2026-09-13, four commits.
2. **Phase 2 — The display lane** (§ The display lane, § The freeze claim) —
   tv allocates a column per frame over the caret's host; the ghost overlay,
   the cents readout and the freeze rect's note streams read the one
   allocation. — landed 2026-09-16, two commits.
3. **Phase 3 — The derived tail bound** (§ The derived tail bound) — a derived
   note's end clipped by same-pitch successor and host window end, with derived
   notes joining the tail walk's pitch dimension. — landed 2026-09-17, one
   commit.
4. **Phase 4 — Laneless emission** (§ The derived note record) — `lane` off the
   emitted spec, `fxOut.notes`, `fxNotesByHost` and the mm metadata;
   `allocateRegionLanes` retires with it. Owes § Open's twin-hit question an
   answer: the existence reconcile keys `lane`, and
   `tm_fx_region_spec :: a region emitting twin hits seats both` fails when the
   term has nothing left to name.  ← in flight
5. **Phase 5 — Keep by omission** (§ Keep by omission) — the derived existing
   set gathered per touched host window, as `buildFxInCcsInWindows` does,
   retiring the fx pass's explicit keep branch for notes. The existing-side half
   landed early on 2026-09-16, at bucket rather than window grain: `fxIn.notes`
   arrives bucketed by producing host and a kept host's bucket is withheld, so
   the reconcile already passes over a kept host. What remains is the per-window
   gather and retiring `runOrKeep`.

Sequencing note: the display lane lands before lanelessness so no frame draws
ghosts or mints a freeze rect without a column to put them in; laneless
emission lands before keep by omission, whose per-window gather would leave a
lane allocator unable to see the notes it must avoid.

## Landed  (newest first; prune below ~4)

- 2026-09-17 tm: key the fx reconcile on the logical seat, match by multiset (§ The derived note record)
- 2026-09-17 tm: bound a derived note by its host's window, not its lane (§ The derived tail bound)
- 2026-09-16 tm/tv: compose the freeze claim from the display allocation (§ The freeze claim)
- 2026-09-13 tv: allocate a display lane for a host's derived notes (§ The display lane)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **Laneless emission.** `lane` leaves the emitted derived spec, `fxOut.notes`,
  the copies that carry a derived note to mm, and the existence key;
  `allocateRegionLanes` and `onTakeOnLane` retire with it, `eachLaneSpan`
  keeping `membersOf` as its one caller, and emission's region/note-host branch
  (`host.lane == nil`) collapses to one path. The host's own `lane` stays: it
  belongs to the inbound stream a monophonic stage reads
  (`docs/generators.md` § Input streams), and slide's same-lane successor seek
  reads it. PC sample shadowing ranks authored records by lane and derived
  records after them in emission order, which preserves today's verdicts —
  the allocator seeds occupancy from the on-take population, so an authored
  record already wins every mixed onset. `docs/generators.md` § Output,
  `docs/trackerManager.md` § Fx expansion and § Lane occupancy stand on the
  allocator; tv's two mirroring comments name it.

