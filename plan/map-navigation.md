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

- 2026-08-01 **Fifteen file-scope declarations, in two spellings.** The plan item named nine `function foo(` fills of a `local` forward-decl; the search found six `foo = function(` siblings, the same idiom in the spelling a syntax search could not see. Both land together: 15 `@fn` rows, 34 `@call` rows and 4 `@bind` rows arrive, 11 forward-decl shell rows leave, and every site inside the fifteen bodies stops rendering as a bare line number — `@field r nodes @ 251,304` becomes `pruneSourceTags:251 mirrorBusTaps:304`. Two regexes rather than one, because column 0 is what separates a declaration from a table-constructor value. The regen gate cannot fail for a no-op, so the directional signal is the run between the code change and the write: exactly the nine expected maps, no tenth. Probed after, `usedby='ensureState'` returns the seven intra-file callers it answered `(no callers found)` for before. (design § Intra-file call edges)
- 2026-08-01 Give a by-name binding its own row (§ Intra-file call edges)
- 2026-08-01 **`uses` answers the forward question, declaration-resolved.** The caller field of the `@call` and `@use` rows was carried by the corpus and read by nothing; `uses` now groups by matching declaration and resolves each callee to *its own*, so the answer is jump-ready — 2931 declarations render across the corpus for 5028 callee rows, 84.5% resolved and the rest `(external)` with no map to resolve against. The span test that places a site in its caller is load-bearing and total: all 6478 caller-attributed sites resolve to exactly one declaration, which is what lets `collect` in `clipboard` come back as two groups rather than one merged. Cross targets prefer the `@api` declaration by construction — a cross-module call cannot reach a module-private `@fn` — which clears all 174 ambiguous sites. `query` naming a module is a pointer at `module=` under both kinds, retiring `usedby`'s documented exception. (design § Intra-file call edges)
- 2026-08-01 **`usedby` answers in two labelled sections.** The 1339 `@call` rows were unreachable through the querier — matching neither `_DECL` nor `_ANN`, so `query='centsToRaw'` returned `(no callers found)` while five callers sat in `map/trackerManager.map`. Both halves gather uncapped and split an even budget, each donating what it can't use, since neither may starve the other; `calls`/`calledby` land as aliases, and a module-level target has no intra half. Settled on contact: a bare callee's module is the map's own stem rather than the resolver's guess at its spelling — without which a `module=` narrowing dropped the intra half, and the new both-empty line asserted it had searched both. (design § Intra-file call edges)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. Teach both call passes the `f{…}` spelling (found while sizing the
   binding pass). `CALL_RE` wants an open paren, and Lua's sugar for a
   lone table or string argument does not supply one, so 98 qualified
   sites produce no edge at all — `cmgr:registerAll{…}`
   (`continuum.lua:136`), `modalHost:openPrompt{…}`,
   `chrome.palettePane{…}` — along with 13 bare ones. The loss falls
   where the house idiom is densest: command registration is written
   `registerAll{…}` throughout, so the wiring the maps are most asked
   about is the wiring they do not carry. Additive to `@use` and
   `@call` both.

2. Decide what a return table of privates makes a module.
   `chrome.lua` ends `return { colour = colour, … }`, so its thirty
   public functions hold `@fn` rows under `# Private functions` and the
   map renders no `# Public API` section at all; `masterMix` does the
   same with one. The `@bind` rows will say those thirty are bound,
   which is true and is a different claim from *exported* — and
   `usedby` on `chrome.row` resolves today only because the key and the
   helper happen to share a name, which `fs.fileOps.copy = copyFile`
   does not.
