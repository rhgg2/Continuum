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
   rendered as a `# Calls (intra-file)` index, with the forward
   direction served by `uses` rather than by a row.
   ✓ done (2026-08-01, 9 commits)
3. **Phase 3 — the luac oracle** (§ Mechanism: park the rewrite) — diff
   phase 2's intra-file `@call` edges against `luac -p -l -l` across all
   64 modules; the disagreement rate is what decides whether the cheap
   pass gets upgraded, and it answers the shadowing open question.
   ← in flight
4. **Phase 4 — negative results that say why** (§ Vocabulary —
   unsettled) — an empty `map_query` distinguishes *no such thing* from
   *bad regex* from *not indexed*, and names the nearest miss; 380 empty
   results in the corpus were re-asked by hand.
5. **Phase 5 — vocabulary** (§ Vocabulary — unsettled) — synonyms,
   fuzziness or near-misses. Unsettled by design: the phase opens with a
   look, and its answer reopens `design/map-navigation.md` before
   anything is built.

## Landed  (newest first; prune below ~4)

- 2026-08-02 **The parser landed behind its control, and the control caught what the brief had lost.** `tools/map_oracle.py` turns one module's `luac -p -l -l` listing into call records — 64 modules, 3,314 prototypes, 13,055 sites, zero `unknown`, a kind distribution matching the spike's to the record. The hand-counted table was written from the `.lua` and seen to fail 31 of 31 against a stub before any parser existed, which is what made its first real failure legible: `SELF` carries the same 8-bit constant-operand overflow the brief documented for `GETTABUP` alone, 23 sites, and it crashed the parse. The prose had dropped it; the brief's own `method 2451` checksum had pinned it all along, being exactly the corpus's `SELF` count. Layer 1 counts the structures it built rather than the lines it read, a distinction worth nothing until a row is read and then discarded — the one drop path a raising regex cannot cover. Five perturbations, four noticed; the fifth is recorded in the design doc, an over-broad `CALL` range that moves twenty-two names and not one kind count. No `.map` churn, suite green at 2,227. (design § Mechanism: park the rewrite)
- 2026-08-01 **The alias table was blind in two places, not one.** The plan item named the forward-decl fill — `local ec, clipboard, ctx` at `trackerView:262`, filled 3700 lines later — and the search for it turned up a second idiom with the same cause: the declaration scan saw only a column-0 `local X = <init>` complete on one line, so an instance bound inside a function was as invisible as one bound in two steps. The second is what fixes `map/continuum.map`, the wiring file's map, which carried five outbound rows and no edge to anything it builds; `Main` now resolves `coord:register` ×5, `coord:setActive` ×10, `cmgr:registerAll` and the rest to their declarations, and `usedby ec:row` goes 9 cross-module sites to 34. The regen gate cannot fail for a no-op, so the directional signal is the check-mode run between the code edit and the write: exactly the five expected maps, no sixth. +102/−2 across them — 20 `@construct` rows, 78 `@use` rows, 243 sites — and the only two removals in the whole diff are the forward-decl shells the construct rows replace. The scope handles stayed out, and the reason generalises past them: the extractor emits receivers verbatim and the querier re-resolves them by name, so the general form of the rule would land `local ps = painter.new(…)` in `arrangeRender` as 43 cross-module edges to pextStore. A wrong alias does not drop, it lies. `gridPane`'s 24 `ec:` sites stay dropped for want of a safe rule, for phase 3's oracle to report. (design § Intra-file call edges)
- 2026-08-01 **Both call passes take `[({]`.** A call whose one argument is a table literal drops the parens, and neither pass could see it. 86 maps move — 21 module, 65 spec — for a net +44 and +67 lines; every removal in that diff is a row re-emitted with more sites in it, so nothing is lost anywhere. 11 `@call` rows arrive, among them the three helpers the corpus said nothing reached: `editCursor resizeBy`, `trackerManager makeTailRules` and `reconcileDerived`. With those in, 84 private functions with no call site becomes 81 and all 81 are named by a `@bind`, so the reverse index no longer says "nobody reaches this" about anything. `pa_compute_desired_spec` had named nothing it exercised, every call in it being `pa.computeDesired{…}`; it now names it. The directional signal was the check-mode run between the code edit and the write — exactly the 21 expected module maps, no twenty-second. String sugar stays out: the corpus has no qualified `recv.fn'…'` site at all, and widening to a quote matches 1013 string literals holding a dot. (design § Intra-file call edges)
- 2026-08-01 **Fifteen file-scope declarations, in two spellings.** The plan item named nine `function foo(` fills of a `local` forward-decl; the search found six `foo = function(` siblings, the same idiom in the spelling a syntax search could not see. Both land together: 15 `@fn` rows, 34 `@call` rows and 4 `@bind` rows arrive, 11 forward-decl shell rows leave, and every site inside the fifteen bodies stops rendering as a bare line number — `@field r nodes @ 251,304` becomes `pruneSourceTags:251 mirrorBusTaps:304`. Two regexes rather than one, because column 0 is what separates a declaration from a table-constructor value. The regen gate cannot fail for a no-op, so the directional signal is the run between the code change and the write: exactly the nine expected maps, no tenth. Probed after, `usedby='ensureState'` returns the seven intra-file callers it answered `(no callers found)` for before. (design § Intra-file call edges)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **Reduce both corpora to the same triple, joined on the span.** The
   map's declaration rows carry `@ 19-24` and luac's prototype headers
   carry `<groups.lua:19,24>`, so the span is the join key and the name is
   not — which keeps a caller the extractor never captured visible as its
   own class instead of letting it confound the callee diff. Expand the
   `@call` rows back into `(caller, callee, line)`, reduce luac's
   prototypes to the same shape, and handle the 389 declaration rows that
   carry a bare line where the other 1758 carry a span.

2. **Diff all 64 modules and classify the disagreements rather than
   counting them.** Report agreed, map-only and luac-only separately, and
   within those name the classes the design doc has already predicted —
   `DAG`'s indented `function ctx:` members, which the extractor
   deliberately does not capture, and callers the extractor never parsed,
   whose sites render as bare line numbers that luac can attribute to a
   prototype. `@bind` rows stay out of the diff by construction, a by-name
   reference being a `GETUPVAL` with no `CALL` after it, and folding them
   in would fill the rate with noise.

3. **Read the report and write the verdict into the design doc.** The
   shadowing open question is the one the phase was built to answer, and
   the map-only edges where luac shows a local are exactly the false ones
   the earlier `local`-only scan could not see, nested-closure parameters
   and `for` variables among them. Record the rate and the decision it
   drives — whether the cheap regex pass gets upgraded — in
   `design/map-navigation.md`, and close the question either way.
