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

- 2026-08-01 **`@call` rows — the intra-file reverse index.** 171 rows across 38 module maps, from the receiver-qualified sites `extract_uses` was discarding at its intra-module skip. Callees keyed by their declaration head, declaration heads guarded out with a prefix fullmatch, and `decl_head` now the one spelling of how a declaration reads — used by the new rows and by `emit_items`, which the regen gate proves changed no output. (design § Intra-file call edges)
- **one definition of the source set** (design § Mechanism). Both PostToolUse map
- **`1b569a2` — `tools/map_regen.py`, the regeneration gate.** `SOURCE_SETS`
- **`c346a69` — `sha=` out of the `.map` header.** It made byte-identity

## Now

(empty — phase 2 item 1 landed; run `/plan-next` to promote the bare-`foo(...)` pass, the queued half that widens where the edges come from.)

## Queued (current phase; one-liners)

1. Widen where the edges come from with the bare-`foo(...)` pass — for
   each name in the file's private-function set, match it over the
   already-masked code and attribute the site with `caller_at(line)`.
   Same edge list and same section as the item before, so this one is
   purely about the new source; its callees are the bare-name half of
   the key convention item 1 settled, and it inherits item 1's
   declaration-line guard. (Checked while measuring item 1: the raw
   `--`-stripped scan `extract_uses` runs and `strip_code`'s masked
   lines disagree on none of the receiver-qualified sites, so the two
   halves reading different text costs nothing today.) It lands
   separately because this is the half where a shadowing local can
   invent an edge that was never called, and it is exactly what phase
   3's `luac` oracle is aimed at.

2. Teach `map_query` the reverse index, so "who calls this helper" is
   askable without opening the map file. The name wants deciding against
   the existing vocabulary: `uses`/`usedby` are the cross-module pair and
   these rows are deliberately not those, so a name that reads as their
   synonym would undo the separation the `@call` row exists to keep.

3. Render the same edges forward, as a continuation row under the
   caller's declaration: `-> sortByPPQ:4812  dirtyChan:4830,4841`. The
   design writes this as the `@fn` row, but it has to be every
   declaration row that can hold a body — fn, method, dotfn, api — or
   chunk modules, whose callers are nearly all methods, lose most of the
   graph.

4. Make the forward tail reach a `map_query` result. The server rebuilds
   each structural result from the `@fn`/`@api` head rather than echoing
   the file, so the continuation row is invisible to a query until it is
   carried deliberately. The open choice is whether the tail rides every
   structural result or only when asked for: it would land on `kind='fn'`
   output everywhere, so it wants weighing against the noise.
