# map navigation — plan

> source: `design/map-navigation.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — the regeneration gate** (§ Mechanism: park the rewrite)
   — regenerate every map the extractor emits (the 66 modules, the spec
   and harness maps alongside them) and diff against the committed ones
   in one command; `map_extract.py` is one-file-per-call today. Every
   later phase lands behind it, byte-identical first.  ✓ done
2. **Phase 2 — intra-file call edges** (§ Intra-file call edges) — one
   `(caller, callee, line)` list per file, from the `self:` edges
   currently extracted and discarded plus a new bare-`foo(...)` pass
   over masked code; rendered twice, forward on the `@fn` row and
   reverse as a `# Calls (intra-file)` index, both reachable from
   `map_query`.  ← in flight
3. **Phase 3 — the luac oracle** (§ Mechanism: park the rewrite) — diff
   phase 2's edges against `luac -p -l -l` across all 66 modules; the
   disagreement rate is what decides whether the cheap pass gets
   upgraded, and it answers the shadowing open question.
4. **Phase 4 — negative results that say why** (§ Vocabulary —
   unsettled) — an empty `map_query` distinguishes *no such thing* from
   *bad regex* from *not indexed*, and names the nearest miss; 380 empty
   results in the corpus were re-asked by hand.
5. **Phase 5 — vocabulary** (§ Vocabulary — unsettled) — synonyms,
   fuzziness or near-misses. Unsettled by design: the phase opens with a
   look, and its answer reopens `design/map-navigation.md` before
   anything is built.

## Landed  (newest first; prune below ~4)

- 2026-08-01 **The alias table was blind in two places, not one.** The plan item named the forward-decl fill — `local ec, clipboard, ctx` at `trackerView:262`, filled 3700 lines later — and the search for it turned up a second idiom with the same cause: the declaration scan saw only a column-0 `local X = <init>` complete on one line, so an instance bound inside a function was as invisible as one bound in two steps. The second is what fixes `map/continuum.map`, the wiring file's map, which carried five outbound rows and no edge to anything it builds; `Main` now resolves `coord:register` ×5, `coord:setActive` ×10, `cmgr:registerAll` and the rest to their declarations, and `usedby ec:row` goes 9 cross-module sites to 34. The regen gate cannot fail for a no-op, so the directional signal is the check-mode run between the code edit and the write: exactly the five expected maps, no sixth. +102/−2 across them — 20 `@construct` rows, 78 `@use` rows, 243 sites — and the only two removals in the whole diff are the forward-decl shells the construct rows replace. The scope handles stayed out, and the reason generalises past them: the extractor emits receivers verbatim and the querier re-resolves them by name, so the general form of the rule would land `local ps = painter.new(…)` in `arrangeRender` as 43 cross-module edges to pextStore. A wrong alias does not drop, it lies. `gridPane`'s 24 `ec:` sites stay dropped for want of a safe rule, for phase 3's oracle to report. (design § Intra-file call edges)
- 2026-08-01 **Both call passes take `[({]`.** A call whose one argument is a table literal drops the parens, and neither pass could see it. 86 maps move — 21 module, 65 spec — for a net +44 and +67 lines; every removal in that diff is a row re-emitted with more sites in it, so nothing is lost anywhere. 11 `@call` rows arrive, among them the three helpers the corpus said nothing reached: `editCursor resizeBy`, `trackerManager makeTailRules` and `reconcileDerived`. With those in, 84 private functions with no call site becomes 81 and all 81 are named by a `@bind`, so the reverse index no longer says "nobody reaches this" about anything. `pa_compute_desired_spec` had named nothing it exercised, every call in it being `pa.computeDesired{…}`; it now names it. The directional signal was the check-mode run between the code edit and the write — exactly the 21 expected module maps, no twenty-second. String sugar stays out: the corpus has no qualified `recv.fn'…'` site at all, and widening to a quote matches 1013 string literals holding a dot. (design § Intra-file call edges)
- 2026-08-01 **Fifteen file-scope declarations, in two spellings.** The plan item named nine `function foo(` fills of a `local` forward-decl; the search found six `foo = function(` siblings, the same idiom in the spelling a syntax search could not see. Both land together: 15 `@fn` rows, 34 `@call` rows and 4 `@bind` rows arrive, 11 forward-decl shell rows leave, and every site inside the fifteen bodies stops rendering as a bare line number — `@field r nodes @ 251,304` becomes `pruneSourceTags:251 mirrorBusTaps:304`. Two regexes rather than one, because column 0 is what separates a declaration from a table-constructor value. The regen gate cannot fail for a no-op, so the directional signal is the run between the code change and the write: exactly the nine expected maps, no tenth. Probed after, `usedby='ensureState'` returns the seven intra-file callers it answered `(no callers found)` for before. (design § Intra-file call edges)
- 2026-08-01 Give a by-name binding its own row (§ Intra-file call edges)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty — run /plan-phase when this lands.)
