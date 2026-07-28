# fx freeze — plan

> source: `design/fx-freeze.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — freeze to raw** (§ Freeze to raw) — `tm:freezeRegion`
   as the producer-shaped primitive: clear `derived`, drop the covered
   fxParked entries, drop the region and its `prevWindows`, one flush;
   plus the tm-side eligibility gates.  ← in flight
2. **Phase 2 — the curve thinner** (§ Freeze to group) — pure
   tolerance-bounded Douglas-Peucker over the standing densified seats,
   emitting linear breakpoints; cents for pb, steps for cc.
3. **Phase 3 — freeze to group** (§ Freeze to group) — re-seat the
   curves sparse, mint a stock gm group via `markGroup` on um-live staged
   events inside the same flush, gm rect-conflict gate on the tv verb.

## Landed  (newest first; prune below ~4)

- 2026-07-29 tm: declare parks to computeFxWindows; chain runs once (§ Eligibility gates)
- 2026-07-28 tm: one producer, one census entry -- dedupe and one-for-one (§ Eligibility gates)
- 2026-07-28 tm: freezeRegion's note-host arm -- parked and on-take (§ Freeze to raw)
- 2026-07-28 tv: bind freeze -- Ctrl-E and the fx tab's action row (§ Freeze to raw)

## Now

(empty — phase 1's fix landed; queued item 1, lifting the producer census, is next. Run /plan-next to promote it.)

## Superseded

The compiled gates brief of 2026-07-28 was refuted by adversarial
review before implementation; its two fatal findings are recorded in
the design doc (`§ Eligibility gates`) and its sound parts return in
queued item 3. The brief text itself is dropped from this file — it
contradicted this note by still being here.

## Queued (current phase; one-liners)

1. tm: lift the producer census — `assembleParkWindows`'s body becomes
   a named module-level function returning `{ uuid, chan, startppq,
   endppq, fx, noteHost }` producer records; rebuild pipes them through
   `generators.parkWindows` exactly as now. Collapses the four
   hand-kept copies of the note-is-a-region literal
   (`trackerManager.lua:1606-1607`, `:1614-1615`, `:4662-4663`,
   `:4671-4672`) and the two of the OPEN-ceiling end (`:1604-1605`,
   `:4669-4670`) to one each. With Now landed the arms are disjoint, so
   there is no precedence rule to carry. Pure refactor, pinned by the
   standing suite. Note `hostProducer` (`:668`) already owns that name.
2. tm: identity-stamp the baseline — `generators.parkWindows` stamps
   each emitted window `id = <producer uuid>` (census records carry
   it); `prevWindows` persists the field; freeze's resync drops by
   `id`, retiring the landed one-for-one walk and the field-for-field
   literal agreement it rests on (`trackerManager.lua:4662-4663`'s
   warning). The pb diff and cc recognition stay span-keyed — `id` is
   inert for seat recognition. Behaviour-equal after the landed
   dedupe; persisted-shape change free pre-beta. (§ Eligibility
   gates, "Identity reaches the baseline as a stamped `id`")
3. tm eligibility gates, against the census — same-target overlap by
   **owner identity** (not window value, so an identical-window
   neighbour is visible), the covered-fx-host gate, and the inverse
   note-host-span gate; pb-inclusive boundary. Specs pin each refusal
   and pin that a disjoint neighbour still freezes. Supersedes the
   refuted brief. Note `freezeRegion` (`:1587`) is lexically above
   `computeFxWindows` (`:2994`), so reaching the census from freeze
   needs a forward declaration in the list at `:792`.
