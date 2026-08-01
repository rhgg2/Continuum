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

- 2026-08-01 **The bare-name half of the `@call` index.** 1168 rows across 53 files, from every module-private helper called with no receiver; the lookbehind `(?<![.:\w])` rather than `\b` keeps a `tm:foo(` site out of the bare key. Corpus 171 → 1339 rows, 38 → 56 sections. The gate itself needed fixing: `.gitattributes` carries `map/*.map -diff`, so the brief's `git diff -U0` check was binary and could not fail — `map_regen.py` now prints the `--text` form after a full write. (design § Intra-file call edges)
- 2026-08-01 **`@call` rows — the intra-file reverse index.** 171 rows across 38 module maps, from the receiver-qualified sites `extract_uses` was discarding at its intra-module skip. Callees keyed by their declaration head, declaration heads guarded out with a prefix fullmatch, and `decl_head` now the one spelling of how a declaration reads — used by the new rows and by `emit_items`, which the regen gate proves changed no output. (design § Intra-file call edges)
- **one definition of the source set** (design § Mechanism). Both PostToolUse map
- **`1b569a2` — `tools/map_regen.py`, the regeneration gate.** `SOURCE_SETS`

## Now

**Teach `usedby` the intra-file `@call` index** — brief in `plan/IMPL.md`. (design § Intra-file call edges)

## Queued (current phase; one-liners)

1. Render the same edges forward, as a continuation row under the
   caller's declaration: `-> sortByPPQ:4812  dirtyChan:4830,4841`. The
   design writes this as the `@fn` row, but it has to be every
   declaration row that can hold a body — fn, method, dotfn, api — or
   chunk modules, whose callers are nearly all methods, lose most of the
   graph.

2. Make the forward tail reach a `map_query` result. The server rebuilds
   each structural result from the `@fn`/`@api` head rather than echoing
   the file, so the continuation row is invisible to a query until it is
   carried deliberately. The open choice is whether the tail rides every
   structural result or only when asked for: it would land on `kind='fn'`
   output everywhere, so it wants weighing against the noise. A cheaper
   alternative surfaced while briefing the `usedby` item: `uses` could
   match the *caller* side of the `@call` rows directly, answering the
   forward question at query time with no continuation row involved —
   which would leave item 1 a file-rendering change for the human reader
   only. Decide between them before building either.

3. Give a by-name binding its own row (found while sizing the bare
   pass). 100 of 1250 private fns have no call site at all and are
   reached only by reference — command tables (`arrangeDive =
   diveSelected`), namespace export tables (`chrome` returning `row =
   row`), callback arguments (`allocStream(…, audioValueCompare, …)`) —
   so the reverse index answers "nobody" where the honest answer names
   the entry point that explains why the helper exists. Kept out of the
   call pass on purpose: phase 3's oracle counts `CALL`, and a by-name
   reference is `GETUPVAL` without one. Wants deciding whether an
   export-table binding is the same kind of thing as a command-table
   one.

4. Close the file-scope declaration-capture gap. Nine `function foo(`
   assignments to a `local` forward-decl (`arrangeManager:444
   ensureState`, `trackerView:2729 colFor`) are invisible to
   `NESTED_FN_RE`, which requires indentation — though the `do function
   foo() … end end` spelling of the same idiom is captured. Their bodies
   hold no `@fn` row, and every site inside them attributes to a bare
   line number. Lands on its own because it is the one change in this
   phase that is not additive: it adds `@fn` rows and rewrites existing
   `@use`/`@field`/`@call` attributions.
