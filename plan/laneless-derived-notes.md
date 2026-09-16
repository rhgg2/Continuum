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
   notes joining the tail walk's pitch dimension.  ← in flight
4. **Phase 4 — Laneless emission** (§ The derived note record) — `lane` off the
   emitted spec, `noteLive`, `fxNotesByHost` and the mm metadata;
   `allocateRegionLanes` retires with it. Owes § Open's twin-hit question an
   answer: the existence reconcile keys `lane`, and
   `tm_fx_region_spec :: a region emitting twin hits seats both` fails when the
   term has nothing left to name.
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

- 2026-09-16 tm/tv: compose the freeze claim from the display allocation (§ The freeze claim)
- 2026-09-13 tv: allocate a display lane for a host's derived notes (§ The display lane)
- 2026-09-13 tm: the pb hold scope asks the generator, not the host's lane (§ The base voice)
- 2026-09-13 tm: seat absorbers against the base voice, not lane 1 (§ The base voice)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The derived tail bound** — a derived note's logical bound becomes the end
   its generator gave it clipped by its host's window end, which `boundNote`'s
   derived arm reads off the pass's window set by `spec.derived` — so
   `rebuildTails` takes that set, and `frame.clippedSpanEnd` over the lane's
   population goes. The raw bound keeps its same-pitch term unchanged; that
   probe already reads authored and derived alike, which is the pitch dimension
   the design asks for. `derivedLanePred` and its anchor probe retire from both
   walks, and `makeTailRules`' derived lane views with them, so the lane-1 nudge
   emission closes on the next authored onset — a wider interval than a derived
   onset gave, and dirt the absorber pass already tolerates. The generator's end
   is always a number (emission converts it to raw as it builds the spec), so
   the bound states no open-end term, which answers § Open's second question.
   Evidence: a region's derived note is no longer cut by an authored note
   sharing its allocated lane at another pitch, and a same-pitch one still cuts
   it. Specs: `tests/specs/tm_fx_region_spec.lua`, `tests/specs/tm_tail_gating_spec.lua`.
   Docs: `docs/trackerManager.md` § Tail walk and § What the walk visits, and
   what it emits, whose derived lane-bound paragraphs it replaces.
